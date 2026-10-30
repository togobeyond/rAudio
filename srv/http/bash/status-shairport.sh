#!/bin/bash

# shairport.service > this:
#    - keeps rAudio's AirPlay state in sync with shairport-sync over D-Bus
#
# This service is enabled at boot and does NOT rely on
# sessioncontrol.run_this_before_play_begins - AirPlay 2 does not reliably
# run that hook, which left rAudio in MPD mode while AirPlay was playing.

. /srv/http/bash/common.sh

signal_time2ms() {
	s=${signal_time:12:14} # signal time=1789821430.049331 ... > 1789821430.049 (s)
	echo ${s/.}            # 1789821430049 (ms)
}

# switch rAudio to the AirPlay player as soon as a session starts
airplayStart() {
	playerActive airplay && return
	playerStart airplay
	date +%s%3N > $dirshm/timestamp
}

# pick up a session that is already running when this service starts
state=$( busctl get-property org.gnome.ShairportSync /org/gnome/ShairportSync \
	org.gnome.ShairportSync.RemoteControl PlayerState 2> /dev/null )
case $state in
	*'"Playing"'*|*'"Paused"'* )
		airplayStart
		pushStatus
		;;
esac

dbus-monitor \
	--system \
	"type=signal,
	interface=org.freedesktop.DBus.Properties,
	member=PropertiesChanged,
	path=/org/gnome/ShairportSync" 2>/dev/null |
		while read line; do
			case $line in
				*PropertiesChanged )
					signal_time=$line
					;;
				*variant*'"Playing"' )
					airplayStart
					pushStatus
					;;
				*'"Metadata"' )
					pushStatus
					;;
				*variant*'"Paused"' ) # ProgressString not change on Paused - calculate for elapsed
					[[ $signal_time ]] || continue
					ms_pause=$( signal_time2ms )
					[[ -e $dirshm/timestamp ]] && ms_prog=$( < $dirshm/timestamp )
					if [[ $ms_prog ]]; then
						echo $(( ( ms_pause - ms_prog + 500 ) / 1000 )) > $dirshm/elapsed # (s)
					fi
					pushStatus
					;;
				*'"ProgressString"' )
					signal_time2ms > $dirshm/timestamp # epoch (ms)
					pushStatus
					;;
				*variant*'"Stopped"' )
					if playerActive airplay; then
						playerStop
					fi
					;;
			esac
		done
