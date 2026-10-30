#!/bin/bash
# AirPlay 2 hotfix for rAudio armv7h (image i20260719 + app update 20261003+)
#
# Problem this fixes:
#   AirPlay 2 does not reliably run sessioncontrol.run_this_before_play_begins,
#   so shairport.service (the D-Bus monitor) never started and rAudio stayed in
#   MPD mode - no AirPlay title/artist/state while audio kept playing.
#
# Changes:
#   - status-shairport.sh: always-on monitor, switches to AirPlay on the Playing
#     signal (and on service start if a session is already running); does not
#     exit on Stopped; handles the session end itself
#   - common.sh: playerStop() no longer stops the monitor
#   - features.sh: AirPlay On/Off also starts/stops the monitor + nqptp
#   - shairport.service: enabled at boot
#   - /etc/shairport-sync.conf: run_this_after_play_ends removed (monitor does it)
#   - status binary: rebuilt with guards for missing ProgressString/SourceFormat
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/togobeyond/rAudio/i20261030/patches/airplay2-hotfix.sh | bash
set -u

[[ $(id -u) != 0 ]] && { echo "run as root"; exit 1; }
[[ $(uname -m) != armv7l ]] && { echo "this hotfix is armv7l only"; exit 1; }

dirbash=/srv/http/bash
unit=/etc/systemd/system/shairport.service
conf=/etc/shairport-sync.conf
base=https://raw.githubusercontent.com/togobeyond/rAudio/a37709297a5c1a1ba07c65b055b063ca8f5b4e4b
backup=/root/airplay2-hotfix-$(date +%Y%m%d-%H%M%S)

[[ ! -e $dirbash/status ]] && { echo "not an rAudio install: $dirbash/status missing"; exit 1; }

echo "backup: $backup"
for f in common.sh status-shairport.sh settings/features.sh status; do
	[[ -e $dirbash/$f ]] || continue
	mkdir -p "$backup/$( dirname $f )"
	cp -a "$dirbash/$f" "$backup/$f"
done
cp -a "$unit" "$backup/shairport.service"
cp -a "$conf" "$backup/shairport-sync.conf"

echo "- status binary"
curl -fsSL -o "$dirbash/status.new" "$base/srv/http/bash/status.armv7h" || { echo "download failed"; exit 1; }
chmod 755 "$dirbash/status.new"
mv -f "$dirbash/status.new" "$dirbash/status"

echo "- status-shairport.sh (always-on monitor)"
curl -fsSL -o "$dirbash/status-shairport.sh.new" "$base/srv/http/bash/status-shairport.sh" || { echo "download failed"; exit 1; }
chmod 755 "$dirbash/status-shairport.sh.new"
mv -f "$dirbash/status-shairport.sh.new" "$dirbash/status-shairport.sh"

echo "- common.sh: playerStop keeps the monitor running"
sed -i '/^[[:space:]]*systemctl stop shairport # metadata$/d' "$dirbash/common.sh"
sed -i '/^[[:space:]]*\[\[ ! \$SHAIRPORT_SELF \]\] && systemctl stop shairport/d' "$dirbash/common.sh"

echo "- features.sh: monitor + nqptp follow AirPlay"
if ! grep -q 'enable --now shairport ' "$dirbash/settings/features.sh"; then
	sed -i 's|^\([[:space:]]*\)\[\[ -e \$dirmpdconf/snapserver.conf \]\] && snapclientEnable$|&\n\1[[ $CMD == shairport-sync ]] \&\& systemctl enable --now shairport \&> /dev/null|' "$dirbash/settings/features.sh"
fi
if ! grep -q 'disable --now shairport nqptp' "$dirbash/settings/features.sh"; then
	if grep -q 'disable --now nqptp' "$dirbash/settings/features.sh"; then
		sed -i 's|^\([[:space:]]*\)\[\[ \$CMD == shairport-sync \]\] && systemctl disable --now nqptp.*|\1[[ $CMD == shairport-sync ]] \&\& systemctl disable --now shairport nqptp \&> /dev/null|' "$dirbash/settings/features.sh"
	else
		sed -i '/^[[:space:]]*systemctl disable --now \$CMD$/a\		[[ $CMD == shairport-sync ]] \&\& systemctl disable --now shairport nqptp \&> /dev/null' "$dirbash/settings/features.sh"
	fi
fi

echo "- shairport.service: enable at boot + keep alive"
grep -q '^Restart=' "$unit" || sed -i '/^\[Service\]/a Restart=always\nRestartSec=5' "$unit"
grep -q '^\[Install\]' "$unit" || printf '\n[Install]\nWantedBy=multi-user.target\n' >> "$unit"
ln -sf "$unit" /etc/systemd/system/multi-user.target.wants/shairport.service

echo "- shairport-sync.conf: drop run_this_after_play_ends"
sed -i 's|^\([[:space:]]*\)run_this_after_play_ends.*|\1// session end handled by /srv/http/bash/status-shairport.sh|' "$conf"

echo "- nqptp package"
pacman -Qq nqptp &> /dev/null || pacman -S --noconfirm nqptp

systemctl daemon-reload
systemctl enable --now shairport &> /dev/null
systemctl restart shairport

sleep 2
echo
echo "=== service ==="
systemctl is-active shairport
echo "=== player ==="
cat /srv/http/data/shm/player
echo "=== status ==="
"$dirbash/status" 2>&1 | grep -E '"(state|Title|Artist|Album|sampling)"' || echo "status failed"
echo
echo "done. rollback:"
echo "  cp -a $backup/. $dirbash/ && cp -a $backup/shairport.service $unit && cp -a $backup/shairport-sync.conf $conf"
echo "  systemctl daemon-reload && systemctl restart shairport"
