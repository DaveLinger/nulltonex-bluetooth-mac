#!/bin/zsh
# Runs the read-only BLE recon under Terminal.app (which can hold Bluetooth permission).
cd "${0:A:h}/.."
mkdir -p captures
echo "Y813 read-only BLE recon. If macOS asks to allow Terminal to use Bluetooth, click Allow."
echo "Make sure the printer is ON and Pixmate is quit."
.venv/bin/python scripts/ble_recon.py --json captures/gatt-recon.json > captures/gatt-recon.log 2>&1
echo "exit=$?" >> captures/gatt-recon.log
cat captures/gatt-recon.log | tail -20
echo; echo "Done. You can close this window."
