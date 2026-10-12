#!/usr/bin/env bash
# install-systemd.sh — pasang systemd user timer (eksekusi monitor tiap 3 jam).
set -e
REPO="/home/temamumtaza/Documents/dev/oci-autoprovision"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/oci-capacity.service" <<EOF
[Unit]
Description=OCI A1 capacity monitor + auto-provisioner (idempotent)

[Service]
Type=oneshot
ExecStart=$REPO/scripts/capacity-monitor.sh
TimeoutStartSec=1800
Nice=10
IOSchedulingClass=idle
EOF

cat > "$UNIT_DIR/oci-capacity.timer" <<EOF
[Unit]
Description=Jalankan OCI capacity monitor tiap 3 jam

[Timer]
OnBootSec=7min
OnUnitActiveSec=3h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now oci-capacity.timer
echo "== timer terpasang:"
systemctl --user list-timers oci-capacity.timer --no-pager
# arsip notif boleh menumpuk di repo; linker notif dipasang utk cron Hermes
ln -sf "$REPO/scripts/oci-notify.sh" "$HOME/.hermes/scripts/oci-notify.sh"
echo "== notifier linked: ~/.hermes/scripts/oci-notify.sh"
