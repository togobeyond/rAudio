#!/bin/bash
# rAudio Bluetooth auto-detect fix
#
# Problem:
#   rAudio switches to the Bluetooth player through a udev rule
#   (/etc/udev/rules.d/bluetooth.rules -> settings/networks-bluetooth.sh connect).
#   That script finds the newly connected device by diffing
#   /srv/http/data/shm/Connected against the current BlueZ list. If the list is
#   stale (same device already recorded), the diff is empty and the script exits
#   without doing anything - rAudio stays in MPD mode and the phone's audio is
#   never routed, even though BlueALSA has the A2DP stream.
#
# Fix:
#   When the diff is empty on a connect event, fall back to the device that is
#   actually connected right now.
#
# Safe to re-run. Backs up the original file to /root/.
# After an rAudio update (which restores the upstream file) run this again.

set -u

[[ $(id -u) != 0 ]] && { echo "run as root"; exit 1; }

f=/srv/http/bash/settings/networks-bluetooth.sh
[[ -e $f ]] || { echo "not an rAudio install: $f missing"; exit 1; }

if grep -q 'stale Connected' "$f"; then
	echo "already applied"
	exit 0
fi

backup=/root/networks-bluetooth.sh.bak-$( date +%Y%m%d-%H%M%S )
cp -a "$f" "$backup"
echo "backup: $backup"

python3 - "$f" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

old = (
    "\tif [[ $d ]]; then\n"
    "\t\tMAC=$( cut -d' ' -f3 <<< $d )"
)
new = (
    "\tif [[ ! $d && $ACTION == connect ]]; then # stale Connected - use the device connected now\n"
    "\t\tMAC=$( bluetoothctl devices Connected | awk '{print $2}' | head -1 )\n"
    "\tfi\n"
    "\tif [[ $d || $MAC ]]; then\n"
    "\t\t[[ ! $MAC ]] && MAC=$( cut -d' ' -f3 <<< $d )"
)

if old not in src:
    sys.stderr.write("pattern not found - upstream changed? nothing applied\n")
    sys.exit(2)

open(path, "w").write(src.replace(old, new, 1))
PY
rc=$?

if (( rc != 0 )); then
	cp -a "$backup" "$f"
	echo "patch failed, restored original"
	exit 1
fi

if ! bash -n "$f"; then
	cp -a "$backup" "$f"
	echo "syntax error, restored original"
	exit 1
fi

echo "applied"
grep -n 'stale Connected' "$f"
echo
echo "Next: reconnect the phone. If it was already connected, run:"
echo "  bluetoothctl disconnect <MAC> && bluetoothctl connect <MAC>"
