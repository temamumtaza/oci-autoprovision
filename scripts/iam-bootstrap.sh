#!/usr/bin/env bash
# ============================================================
# IAM bootstrap v2 — Hermes OCI Auto-Provisioner (ap-batam-1)
# Jalankan di OCI Cloud Shell (shell.oracle.com atau dari Console).
# Idempotent: aman dijalankan ulang. Tidak berisi secret —
# hanya meng-upload PUBLIC key. Private key tidak pernah keluar laptop.
# v2: identitas tidak bergantung format file config — OCID via regex,
#     region via API region-subscription (Cloud Shell pre-authenticated).
# ============================================================
set -u

GROUP_NAME="${OPS_GROUP:-hermes-provisioner}"
COMP_NAME="${OPS_COMP:-personal-lab}"
P_COMPUTE="hermes-lab-compute"
P_CAPACITY="hermes-lab-capacity"
P_BILLING="hermes-lab-billing"

PUBKEY='-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA8aqyECO6V2TIZJJOvUsN
5VjxD4beIwYd/4Nw1TWwgUOHUg5oH4Kn9yaH7hEx+TkJpaT2Xe9MfBhvI4eOkqMd
1xrdSQnXUEeP6OQzZKEG1xvWAlqpzpMrZqGx0taB9y2DPaFwSSob9q112i5r+F/Q
on3S9nPVxS345jHLtM3BOKW/HYnvJRJzOi0AudHQDO7dCoQmC71UbPMz5w5j/JKD
U1XR3U9sSX8IJLTnDznlOZm98ecMNdXvCawyCJhqwZd2t+KNFEX93CsGdG62Op9G
8kfWmjYuhujpFhXJd8MdHnJO9l6GSrybKbItecFoo6thXggOsVe/UeDRNjHIaCMs
XQIDAQAB
-----END PUBLIC KEY-----'

CFG="${OCI_CONFIG_FILE:-$HOME/.oci/config}"

# --- 0. identitas tenancy/user/region --------------------------
TENANCY="${OPS_TENANCY_OCID:-$(grep -hoE 'ocid1\.tenancy\.oc1\.[a-zA-Z0-9]+' "$CFG" "$HOME/.oci/config" /etc/oci/config 2>/dev/null | head -1)}"
[ -n "$TENANCY" ] || TENANCY="ocid1.tenancy.oc1..aaaaaaaa2mjyndqomlaiof2cj7e6bztajo3xz4mvqpg5ztwduhkryyuhdyla"
[ -n "$TENANCY" ] || { echo "ERROR: tenancy OCID tidak ketemu"; exit 1; }

