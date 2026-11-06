#!/bin/bash
#
# rAudio (Raspberry Pi 4 / 64bit) 기기 설정 provision 스크립트
#
#   - NAS 자동 마운트 (fstab + x-systemd.automount)
#   - 한국 라디오 15채널 + 갱신 타이머
#   - MPD/AirPlay 워치독 (MPD 교착, player 고착, DAC 설정 표류)
#   - NAS 워치독 (CIFS 세션 끊김)
#   - USB DAC 안정화 (udev 훅, hw:CARD 이름 고정, 허브 절전, alsa 링크 루프)
#
# 사용법:
#   sudo ./provision.sh --check          # 현재 상태만 점검
#   sudo ./provision.sh                  # 적용 (설정 파일 값 사용)
#   sudo ./provision.sh --nas-src //192.168.1.4/win/music \
#        --nas-user carrot --nas-pass 'secret'
#
# 설정 파일(선택): /etc/raudio-provision.conf
#   NAS_SRC="//192.168.1.4/win/music"
#   NAS_USER="carrot"
#   NAS_PASS="secret"
#   DAC_NAME="E30 II Lite"
#   DAC_CARD="Lite"
#   DAC_USBID="152a:8750"

set -uo pipefail

# ---------------------------------------------------------------- defaults
NAS_SRC=""
NAS_USER=""
NAS_PASS=""
DAC_NAME="E30 II Lite"
DAC_CARD="Lite"
DAC_USBID="152a:8750"

MOUNT_POINT=/mnt/MPD/NAS
CHECK=0
CONF=/etc/raudio-provision.conf
[[ -f $CONF ]] && . "$CONF"

# ---------------------------------------------------------------- args
while [[ $# -gt 0 ]]; do
    case $1 in
        --check)      CHECK=1; shift ;;
        --nas-src)    NAS_SRC=$2; shift 2 ;;
        --nas-user)   NAS_USER=$2; shift 2 ;;
        --nas-pass)   NAS_PASS=$2; shift 2 ;;
        --dac-name)   DAC_NAME=$2; shift 2 ;;
        --dac-card)   DAC_CARD=$2; shift 2 ;;
        --dac-usbid)  DAC_USBID=$2; shift 2 ;;
        -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ $CHECK == 0 && $EUID -ne 0 ]] && { echo "root 권한이 필요합니다 (sudo)" >&2; exit 1; }

