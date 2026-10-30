#!/bin/bash
# AirPlay 2 hotfix for rAudio armv7h
#
# Target: official image i20260719 + built-in update (app code 20261003+),
#         or any armv7h system where status.sh is the C++ status binary.
#
# Fixes:
#   - status aborted when AirPlay 2 provided no ProgressString / SourceFormat
#   - Metadata was queried on the wrong D-Bus name+path, so track info never showed
#   - idle AirPlay was reported as pause instead of stop
#   - playerStop() stopped shairport.service from inside itself, losing cleanup
#   - nqptp kept running after AirPlay was turned off
#
# Usage:  curl -fsSL https://raw.githubusercontent.com/togobeyond/rAudio/i20261030/patches/airplay2-hotfix.sh | bash
set -u

[[ $(id -u) != 0 ]] && { echo "run as root"; exit 1; }
[[ $(uname -m) != armv7l ]] && { echo "this hotfix is armv7l only"; exit 1; }

dirbash=/srv/http/bash
base=https://raw.githubusercontent.com/togobeyond/rAudio/i20261030
backup=/root/airplay2-hotfix-$(date +%Y%m%d-%H%M%S)

[[ ! -e $dirbash/status ]] && { echo "not an rAudio install: $dirbash/status missing"; exit 1; }

echo "backup: $backup"
for f in common.sh status-shairport.sh settings/features.sh status; do
	[[ -e $dirbash/$f ]] || continue
	mkdir -p "$backup/$( dirname $f )"
	cp -a "$dirbash/$f" "$backup/$f"
done

echo "- status binary"
curl -fsSL -o "$dirbash/status.new" "$base/srv/http/bash/status.armv7h" || { echo "download failed"; exit 1; }
chmod 755 "$dirbash/status.new"
mv -f "$dirbash/status.new" "$dirbash/status"

echo "- status-shairport.sh"
curl -fsSL -o "$dirbash/status-shairport.sh.new" "$base/srv/http/bash/status-shairport.sh" || { echo "download failed"; exit 1; }
chmod 755 "$dirbash/status-shairport.sh.new"
mv -f "$dirbash/status-shairport.sh.new" "$dirbash/status-shairport.sh"

echo "- common.sh: playerStop self-stop guard"
if grep -q '^[[:space:]]*systemctl stop shairport # metadata$' "$dirbash/common.sh"; then
	sed -i 's|^\([[:space:]]*\)systemctl stop shairport # metadata$|\1[[ ! $SHAIRPORT_SELF ]] \&\& systemctl stop shairport # metadata|' "$dirbash/common.sh"
fi

echo "- features.sh: stop nqptp with AirPlay"
if ! grep -q 'disable --now nqptp' "$dirbash/settings/features.sh"; then
	sed -i '/^[[:space:]]*systemctl disable --now \$CMD$/a\		[[ $CMD == shairport-sync ]] \&\& systemctl disable --now nqptp \&> /dev/null' "$dirbash/settings/features.sh"
fi

echo "- nqptp package"
pacman -Qq nqptp &> /dev/null || pacman -S --noconfirm nqptp

chmod 755 "$dirbash/status" "$dirbash/status-shairport.sh"
systemctl restart shairport-sync 2> /dev/null || true

echo
echo "=== shairport-sync ==="
shairport-sync -V 2> /dev/null | head -1
echo "=== nqptp ==="
systemctl is-active nqptp 2> /dev/null || true
echo "=== status ==="
"$dirbash/status" 2>&1 | head -5 || echo "status failed"
echo
echo "done. rollback: cp -a $backup/. $dirbash/"
