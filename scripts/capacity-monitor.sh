#!/usr/bin/env bash
# capacity-monitor.sh — poll kapasitas A1 + auto-provision saat AVAILABLE.
# Idempotent: jalan tiap 3 jam; notif hanya saat perubahan penting; aman reboot.
set -u
cd "$(dirname "$0")/.."
source ./etc/config.sh
mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
file_get() { [ -f "$1" ] && cat "$1" 2>/dev/null || echo ""; }
file_set() { printf '%s' "$2" > "$1" 2>/dev/null || true; }
bump_err() { local E; E=$(file_get "$REPO/var/err_count"); file_set "$REPO/var/err_count" $(( ${E:-0} + 1 )); echo $(( ${E:-0} + 1 )); }

oci_get() { # GET-call dengan retry+backoff; output JSON via stdout
  local f=0 out
  while [ $f -lt $MAX_TRIES_API ]; do
    out=$("$OCI_BIN" "$@" 2>>"$LOG.err") && { printf '%s' "$out"; return 0; }
    f=$((f+1)); [ $f -lt $MAX_TRIES_API ] && sleep $((f*10))
  done
  return 1
}

notify() { printf '%s\n' "$1"; }   # stdout = dikirim oleh cron Hermes; kosong = silent

[[ "${1:-}" == "--check" ]] && { echo "OK"; exit 0; }

log "=== tick mulai ==="
for v in TENANCY COMPARTMENT REGION AD SUBNET_PUBLIC SHAPE OCPUS MEM_GB BOOT_GB DISPLAY_NAME; do
  [ -n "${!v:-}" ] || { log "FATAL: config $v kosong"; notify "⚠️ OCI provisioner: config $v kosong."; exit 1; }
done

# ---------- 0. guard: instance existing? (anti-duplikat, resume-safe) ----------
if ! EXISTING_JSON=$(oci_get compute instance list --compartment-id "$COMPARTMENT" --all); then
  E=$(bump_err); log "WARN: list instance gagal (err beruntun #$E)"
  [ $(( E % ERR_NOTIFY_EVERY )) -eq 1 ] && notify "⚠️ OCI monitor: API error beruntun (#$E). Log: var/monitor.log.err"
  exit 0
fi
ERR=0; file_set "$REPO/var/err_count" 0
# CLI mengembalikan stdout kosong utk list kosong (rc=0)
EXISTING=""
[ -n "$EXISTING_JSON" ] && EXISTING=$(printf '%s' "$EXISTING_JSON" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))' 2>/dev/null)
if [ -z "$EXISTING" ]; then
  if [ -z "$EXISTING_JSON" ]; then EXISTING=0; else E=$(bump_err); log "WARN: parse instance list gagal (#$E)"; exit 0; fi
fi

if [ "$EXISTING" != "0" ]; then
  file_set "$REPO/var/provisioned" 1
  IID=$(oci_get compute instance list --compartment-id "$COMPARTMENT" --all \
    --query 'data[0].id' --raw-output)
  IP=$(oci_get compute instance list-vnics --compartment-id "$COMPARTMENT" \
    --instance-id "$IID" --query 'data[0]."public-ip"' --raw-output)
  if [ "$(file_get "$REPO/var/provisioned_notified")" != "1" ]; then
    notify "🎉 VM OCI AKTIF (guard: tidak create duplikat).
Shape: $SHAPE $OCPUS/$MEM_GB | IP: ${IP:-?}
ID: ${IID:-?}"
    file_set "$REPO/var/provisioned_notified" 1
  fi
  log "instance ada (${IID:-?}) — idle"
  exit 0
fi

