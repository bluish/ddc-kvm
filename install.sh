#!/bin/sh
# Build and install kvm for your user. Needs Go to build, ddcutil to run, and
# i2c-dev loaded for DDC/CI.
set -e
cd "$(dirname "$0")"
command -v ddcutil >/dev/null || { echo "Install ddcutil first."; exit 1; }
go build -trimpath -o kvm .
install -Dm755 kvm "$HOME/.local/bin/kvm"
install -Dm644 kvm-serve.service "$HOME/.config/systemd/user/kvm-serve.service"
systemctl --user daemon-reload
if [ ! -f "$HOME/.config/kvm/config.json" ]; then
  echo "Write ~/.config/kvm/config.json (start from examples/), then: kvm status"
else
  echo "kvm installed. Try: kvm status"
fi