# ---------------------------------------------------------------- helpers
ok()   { printf '  [ OK ] %s\n' "$*"; }
miss() { printf '  [MISS] %s\n' "$*"; }
info() { printf '  [ .. ] %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

# put <path> <mode>   (표준입력 내용을 파일로)
put() {
    local path=$1 mode=$2 tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        ok "$path (변경 없음)"
    elif [[ $CHECK == 1 ]]; then
        miss "$path"
    else
        install -D -m "$mode" "$tmp" "$path"
        ok "$path"
    fi
    rm -f "$tmp"
}

svc_ok() {  # <unit>  — 타이머는 active 까지, oneshot 서비스는 enabled 만
    local u=$1 good=0
    systemctl is-enabled --quiet "$u" 2>/dev/null || good=1
    if [[ $u == *.timer ]] && ! systemctl is-active --quiet "$u" 2>/dev/null; then
        good=1
    fi
    if [[ $good == 0 ]]; then
        ok "$u"
    elif [[ $CHECK == 1 ]]; then
        miss "$u"
    else
        systemctl enable --now "$u" >/dev/null 2>&1
        ok "$u"
    fi
}

# ---------------------------------------------------------------- NAS fstab
setup_fstab() {
    head_ "NAS 자동 마운트"
    if [[ -z $NAS_SRC ]]; then
        info "NAS_SRC 미지정 — 건너뜀"
        return
    fi
    local opts line
    opts="username=$NAS_USER,password=$NAS_PASS,uid=45,gid=45,iocharset=utf8"
    opts+=",_netdev,nofail,noatime,actimeo=60,soft,echo_interval=30,noserverino"
    opts+=",x-systemd.automount,x-systemd.mount-timeout=30"
    line="$NAS_SRC $MOUNT_POINT cifs $opts 0 0"

    if grep -q " $MOUNT_POINT " /etc/fstab; then
        if [[ $(grep " $MOUNT_POINT " /etc/fstab) == "$line" ]]; then
            ok "/etc/fstab"
            return
        fi
        if [[ $CHECK == 1 ]]; then
            miss "/etc/fstab (내용 불일치)"
            return
        fi
        sed -i "\| $MOUNT_POINT |d" /etc/fstab
    elif [[ $CHECK == 1 ]]; then
        miss "/etc/fstab ($MOUNT_POINT 항목 없음)"
        return
    fi

    printf '%s\n' "$line" >> /etc/fstab
    mkdir -p "$MOUNT_POINT"
    systemctl daemon-reload
    ok "/etc/fstab (등록)"
}

# ---------------------------------------------------------------- radio
install_radio() {
    head_ "한국 라디오 소스 + 갱신 타이머"

    put /usr/local/etc/radio-sources.tsv 644 <<'TSV'
http://serpent0.duckdns.org:8088/kbs1radio.pls|KBS 1라디오
http://serpent0.duckdns.org:8088/kbs2radio.pls|KBS 해피FM
http://serpent0.duckdns.org:8088/kbs3radio.pls|KBS 3라디오
http://serpent0.duckdns.org:8088/kbsfm.pls|KBS 클래식FM
http://serpent0.duckdns.org:8088/kbs2fm.pls|KBS 쿨FM
http://serpent0.duckdns.org:8088/mbcfm.pls|MBC FM4U
http://serpent0.duckdns.org:8088/mbcsfm.pls|MBC 표준FM
http://serpent0.duckdns.org:8088/sbsfm.pls|SBS 파워FM
http://serpent0.duckdns.org:8088/sbslovefm.pls|SBS 러브FM
http://serpent0.duckdns.org:8088/cbsfm.pls|CBS 음악FM
http://serpent0.duckdns.org:8088/cbssfm.pls|CBS 표준FM
http://serpent0.duckdns.org:8088/ebsfm.pls|EBS FM
http://serpent0.duckdns.org:8088/tbsfm.pls|TBS FM
http://serpent0.duckdns.org:8088/gugakfm.pls|국악방송
http://serpent0.duckdns.org:8088/cpbc.pls|CPBC 평화방송
TSV

    put /usr/local/bin/radio-refresh.sh 755 <<'SCRIPT'
#!/bin/bash
# 한국 라디오 .pls 소스 → 실제 스트림 URL 자동 갱신
MAP="/usr/local/etc/radio-sources.tsv"
[ -f "$MAP" ] || exit 1

while IFS='|' read -r src name; do
    [ -n "$src" ] || continue
    case "$src" in \#*) continue ;; esac
    dir="/srv/http/data/webradio/$name"

    url=$(curl -s -m 20 "$src" | grep -m1 "^File1=" | cut -d= -f2-)
    if [ -z "$url" ]; then
        echo "skip (no url): $name"
        continue
    fi

    cur=$(head -n1 "$dir/data" 2>/dev/null)
    [ "$cur" = "$url" ] && continue

    mkdir -p "$dir"
    printf "%s\n" "$url" > "$dir/data"
    chown -R http:http "$dir"
    chmod 644 "$dir/data"
    echo "updated: $name"
done < "$MAP"

# 라디오 목록 + counts 갱신 후 UI 로 푸시 (rAudio 공식 경로)
if ! ( cd /srv/http/bash && bash -c '. ./common.sh; . ./cmd-function.sh; webradioCount' ) >/dev/null 2>&1; then
    for d in /srv/http/data/webradio /srv/http/data/dabradio; do
        [ -d "$d" ] || continue
        find -L "$d" -type f -name data 2>/dev/null | while read -r f; do
            printf "%s^^%s\n" "$(head -n1 "$f")" "$(dirname "$f")"
        done
    done > /tmp/radio.new
    mv /tmp/radio.new /srv/http/data/mpd/radio
    systemctl try-restart radio >/dev/null 2>&1
fi

exit 0
SCRIPT

    put /etc/systemd/system/radio-refresh.service 644 <<'UNIT'
[Unit]
Description=Refresh Korean radio stream URLs
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/radio-refresh.sh
UNIT

    put /etc/systemd/system/radio-refresh.timer 644 <<'UNIT'
[Unit]
Description=Refresh Korean radio stream URLs every 6h

[Timer]
OnBootSec=3min
OnCalendar=*-*-* 00/6:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
}

# ---------------------------------------------------------------- watchdogs
install_watchdogs() {
    head_ "MPD / AirPlay 워치독"

    put /usr/local/bin/radio-watchdog.sh 755 <<'SCRIPT'
#!/bin/bash
# MPD/AirPlay 상태 감시 → 자동 복구
STATE=/run/radio-watchdog.fail
MAX=3
PLAYER=$(cat /dev/shm/player 2>/dev/null)
DAC_MARK=/etc/raudio-dac-preferred
DAC_PAT=$(cat "$DAC_MARK" 2>/dev/null || echo "E30 II Lite")

# 1) AirPlay 재생 중인데 rAudio 인식이 어긋난 경우
if systemctl is-active --quiet shairport-sync; then
    pstate=$(timeout 3 gdbus call --system \
        --dest org.gnome.ShairportSync \
        --object-path /org/gnome/ShairportSync \
        --method org.freedesktop.DBus.Properties.Get \
        org.gnome.ShairportSync.RemoteControl PlayerState 2>/dev/null)
    case "$pstate" in
        *Playing*|*Paused*)
            if [ "$PLAYER" != "airplay" ]; then
                echo "watchdog: airplay active but player=$PLAYER - restarting shairport"
                systemctl restart shairport
            fi
            ;;
    esac
fi

# 2) player=airplay 인데 shairport 가 없으면 mpd 로 복구
if [ "$PLAYER" = "airplay" ] && ! systemctl is-active --quiet shairport-sync; then
    echo "watchdog: player stuck at airplay - reset to mpd"
    echo mpd > /dev/shm/player
    rm -f /dev/shm/pidstatuspush
    /srv/http/bash/status-push.sh >/dev/null 2>&1
fi

# 3) 선호 DAC 설정 표류 감지 → 복원
if [ -f "$DAC_MARK" ] && grep -q "$DAC_PAT" /proc/asound/cards 2>/dev/null; then
    if ! grep -q "$DAC_PAT" /srv/http/data/mpdconf/output.conf 2>/dev/null \
       || ! grep -q "$DAC_PAT" /etc/shairport-sync.conf 2>/dev/null; then
        echo "watchdog: preferred DAC config drifted - restoring"
        /usr/local/bin/usb-dac-ready.sh
    fi
fi

# 4) MPD 응답성
if timeout 5 mpc status >/dev/null 2>&1; then
    rm -f "$STATE"
    exit 0
fi

n=$(cat "$STATE" 2>/dev/null || echo 0)
n=$(( n + 1 ))
echo "$n" > "$STATE"

[ "$n" -lt "$MAX" ] && exit 0

echo "watchdog: MPD unresponsive (${n}x) - restarting"
systemctl restart mpd
sleep 5

if timeout 5 mpc status >/dev/null 2>&1; then
    echo "watchdog: MPD recovered"
    rm -f "$STATE"
else
    echo "watchdog: MPD still failing"
    exit 1
fi

rm -f /dev/shm/pidstatuspush
/srv/http/bash/status-push.sh >/dev/null 2>&1
if [ "$(stat -c %s /dev/shm/status.json 2>/dev/null || echo 0)" -lt 10 ]; then
    /srv/http/bash/status -s > /dev/shm/status.json 2>/dev/null
fi

exit 0
SCRIPT

    put /etc/systemd/system/radio-watchdog.service 644 <<'UNIT'
[Unit]
Description=MPD watchdog (auto recover)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/radio-watchdog.sh
UNIT

    put /etc/systemd/system/radio-watchdog.timer 644 <<'UNIT'
[Unit]
Description=Run MPD watchdog every minute

[Timer]
OnBootSec=2min
OnCalendar=*-*-* *:*:00
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT

    head_ "NAS 워치독"

    put /usr/local/bin/nas-watchdog.sh 755 <<'SCRIPT'
#!/bin/bash
# NAS(CIFS) 마운트 헬스체크 → 실패 시 리마운트 + MPD 복구
MNT=/mnt/MPD/NAS
STATE=/run/nas-watchdog.fail
MAX=3

if timeout 8 stat "$MNT" >/dev/null 2>&1 && timeout 8 ls "$MNT" >/dev/null 2>&1; then
    rm -f "$STATE"
    exit 0
fi

n=$(cat "$STATE" 2>/dev/null || echo 0)
n=$(( n + 1 ))
echo "$n" > "$STATE"
[ "$n" -lt "$MAX" ] && exit 0

echo "nas-watchdog: $MNT unresponsive (${n}x) - remounting"
systemctl restart mnt-MPD-NAS.automount >/dev/null 2>&1
umount -l "$MNT" >/dev/null 2>&1
sleep 3

if timeout 10 ls "$MNT" >/dev/null 2>&1; then
    echo "nas-watchdog: remount OK"
    rm -f "$STATE"
else
    echo "nas-watchdog: remount failed"
    exit 1
fi

if ! timeout 8 mpc status >/dev/null 2>&1; then
    echo "nas-watchdog: restarting mpd"
    systemctl restart mpd
fi

rm -f /dev/shm/pidstatuspush
/srv/http/bash/status-push.sh >/dev/null 2>&1
if [ "$(stat -c %s /dev/shm/status.json 2>/dev/null || echo 0)" -lt 10 ]; then
    /srv/http/bash/status -s > /dev/shm/status.json 2>/dev/null
fi

exit 0
SCRIPT

    put /etc/systemd/system/nas-watchdog.service 644 <<'UNIT'
[Unit]
Description=NAS mount watchdog (auto remount)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nas-watchdog.sh
UNIT

    put /etc/systemd/system/nas-watchdog.timer 644 <<'UNIT'
[Unit]
Description=Run NAS watchdog every 2 minutes

[Timer]
OnBootSec=5min
OnCalendar=*-*-* *:00/2:00
AccuracySec=10s

[Install]
WantedBy=timers.target
UNIT
}

