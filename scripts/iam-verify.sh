#!/usr/bin/env bash
# v3 — verifier API key & identitas (Cloud Shell). Idempotent, tanpa secret.
set -u
GROUP_NAME="hermes-provisioner"
COMP_NAME="personal-lab"
TENANCY="ocid1.tenancy.oc1..aaaaaaaa2mjyndqomlaiof2cj7e6bztajo3xz4mvqpg5ztwduhkryyuhdyla"
USER_OCID="ocid1.user.oc1..aaaaaaaa3q6wjgjgh6knpeghfvyt5cvbudogn4gch4eoxilysqxkbifuj5da"
FP="e6:d1:0f:e9:fb:4a:7a:19:e4:00:f2:f6:8a:3d:41:ae"

PUBKEY='-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA8aqyECO6V2TIZJJOvUsN
5VjxD4beIwYd/4Nw1TWwgUOHUg5oH4Kn9yaH7hEx+TkJpaT2Xe9MfBhvI4eOkqMd
1xrdSQnXUEeP6OQzZKEG1xvWAlqpzpMrZqGx0taB9y2DPaFwSSob9q112i5r+F/Q
on3S9nPVxS345jHLtM3BOKW/HYnvJRJzOi0AudHQDO7dCoQmC71UbPMz5w5j/JKD
U1XR3U9sSX8IJLTnDznlOZm98ecMNdXvCawyCJhqwZd2t+KNFEX93CsGdG62Op9G
8kfWmjYuhujpFhXJd8MdHnJO9l6GSrybKbItecFoo6thXggOsVe/UeDRNjHIaCMs
XQIDAQAB
-----END PUBLIC KEY-----'

echo "=== A. pasangan user <-> tenancy ==="
oci iam user get --user-id "$USER_OCID" \
  --query 'data.{name:name,tenancy:"compartment-id"}' --output table 2>&1 | head -6

echo "=== B. daftar API key user ini ==="
oci iam user api-key list --user-id "$USER_OCID" \
  --query 'data[].{fp:fingerprint,state:"lifecycle-state"}' --output table 2>&1 | head -10

echo "=== C. pastikan fp $FP terdaftar; kalau belum, upload ulang (error ditampilkan) ==="
REGISTERED=$(oci iam user api-key list --user-id "$USER_OCID" --all \
  --query "data[?fingerprint=='$FP'].fingerprint | [0]" --raw-output 2>/dev/null | tr -d '"')
if [ -n "$REGISTERED" ] && [ "$REGISTERED" != "null" ]; then
  echo "== fp terdaftar: OK"
else
  echo "== fp BELUM terdaftar — upload ulang:"
  PUBFILE=$(mktemp /tmp/pub.XXXX.pem); printf '%s\n' "$PUBKEY" > "$PUBFILE"
  oci iam user api-key upload --user-id "$USER_OCID" --key-file "$PUBFILE"
  echo "exit_code=$?"
  rm -f "$PUBFILE"
fi

echo "=== D. compartment $COMP_NAME ==="
COMP_OCID=""
for i in 1 2 3 4 5 6; do
  COMP_OCID=$(oci iam compartment list --compartment-id "$TENANCY" --all \
    --query "data[?name=='$COMP_NAME' && \"lifecycle-state\"=='ACTIVE'].id | [0]" --raw-output 2>/dev/null | tr -d '"')
  [ -n "$COMP_OCID" ] && [ "$COMP_OCID" != "null" ] && break
  echo "   retry $i (policy baru mungkin masih propagasi)..."; sleep 5
done
[ -n "$COMP_OCID" ] && echo "== compartment: $COMP_OCID" || echo "!! compartment tidak ketemu"

echo "=== E. fingerprint via python (FIPS-safe) ==="
python3 - "$PUBKEY" <<'PY' 2>/dev/null || echo "(python fp gagal — abaikan)"
import sys, hashlib, base64, re
pem = sys.argv[1]
b64 = "".join(l for l in pem.splitlines() if "KEY" not in l)
der = base64.b64decode(b64)
print("fp(python):", ":".join(f"{b:02x}" for b in hashlib.md5(der, usedforsecurity=False).digest()))
PY

cat <<BLOCK

================ COPY TO AGENT ================
tenancy_ocid=$TENANCY
user_ocid=$USER_OCID
region=ap-batam-1
fingerprint=$FP
group=$GROUP_NAME
compartment_name=$COMP_NAME
compartment_ocid=$COMP_OCID
================ END COPY =====================
BLOCK