REGION=$(oci iam region-subscription list --query 'data[?is-home-region==`true`].region-name | [0]' --raw-output 2>/dev/null | tr -d '"')
if [ -z "$REGION" ] || [ "$REGION" = "null" ]; then
  REGION=$(grep -hoE '^region[ \t]*=.*' "$CFG" "$HOME/.oci/config" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
fi
[ -n "$REGION" ] || { echo "ERROR: region tidak ketemu"; exit 1; }
echo "== tenancy : $TENANCY"
echo "== region  : $REGION"

USER_OCID="${OPS_USER_OCID:-$(grep -hoE 'ocid1\.user\.oc1\.[a-zA-Z0-9]+' "$CFG" "$HOME/.oci/config" /etc/oci/config 2>/dev/null | head -1)}"
if [ -z "$USER_OCID" ]; then
  N=$(oci iam user list --compartment-id "$TENANCY" --all --query 'length(data)' --raw-output 2>/dev/null)
  if [ "$N" = "1" ]; then
    USER_OCID=$(oci iam user list --compartment-id "$TENANCY" --all --query 'data[0].id' --raw-output | tr -d '"')
  else
    echo "== user OCID tidak ada di config. Daftar user tenancy:"
    oci iam user list --compartment-id "$TENANCY" --all --query 'data[].{name:name,id:id}' --output table 2>/dev/null
    echo "Jalankan ulang: OPS_USER_OCID=<ocid-anda> bash $0"
    exit 1
  fi
fi
echo "== user    : $USER_OCID"

# --- 1. group (idempotent) ------------------------------------
GID=$(oci iam group list --compartment-id "$TENANCY" --all --query "data[?name=='$GROUP_NAME'].id | [0]" --raw-output 2>/dev/null | tr -d '"')
if [ -z "$GID" ] || [ "$GID" = "null" ]; then
  GID=$(oci iam group create --name "$GROUP_NAME" \
        --description "least-privilege automation for home-lab compute provisioning" \
        --query 'data.id' --raw-output | tr -d '"')
  echo "== group dibuat : $GROUP_NAME"
else
  echo "== group sudah ada"
fi

MEMBER=$(oci iam group list-users --group-id "$GID" --all \
         --query "data[?userid=='$USER_OCID'].userid | [0]" --raw-output 2>/dev/null | tr -d '"')
if [ -z "$MEMBER" ] || [ "$MEMBER" = "null" ]; then
  oci iam group add-user --group-id "$GID" --user-id "$USER_OCID" >/dev/null && echo "== user masuk group"
else
  echo "== user sudah member"
fi

# --- 2. policies (3 terpisah; satu gagal tidak menggugurkan lain) ---
mk_policy() { # $1=name  $2=statements-JSON
  local EXIST
  EXIST=$(oci iam policy list --compartment-id "$TENANCY" --all \
          --query "data[?name=='$1'].id | [0]" --raw-output 2>/dev/null | tr -d '"')
  if [ -n "$EXIST" ] && [ "$EXIST" != "null" ]; then echo "== policy $1 sudah ada"; return 0; fi
  if oci iam policy create --compartment-id "$TENANCY" --name "$1" \
       --description "hermes auto-provisioner (least privilege)" \
       --statements "$2" >/dev/null 2>&1; then
    echo "== policy dibuat : $1"; return 0
  fi
  return 1
}

S_COMPUTE='["Allow group '"$GROUP_NAME"' to read compartments in tenancy","Allow group '"$GROUP_NAME"' to manage instance-family in compartment '"$COMP_NAME"'","Allow group '"$GROUP_NAME"' to use virtual-network-family in compartment '"$COMP_NAME"'","Allow group '"$GROUP_NAME"' to use volume-family in compartment '"$COMP_NAME"'","Allow group '"$GROUP_NAME"' to read instance-images in tenancy","Allow group '"$GROUP_NAME"' to read app-catalog-listing in tenancy"]'
S_CAPACITY='["Allow group '"$GROUP_NAME"' to manage compute-capacity-reports in tenancy","Allow group '"$GROUP_NAME"' to read limits in tenancy"]'
S_BILLING='["Allow group '"$GROUP_NAME"' to read usage-report in tenancy","Allow group '"$GROUP_NAME"' to read subscriptions in tenancy","Allow group '"$GROUP_NAME"' to read organizations-subscriptions in tenancy"]'

mk_policy "$P_COMPUTE"  "$S_COMPUTE"  || echo "!! GAGAL: $P_COMPUTE (copy output error ke agent)"
mk_policy "$P_CAPACITY" "$S_CAPACITY" || echo "!! GAGAL: $P_CAPACITY (copy output error ke agent)"
if ! mk_policy "$P_BILLING" "$S_BILLING"; then
  S_BILLING='["Allow group '"$GROUP_NAME"' to read usage-reports in tenancy","Allow group '"$GROUP_NAME"' to read subscriptions in tenancy","Allow group '"$GROUP_NAME"' to read organizations-subscriptions in tenancy"]'
  mk_policy "$P_BILLING" "$S_BILLING" || echo "!! GAGAL: $P_BILLING (kedua ejaan; copy output ke agent)"
fi

# --- 3. upload API public key (idempotent by fingerprint) ------
PUBFILE=$(mktemp /tmp/hermes_api_pub.XXXXXX)
printf '%s\n' "$PUBKEY" > "$PUBFILE"
FP=$(openssl pkey -pubin -in "$PUBFILE" -outform DER 2>/dev/null | openssl md5 -c | awk '{print $2}')
EXIST_FP=$(oci iam user api-key list --user-id "$USER_OCID" --all \
           --query "data[?fingerprint=='$FP'].fingerprint | [0]" --raw-output 2>/dev/null | tr -d '"')
if [ -n "$EXIST_FP" ] && [ "$EXIST_FP" != "null" ]; then
  echo "== API key sudah terdaftar (fp: $FP)"
else
  if oci iam user api-key upload --user-id "$USER_OCID" --key-file "$PUBFILE" >/dev/null 2>&1; then
    echo "== API key di-upload (fp: $FP)"
  else
    echo "!! GAGAL upload API key. Coba manual, lalu kirim output ke agent:"
    echo "   oci iam user api-key upload --user-id $USER_OCID --key-file <file-pubkey>"
    rm -f "$PUBFILE"; exit 1
  fi
fi
rm -f "$PUBFILE"

# --- 4. compartment OCID --------------------------------------
COMP_OCID=$(oci iam compartment list --compartment-id "$TENANCY" --all \
            --query "data[?name=='$COMP_NAME' && lifecycleState=='ACTIVE'].id | [0]" --raw-output 2>/dev/null | tr -d '"')

# --- 5. blok hasil untuk agent ---------------------------------
cat <<BLOCK

================ COPY TO AGENT ================
tenancy_ocid=$TENANCY
user_ocid=$USER_OCID
region=$REGION
fingerprint=$FP
group=$GROUP_NAME
compartment_name=$COMP_NAME
compartment_ocid=$COMP_OCID
================ END COPY =====================
BLOCK
echo "Selesai. Kirim blok di atas balik ke Hermes (aman — tidak ada secret)."