# ---------------------------------------------------------------- USB DAC
install_dac() {
    head_ "USB DAC 안정화 ($DAC_NAME)"

    local vend prod
    vend=${DAC_USBID%%:*}
    prod=${DAC_USBID##*:}

    local content
    content=$(cat <<'SCRIPT'
#!/bin/bash
# USB DAC 재연결 시
#  1) DAC 카드가 올라올 때까지 대기
#  2) MPD output.conf / shairport 설정이 다른 장치로 폴백돼 있으면 DAC 으로 복원
#  3) 오디오 서비스 재시작
#  4) AirPlay 세션이 끊긴 채 player=airplay 로 남아 있으면 mpd 로 복구

CONF="/srv/http/data/mpdconf/output.conf"
SHAIR="/etc/shairport-sync.conf"
CARDPAT="__DAC_NAME__"
CARDNAME="__DAC_CARD__"

for i in $(seq 1 10); do
    grep -q "$CARDPAT" /proc/asound/cards 2>/dev/null && break
    sleep 1
done

grep -q "$CARDPAT" /proc/asound/cards 2>/dev/null || exit 0

# MPD 출력
if ! grep -q "$CARDPAT" "$CONF" 2>/dev/null; then
    echo "usb-dac-ready: restoring mpd output -> $CARDPAT"
    cat > "$CONF" <<EOF
audio_output {
	name           "__DAC_NAME__"
	device         "hw:CARD=$CARDNAME"
	type           "alsa"
	auto_resample  "no"
	auto_format    "no"
	mixer_type     "none"
}
EOF
    chown root:root "$CONF"
    chmod 644 "$CONF"
fi

# shairport 출력 (rAudio 는 폴백 시 이 파일도 덮어쓴다)
if ! grep -q "$CARDPAT" "$SHAIR" 2>/dev/null; then
    echo "usb-dac-ready: restoring shairport output -> $CARDPAT"
    sed -i '/^alsa = {/,/^}/c\
alsa = {\
	output_device = "hw:CARD='"$CARDNAME"'";\
	mixer_control_name = "'"$CARDPAT"'";\
}' "$SHAIR"
fi

systemctl try-restart mpd shairport-sync

if [ "$(cat /dev/shm/player 2>/dev/null)" = "airplay" ]; then
    echo "usb-dac-ready: reset player -> mpd"
    echo mpd > /dev/shm/player
    rm -f /dev/shm/pidstatuspush
    /srv/http/bash/status-push.sh >/dev/null 2>&1
fi

exit 0
SCRIPT
)
    content=${content//__DAC_NAME__/$DAC_NAME}
    content=${content//__DAC_CARD__/$DAC_CARD}
    printf '%s\n' "$content" | put /usr/local/bin/usb-dac-ready.sh 755

    put /etc/systemd/system/usb-dac-ready.service 644 <<'UNIT'
[Unit]
Description=USB DAC reconnect - restart audio services
After=sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb-dac-ready.sh
UNIT

    put /etc/udev/rules.d/99-raudio-dac.rules 644 <<UDEV
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="$vend", ATTR{idProduct}=="$prod", TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-dac-ready.service"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2109", ATTR{idProduct}=="3431", ATTR{power/control}="on"
UDEV

    head_ "ALSA 링크 루프 교정"

    put /usr/local/bin/alsa-shm-fix.sh 755 <<'SCRIPT'
#!/bin/bash
# rAudio startup.sh 의 `mv /var/lib/alsa $dirshm/alsa` 는
# /var/lib/alsa 가 이미 심볼릭 링크이면 링크 자체를 옮겨 자기 참조 루프를 만든다.
if [ -L /dev/shm/alsa ]; then
    tgt=$(readlink -f /dev/shm/alsa 2>/dev/null)
    rm -f /dev/shm/alsa
    mkdir -p /dev/shm/alsa
    if [ -n "$tgt" ] && [ -f "$tgt/asound.state" ]; then
        cp -f "$tgt/asound.state" /dev/shm/alsa/ 2>/dev/null
    fi
fi
[ -d /dev/shm/alsa ] || mkdir -p /dev/shm/alsa
if [ ! -e /var/lib/alsa ] && [ ! -L /var/lib/alsa ]; then
    ln -s /dev/shm/alsa /var/lib/alsa
fi
exit 0
SCRIPT

    put /etc/systemd/system/alsa-shm-fix.service 644 <<'UNIT'
[Unit]
Description=Fix /dev/shm/alsa symlink loop
After=startup.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alsa-shm-fix.sh

[Install]
WantedBy=multi-user.target
UNIT
}

# ---------------------------------------------------------------- apply
apply() {
    setup_fstab
    install_radio
    install_watchdogs
    install_dac

    head_ "선호 출력 마커"
    if [[ -f /etc/raudio-dac-preferred ]]; then
        ok "/etc/raudio-dac-preferred"
    elif [[ $CHECK == 1 ]]; then
        miss "/etc/raudio-dac-preferred"
    else
        echo "$DAC_NAME" > /etc/raudio-dac-preferred
        ok "/etc/raudio-dac-preferred"
    fi

    head_ "서비스 / 타이머"
    [[ $CHECK == 0 ]] && systemctl daemon-reload && udevadm control --reload-rules
    svc_ok radio-refresh.timer
    svc_ok radio-watchdog.timer
    svc_ok nas-watchdog.timer
    svc_ok alsa-shm-fix.service

    if [[ $CHECK == 0 ]]; then
        head_ "라디오 스테이션 생성"
        /usr/local/bin/radio-refresh.sh
        echo "  채널 수: $(ls /srv/http/data/webradio 2>/dev/null | wc -l)"
    fi
}

# ---------------------------------------------------------------- main
printf 'rAudio provision %s\n' "$([[ $CHECK == 1 ]] && echo '(check only)' || echo '(apply)')"
apply

if [[ $CHECK == 1 ]]; then
    printf '\n점검 완료. [MISS] 항목은 sudo %s 로 적용하세요.\n' "$0"
else
    printf '\n적용 완료.\n'
fi
