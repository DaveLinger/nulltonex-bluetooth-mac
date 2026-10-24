#!/bin/zsh
# Send a prepared job file under Terminal.app (Bluetooth permission). Job path in $Y813_JOB or jobs/next.bin.
cd "${0:A:h}/.."
mkdir -p captures
JOB="${Y813_JOB:-jobs/next.bin}"
echo "Sending $JOB"
.venv/bin/python scripts/y813_send.py --replay "$JOB" 2>&1 | tee captures/send.log
echo "exit=$pipestatus[1]" >> captures/send.log
echo; echo "Done. You can close this window."
