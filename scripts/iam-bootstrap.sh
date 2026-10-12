#!/usr/bin/env bash
# ============================================================
# IAM bootstrap — Hermes OCI Auto-Provisioner (ap-batam-1)
# Jalankan di OCI Cloud Shell (shell.oracle.com atau dari Console).
# Idempotent: aman dijalankan ulang. Tidak berisi secret —
# hanya meng-upload PUBLIC key. Private key tidak pernah keluar laptop.
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
[ -f "$CFG" ] || { echo "ERROR: $CFG tidak ditemukan (bukan di Cloud Shell?)"; exit 1; }
TENANCY=$(awk -F'=' '/^[ \t]*tenancy[ \t]*=/{gsub(/[ \t]/,"",$2);print $2;exit}' "$CFG")
USER_OCID=$(awk -F'=' '/^[ \t]*user[ \t]*=/{gsub(/[ \t]/,"",$2);print $2;exit}' "$CFG")
REGION=$(awk -F'=' '/^[ \t]*region[ \t]*=/{gsub(/[ \t]/,"",$2);print $2;exit}' "$CFG")
[ -n "${TENANCY:-}" ] && [ -n "${USER_OCID:-}" ] || { echo "ERROR: gagal parse $CFG"; exit 1; }
echo "== tenancy  : $TENANCY"
echo "== user     : $USER_OCID"
echo "== region   : $REGION"

# --- 1. group (idempotent) ------------------------------------
GID=$(oci iam group list --all --query "data[?name=='$GROUP_NAME'].id | [0]" --raw-output 2>/dev/null)
if [ -z "$GID" ] || [ "$GID" = "null" ]; then
  GID=$(oci iam group create --name "$GROUP_NAME" \
        --description "least-privilege automation for home-lab compute provisioning" \
        --query 'data.id' --raw-output | tr -d '"')
  echo "== group dibuat : $GROUP_NAME"
else
  echo "== group sudah ada"
fi

# membership (idempotent)
MEMBER=$(oci iam group list-users --group-id "$GID" --all \
         --query "data[?userid=='$USER_OCID'].userid | [0]" --raw-output 2>/dev/null)
if [ -z "$MEMBER" ] || [ "$MEMBER" = "null" ]; then
  oci iam group add-user --group-id "$GID" --user-id "$USER_OCID" >/dev/null
  echo "== user ditambahkan ke group"
else
  echo "== user sudah member"
fi

# --- 2. policies (3 terpisah; gagal satu tidak menggugurkan lain) ---
mk_policy() { # $1=name  $2=statements-JSON
  local EXIST
  EXIST=$(oci iam policy list --compartment-id "$TENANCY" --all \
          --query "data[?name=='$1'].id | [0]" --raw-output 2>/dev/null)
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

mk_policy "$P_COMPUTE"  "$S_COMPUTE"  || echo "!! GAGAL: $P_COMPUTE (laporkan output ini)"
mk_policy "$P_CAPACITY" "$S_CAPACITY" || echo "!! GAGAL: $P_CAPACITY (laporkan output ini)"
if ! mk_policy "$P_BILLING" "$S_BILLING"; then
  # fallback: ejaan jamak untuk usage-report (docs Oracle memakai keduanya)
  S_BILLING='["Allow group '"$GROUP_NAME"' to read usage-reports in tenancy","Allow group '"$GROUP_NAME"' to read subscriptions in tenancy","Allow group '"$GROUP_NAME"' to read organizations-subscriptions in tenancy"]'
  mk_policy "$P_BILLING" "$S_BILLING" || echo "!! GAGAL: $P_BILLING (kedua ejaan)"
fi

# --- 3. upload API public key (idempotent by fingerprint) ------
PUBFILE=$(mktemp /tmp/hermes_api_pub.XXXXXX)
printf '%s\n' "$PUBKEY" > "$PUBFILE"
FP=$(openssl pkey -pubin -in "$PUBFILE" -outform DER 2>/dev/null | openssl md5 -c | awk '{print $2}')
EXIST_FP=$(oci iam user api-key list --user-id "$USER_OCID" --all \
           --query "data[?fingerprint=='$FP'].fingerprint | [0]" --raw-output 2>/dev/null)
if [ -n "$EXIST_FP" ] && [ "$EXIST_FP" != "null" ]; then
  echo "== API key sudah terdaftar (fp: $FP)"
else
  oci iam user api-key upload --user-id "$USER_OCID" --key-file "$PUBFILE" >/dev/null && \
    echo "== API key di-upload (fp: $FP)"
fi
rm -f "$PUBFILE"

# --- 4. cari compartment OCID ----------------------------------
COMP_OCID=$(oci iam compartment list --compartment-id "$TENANCY" --access-level ACCESSIBLE --all \
            --query "data[?name=='$COMP_NAME' && lifecycleState=='ACTIVE'].id | [0]" --raw-output 2>/dev/null)

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
echo "Selesai. Salin blok di atas lalu kirim balik ke Hermes (aman — tidak ada secret)."