# ---------- 1. pre-flight biaya (guard kasar, bukan pengganti billing console) ----------
SPEND_JSON=""
if SPEND_JSON=$(oci_get usage-api usage-summary request-summarized-usages --tenant-id "$TENANCY" \
  --time-usage-started "$(date -u -d '7 days ago' '+%Y-%m-%dT00:00:00Z')" \
  --time-usage-ended "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --granularity MONTHLY \
  --query 'data.items[*]."computed-cost"'); then
  if [ -n "$SPEND_JSON" ]; then
  SPEND=$(printf '%s' "$SPEND_JSON" | python3 -c '
import sys, json
try:
    arr = json.load(sys.stdin)
    print(round(sum(float(x or 0) for x in arr), 2))
except Exception:
    print("?")')
  if [ "$SPEND" != "?" ] && python3 -c "exit(0 if float('$SPEND') > $COST_GUARD_USD else 1)" 2>/dev/null; then
    notify "🛑 COST GUARD: pemakaian 7 hari \$${SPEND} > \$$COST_GUARD_USD. Create diblokir sementara."
    log "cost guard blokir: \$$SPEND"
    exit 0
  fi
  log "spend 7d: \$${SPEND:-?}"
  fi
fi

# ---------- 2. resolve image Ubuntu 24.04 ARM64 terbaru ----------
IMG_ID=$(oci_get compute image list --compartment-id "$COMPARTMENT" \
  --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output)
[ -n "$IMG_ID" ] || { E=$(bump_err); log "WARN: image resolve gagal (#$E)"; exit 0; }

# ---------- 3. capacity report ----------
REP=$(oci_get compute compute-capacity-report create --availability-domain "$AD" \
  --compartment-id "$COMPARTMENT" \
  --shape-availabilities '[{"instance-shape":"'"$SHAPE"'","instance-shape-config":{"ocpus":'"$OCPUS"',"memory-in-gbs":'"$MEM_GB"'}}]')
[ -n "$REP" ] || { E=$(bump_err); log "WARN: capacity report gagal (#$E)"; [ $(( E % ERR_NOTIFY_EVERY )) -eq 1 ] && notify "⚠️ OCI monitor: capacity report gagal #$E tick."; exit 0; }

STATUS=$(printf '%s' "$REP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["shape-availabilities"][0]["availability-status"])' 2>/dev/null)
[ -n "$STATUS" ] || { E=$(bump_err); log "WARN: parse status gagal (#$E)"; exit 0; }
log "capacity: $STATUS"

PREV=$(file_get "$REPO/var/last_status")

# tidak berubah & tidak AVAILABLE -> silent
if [ -n "$PREV" ] && [ "$STATUS" = "$PREV" ] && [ "$STATUS" != "AVAILABLE" ]; then
  log "no change ($STATUS) — silent exit"
  exit 0
fi

# ---------- 4. AVAILABLE -> PROVISION ----------
if [ "$STATUS" = "AVAILABLE" ]; then
  log "AVAILABLE terdeteksi — eksekusi create"
  CREATE_OUT=$("$OCI_BIN" compute instance launch \
    --availability-domain "$AD" \
    --compartment-id "$COMPARTMENT" \
    --shape "$SHAPE" \
    --shape-config '{"ocpus":'"$OCPUS"',"memoryInGBs":'"$MEM_GB"'}' \
    --image-id "$IMG_ID" \
    --subnet-id "$SUBNET_PUBLIC" \
    --assign-public-ip true \
    --boot-volume-size-in-gbs "$BOOT_GB" \
    --display-name "$DISPLAY_NAME" \
    --user-data-file "$USER_DATA" \
    --ssh-authorized-keys-file "$SSH_PUB" \
    --wait-for-state RUNNING --max-wait-seconds 900 2>&1)
  RC=$?
  printf '%s\n' "$CREATE_OUT" >> "$LOG.create"
  if [ $RC -ne 0 ]; then
    # OUT_OF_HOST_CAPACITY saat create = capacity report tidak menjamin sukses
    file_set "$REPO/var/last_status" "AVAILABLE"
    file_set "$REPO/var/last_create_fail" "$(date +%s)"
    log "create gagal rc=$RC (akan retry tick berikut)"
    notify "❌ Create gagal walau capacity AVAILABLE (report tidak menjamin alokasi). Retry otomatis tick berikutnya. Log: var/monitor.log.create"
    exit 0
  fi
  IID=$(oci_get compute instance list --compartment-id "$COMPARTMENT" --all \
    --query "data[?\"display-name\"=='$DISPLAY_NAME'].id | [0]" --raw-output)
  file_set "$REPO/var/instance_id" "$IID"
  file_set "$REPO/var/provisioned" 1
  sleep 15   # VNIC attach
  IP=$(oci_get compute instance list-vnics --compartment-id "$COMPARTMENT" \
    --instance-id "$IID" --query 'data[0]."public-ip"' --raw-output)
  file_set "$REPO/var/provisioned_notified" 1
  notify "🎉 VM OCI BERHASIL DIBUAT ✅
Shape: $SHAPE $OCPUS/$MEM_GB | Boot: ${BOOT_GB}GB Balanced
IP publik: ${IP:-pending}
Instance: ${IID:-?}
Cloud-init bootstrap jalan otomatis (±3-5 mnt). Health check menyusul."
  log "provisioning OK: $IID ip=${IP:-pending}"
  exit 0
fi

# ---------- 5. AVAILABLE -> habis lagi (flapping) ----------
if [ -n "$PREV" ]; then
  notify "ℹ️ Kapasitas $OCPUS/$MEM_GB Batam: $STATUS (sebelumnya $PREV). Monitoring lanjut."
fi
file_set "$REPO/var/last_status" "$STATUS"
log "transisi: ${PREV:-<kosong>} -> $STATUS"
