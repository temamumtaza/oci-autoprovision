# Konfigurasi oci-autoprovision — tidak ada secret di file ini
REPO="/home/temamumtaza/Documents/dev/oci-autoprovision"
OCI_BIN="$HOME/tools/oci-venv/bin/oci"
export SUPPRESS_LABEL_WARNING=True

TENANCY="ocid1.tenancy.oc1..aaaaaaaa2mjyndqomlaiof2cj7e6bztajo3xz4mvqpg5ztwduhkryyuhdyla"
COMPARTMENT="ocid1.compartment.oc1..aaaaaaaag7yfbyvpxsrpdd5d6zpl6i4yw3smcy5iz4frcppmblrrtqkwmuya"
REGION="ap-batam-1"
AD="Xegm:AP-BATAM-1-AD-1"
SUBNET_PUBLIC="ocid1.subnet.oc1.ap-batam-1.aaaaaaaaaottn555hsc5ueadr5b56sgl2q77p5wdbjoo6sskle3aqzdidwla"

# Template ter-approve (sekali setuju, berlaku sampai diubah): Always Free 2/12/100GB
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEM_GB=12
BOOT_GB=100
DISPLAY_NAME="hermes-a1-lab"

SSH_KEY="$HOME/.ssh/oci_lab_ed25519"
SSH_PUB="$HOME/.ssh/oci_lab_ed25519.pub"
USER_DATA="$REPO/cloud-init/user-data.yaml"

STATE="$REPO/var/state.json"
LOG="$REPO/var/monitor.log"

# Batas aman
COST_GUARD_USD=25          # skip create kalau pemakaian 7 hari > ini
MAX_TRIES_API=3            # retry utk call GET
ERR_NOTIFY_EVERY=8         # error beruntun: notif di ke-N dan tiap ke-8
