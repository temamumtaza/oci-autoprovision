#!/usr/bin/env bash
# oci-notify.sh — pengirim notifikasi (dipanggil cron Hermes no_agent).
# Membaca antrean var/pending_notify.txt (ditulis capacity-monitor.sh),
# stdout terkirim ke Telegram; kosong = silent. Antrean = dead-letter aman.
set -u
REPO="/home/temamumtaza/Documents/dev/oci-autoprovision"
PENDING="$REPO/var/pending_notify.txt"
[ -s "$PENDING" ] || exit 0
cat "$PENDING"
mv "$PENDING" "$PENDING.sent.$(date +%s)" 2>/dev/null || rm -f "$PENDING"
# simpan hanya 20 arsip terakhir
ls -1t "$PENDING".sent.* 2>/dev/null | tail -n +21 | xargs -r rm -f
exit 0
