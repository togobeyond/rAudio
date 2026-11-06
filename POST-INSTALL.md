# rAudio 설치 가이드 — Raspberry Pi 4 / 64bit

재설치할 때 **무엇이 이미 제공되고, 무엇을 내가 해야 하는지** 기준으로 정리했습니다.

---

## 0. 전체 구조

| 계층 | 대상 | 하는 일 | 소요 |
|---|---|---|---|
| **A. 공식 이미지** | `rAudio-64bit-20260719.img` | 굽고 부팅. 기본 시스템·웹 UI·MPD 구성 | 10분 |
| **B. 업스트림 업데이트** | Addons → Update → **20261101** | 이미지 이후 수정분 반영 (AirPlay 포트 충돌 해결 등) | 5~10분 |
| **C. 내가 반영** | 수동 설정 6가지 | NAS · 라디오 · 워치독 · DAC · 편의 | 30분 + 스캔 45분 |

**순서를 지켜야 하는 이유**: B(업데이트)를 먼저 해야 C의 AirPlay 설정에서 웹 UI가 멈추지 않습니다.

```
A 이미지 → 부팅 → B 업데이트 → 재부팅 → C 수동 반영
```

---

# A. 공식 이미지

## A-1. 굽기 (macOS)

```bash
diskutil list external                             # 대상 SD카드 확인 (예: disk6)
diskutil unmountDisk force /dev/disk6
sudo dd if=~/Downloads/rAudio-64bit-20260719.img of=/dev/rdisk6 bs=4m
sync
diskutil list disk6                                # BOOT + Linux 확인
diskutil eject disk6
```

굽은 뒤 부트 파티션 검증:

```bash
diskutil mount /dev/disk6s1
cat /Volumes/BOOT/cmdline.txt      # root=PARTUUID=xxxxxxxx-02 이어야 정상
ls -lh /Volumes/BOOT/kernel8.img   # 64bit 커널
diskutil unmount /Volumes/BOOT
```

> `root=` 가 비어 있으면(`root= rw ...`) 커널이 루트를 못 찾아 부팅이 멈춥니다.
> 공식 이미지는 정상이지만, 직접 빌드한 이미지는 확인이 필요합니다.

## A-2. 첫 부팅과 검증

```bash
ssh root@<Pi IP>          # 기본 암호: ros

df -h /                   # 카드 크기로 확장됐는지
systemctl --failed        # 0 loaded units
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/    # 200
```

## A-3. 이미지가 기본 제공하는 것

| 항목 | 상태 |
|---|---|
| 루트 파티션 자동 확장 | 첫 부팅 시 카드 끝까지 |
| 웹 서버 | `nginx` + `php-fpm` 활성 |
| MPD | `mpd` 활성, `music_directory = /mnt/MPD` |
| WebSocket | `websocket` 활성 (UI 필수) |
| SSH | `sshd` 활성 |
| AirPlay | `shairport-sync` / `nqptp` **모두 disabled** |
| 웹라디오 | Radio Paradise 5개 포함 |
| 계정 | `root` / `ros` |

## A-4. 이미지 기본값에서 알아둘 점

- **AirPlay는 꺼져 있습니다.** 쓰려면 B 이후 C에서 활성화
- **Radio Paradise 5개**가 기본 포함 → C-3에서 삭제
- **NAS는 자동 마운트되지 않습니다.** C-2에서 등록
- 카드가 여러 개면 mDNS(호스트명 `rAudio`)가 충돌할 수 있음

---

# B. 업스트림 업데이트

## B-1. 적용

```
웹 UI → Addons → Update
```

```bash
cat /srv/http/data/addons/r1      # → 20261101 (이상)
```

업데이트 후 **재부팅 1회**.

## B-2. 이 업데이트가 해결하는 것

- **`nqptp`(AirPlay 2) ↔ `websocket` UDP 9000 포트 충돌**
  - 업데이트 전: `websocket.py` 가 9000을 하드코딩 → nqptp와 경합 → 진 쪽 실패
  - 업데이트 후: `status -Bp` 에서 포트를 받아옴(9001) → 충돌 없음
- 결과적으로 **AirPlay 2를 켜도 웹 UI가 멈추지 않음**

> 업데이트 전 이미지에서 AirPlay를 켜면 `websocket.service` 가 실패하고
> **UI가 로딩 화면에서 멈춥니다.** 그래서 B를 먼저 해야 합니다.

## B-3. 업데이트가 건드리지 않는 것

C에서 만드는 아래 파일들은 **재설치·업데이트와 무관**합니다.

```
/usr/local/bin/*.sh                      라디오 갱신 · 워치독 · DAC · alsa
/etc/systemd/system/*.service, *.timer
/etc/udev/rules.d/
/etc/fstab                               NAS 마운트
/srv/http/data/                          설정 · 라디오 · MPD DB
```

반대로 **`/srv/http/bash/` 아래는 덮어써집니다** (수동 패치는 사라짐).

## B-4. 업데이트 후 확인

```bash
systemctl --failed                        # 0 loaded units
systemctl is-active websocket             # active
ss -ulnp | grep -E ':9000|:9001'          # nqptp:9000 / websocket:9001
```

---

# C. 내가 반영할 것

## C-0. 반영 순서

| 순서 | 항목 | 절 | 비고 |
|---|---|---|---|
| 1 | root 비밀번호 | C-1 | 필수 |
| 2 | AirPlay 2 (선택) | C-2 | B 이후에만 |
| 3 | NAS 자동 마운트 | C-3 | MPD 스캔 45분 |
| 4 | 웹라디오 15채널 | C-4 | 기본 방송 삭제 포함 |
| 5 | MPD 워치독 | C-5 | |
| 6 | USB DAC 안정화 | C-6 | 재생 잠깐 중단 |
| 7 | htop | C-7 | |

## C-1. root 비밀번호

```bash
passwd
```

## C-2. AirPlay 2 (선택)

이미지 기본값은 `shairport-sync` / `nqptp` **모두 disabled** 입니다.

```bash
systemctl enable --now nqptp            # AirPlay 2 필수 (PTP 타이밍)
systemctl enable --now shairport-sync   # RAOP

avahi-browse -t _airplay._tcp | grep -i raudio   # 광고 확인
ss -tlnp | grep 7000                             # AirPlay 2 포트
```

**품질 참고**: AirPlay 2는 송신 측에서 AAC 256kbps로 재인코딩 → 손실.
무손실·Hi-Res는 MPD(C-3의 NAS 파일 직접 재생)를 사용합니다.

## C-3. NAS 자동 마운트

### fstab 등록

SMB는 하위 폴더만 따로 마운트할 수 없으므로 **소스 경로에 하위 디렉터리를 포함**합니다.

```bash
cat >> /etc/fstab <<'EOF'
//<NAS IP>/win/music /mnt/MPD/NAS cifs username=<USER>,password=<PASS>,uid=45,gid=45,iocharset=utf8,_netdev,nofail,noatime,actimeo=60,soft,echo_interval=30,noserverino,x-systemd.automount,x-systemd.mount-timeout=30 0 0
EOF
mkdir -p /mnt/MPD/NAS
systemctl daemon-reload
ls /mnt/MPD/NAS          # 첫 접근 시 자동 마운트
findmnt /mnt/MPD/NAS
```

| 옵션 | 이유 |
|---|---|
| `uid=45,gid=45` | MPD 사용자 소유 (Arch 기준 mpd uid/gid = 45) |
| `iocharset=utf8` | 한글 폴더명 |
| `actimeo=60` | 속성 캐시 60초. 스캔 2~3배 향상 (기본 1초) |
| `soft` | 서버 무응답 시 무한 대기 대신 오류 반환 |
| `echo_interval=30` | keepalive 30초. 끊김을 더 빨리 감지 (기본 60) |
| `noserverino` | inode 재사용 경고 제거 |
| `x-systemd.automount` | **부팅 시 네트워크 경합 회피** (필수) |
| `_netdev,nofail` | NAS가 꺼져 있어도 부팅 지속 |

> ⚠️ `_netdev,nofail` 만 쓰면 부팅 시 `cifs_mount failed w/return code = -101` 로
> 실패하고 재시도하지 않습니다. 반드시 `x-systemd.automount` 를 함께 쓰세요.

### NAS 워치독 (끊김 자동 복구)

NAS의 SMB 세션이 몇 시간마다 끊기면(`CIFS: ... has not responded in 180 seconds`)
MPD가 I/O에 묶여 **웹 UI와 AirPlay가 함께 멈춥니다**. 2분마다 확인해 자동 리마운트합니다.

`/usr/local/bin/nas-watchdog.sh`:

```bash
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
```

`/etc/systemd/system/nas-watchdog.service`:

```ini
[Unit]
Description=NAS mount watchdog (auto remount)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nas-watchdog.sh
```

`/etc/systemd/system/nas-watchdog.timer`:

```ini
[Unit]
Description=Run NAS watchdog every 2 minutes

[Timer]
OnBootSec=5min
OnCalendar=*-*-* *:00/2:00
AccuracySec=10s

[Install]
WantedBy=timers.target
```

```bash
chmod 755 /usr/local/bin/nas-watchdog.sh
systemctl daemon-reload
systemctl enable --now nas-watchdog.timer
systemctl list-timers nas-watchdog.timer
```

### MPD 스캔

```bash
mpc update
mpc status | head -1                    # Updating DB → 사라지면 완료
mpc stats | egrep 'Artists|Albums|Songs'
```

- 17,680개 파일 기준 **40~45분**
- 스캔 중에는 곡 수가 늘지 않음 (완료 시 일괄 커밋)

## C-4. 웹라디오 15채널

### 1) 기본 방송 삭제

**업데이트 후 다시 생기므로 B를 마친 뒤** 실행합니다.

```bash
rm -rf /srv/http/data/webradio/Radio*
```

### 2) 구조

```
/srv/http/data/webradio/<방송 이름>/data   ← 1번째 줄: 스트림 URL
/srv/http/data/mpd/radio                   ← "URL^^경로" 목록 (자동 생성)
```

KBS·MBC·SBS 등은 **서명 토큰이 붙은 HLS(m3u8)** 를 `.pls` 로 감싼 형태입니다.
MPD는 원격 `.pls`를 읽지 못하므로 m3u8 주소를 저장하고 주기적으로 갱신합니다.

### 3) 소스 목록

`/usr/local/etc/radio-sources.tsv` — `pls주소|방송이름`

```
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
```

### 4) 갱신 스크립트

`/usr/local/bin/radio-refresh.sh`:

```bash
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
```

`/etc/systemd/system/radio-refresh.service`:

```ini
[Unit]
Description=Refresh Korean radio stream URLs
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/radio-refresh.sh
```

`/etc/systemd/system/radio-refresh.timer`:

```ini
[Unit]
Description=Refresh Korean radio stream URLs every 6h

[Timer]
OnBootSec=3min
OnCalendar=*-*-* 00/6:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

### 5) 적용

```bash
chmod 755 /usr/local/bin/radio-refresh.sh
systemctl daemon-reload
systemctl enable --now radio-refresh.timer
systemctl start radio-refresh.service        # 즉시 1회 → 15채널 생성
systemctl list-timers radio-refresh.timer
ls /srv/http/data/webradio
```

> 채널 추가/삭제 후에도 `radio-refresh.service` 를 한 번 실행하면
> `counts`·목록·UI 푸시가 함께 갱신됩니다.
> 그래도 화면 숫자가 그대로면 **브라우저 강제 새로고침(⌘⇧R)**.

## C-5. MPD / AirPlay 워치독

세 가지 상황을 1분마다 감시합니다.

1. HLS 라디오 전환 중 MPD 교착 → `status.json` 이 비어 UI 정지
2. AirPlay 재생 중인데 rAudio 인식이 어긋남 (`player` ≠ `airplay`) → UI 무반응
3. `player=airplay` 인데 shairport 가 죽음 → UI가 AirPlay 모드에 고정

`/usr/local/bin/radio-watchdog.sh`:

```bash
#!/bin/bash
# MPD/AirPlay 상태 감시 → 자동 복구
#  - shairport-sync 가 Playing 인데 rAudio 가 airplay 로 인식하지 못하면 메타데이터 감시 재시작
#  - player 가 airplay 로 고정된 채 shairport 가 없으면 mpd 로 복구
#  - mpc status 가 연속 3회 실패하면 mpd 재시작 + status.json 재생성

STATE=/run/radio-watchdog.fail
MAX=3
PLAYER=$(cat /dev/shm/player 2>/dev/null)

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

# 2) player=airplay 인데 shairport 가 없으면 mpd 로 복구 (UI 빈 화면 방지)
if [ "$PLAYER" = "airplay" ] && ! systemctl is-active --quiet shairport-sync; then
    echo "watchdog: player stuck at airplay - reset to mpd"
    echo mpd > /dev/shm/player
    rm -f /dev/shm/pidstatuspush
    /srv/http/bash/status-push.sh >/dev/null 2>&1
fi

# 3) MPD 응답성
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
```

`/etc/systemd/system/radio-watchdog.service`:

```ini
[Unit]
Description=MPD watchdog (auto recover)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/radio-watchdog.sh
```

`/etc/systemd/system/radio-watchdog.timer`:

```ini
[Unit]
Description=Run MPD watchdog every minute

[Timer]
OnBootSec=2min
OnCalendar=*-*-* *:*:00
AccuracySec=5s

[Install]
WantedBy=timers.target
```

```bash
chmod 755 /usr/local/bin/radio-watchdog.sh
systemctl daemon-reload
systemctl enable --now radio-watchdog.timer
systemctl list-timers radio-watchdog.timer
```

| 항목 | 내용 |
|---|---|
| 확인 주기 | 1분 |
| 복구 조건 | `mpc status` 3회 연속 실패 (≈3분) |
| 부하 | 분당 `mpc status` 1회 (수 ms) |

## C-6. USB DAC 안정화

### 증상과 원인

장시간 유휴 후 재생하면 DAC로 소리가 안 나고, 재부팅해야 복구됩니다.
DAC이 USB에서 **재열거**되는데 오디오 서비스가 죽은 ALSA 핸들을 붙잡기 때문입니다.

```bash
aplay -l | grep -i usb              # 카드 번호/이름
cat /proc/asound/card2/id           # → Lite      (hw:CARD= 에 사용)
cat /proc/asound/card2/usbid        # → 152a:8750 (udev 규칙에 사용)
journalctl -b -1 -k | grep "new high-speed USB device"   # 재열거 이력
```

### ① DAC 재연결 시 자동 복구

DAC이 빠지면 **rAudio가 온보드 이어폰 출력으로 폴백**하며 **두 파일을 모두 덮어씁니다**.
DAC이 돌아와도 되돌리지 않으므로, 훅에서 둘 다 복원해야 합니다.

```
/srv/http/data/mpdconf/output.conf      MPD 출력
/etc/shairport-sync.conf                AirPlay(shairport) 출력
```

`/usr/local/bin/usb-dac-ready.sh`:

```bash
#!/bin/bash
# USB DAC 재연결 시
#  1) DAC 카드가 올라올 때까지 대기
#  2) MPD output.conf / shairport 설정이 다른 장치로 폴백돼 있으면 DAC 으로 복원
#  3) 오디오 서비스 재시작
#  4) AirPlay 세션이 끊긴 채 player=airplay 로 남아 있으면 mpd 로 복구

CONF="/srv/http/data/mpdconf/output.conf"
SHAIR="/etc/shairport-sync.conf"
CARDPAT="E30 II Lite"
CARDNAME="Lite"

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
	name           "Topping E30 II Lite"
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

# 재시작으로 AirPlay 세션이 끊겼으므로 player 상태를 되돌린다
if [ "$(cat /dev/shm/player 2>/dev/null)" = "airplay" ]; then
    echo "usb-dac-ready: reset player -> mpd"
    echo mpd > /dev/shm/player
    rm -f /dev/shm/pidstatuspush
    /srv/http/bash/status-push.sh >/dev/null 2>&1
fi

exit 0
```

`/etc/systemd/system/usb-dac-ready.service`:

```ini
[Unit]
Description=USB DAC reconnect - restart audio services
After=sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb-dac-ready.sh
```

`/etc/udev/rules.d/99-raudio-dac.rules`:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="152a", ATTR{idProduct}=="8750", TAG+="systemd", ENV{SYSTEMD_WANTS}="usb-dac-ready.service"
```

```bash
chmod 755 /usr/local/bin/usb-dac-ready.sh
udevadm control --reload-rules
systemctl daemon-reload
```

### ② 카드 번호 대신 이름으로 지정

```bash
cp /srv/http/data/mpdconf/output.conf /srv/http/data/mpdconf/output.conf.bak
cp /etc/shairport-sync.conf /etc/shairport-sync.conf.bak

sed -i 's|device         "hw:2"|device         "hw:CARD=Lite"|' /srv/http/data/mpdconf/output.conf
sed -i 's|output_device = "hw:2"|output_device = "hw:CARD=Lite"|' /etc/shairport-sync.conf

systemctl restart mpd shairport-sync
```

> 카드 번호가 2가 아니면(예: `hw:1`) 그 번호로 바꿔 적용합니다.
> ⚠️ rAudio UI에서 출력 장치를 다시 선택하면 `hw:2` 로 되돌아갈 수 있습니다.

### ③ USB 허브 절전 해제

DAC이 허브(`2109:3431`) 뒤에 있고 허브가 autosuspend `auto` 인 경우입니다.

`/etc/udev/rules.d/99-raudio-dac.rules` 에 한 줄 추가:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2109", ATTR{idProduct}=="3431", ATTR{power/control}="on"
```

```bash
udevadm control --reload-rules
echo on > /sys/bus/usb/devices/1-1/power/control      # 즉시 적용
```

### ④ `/var/lib/alsa` 심볼릭 링크 루프

rAudio `startup.sh` 는 부팅 시 아래를 실행합니다(비정상 종료 후 반복되면 루프 발생).

```bash
mv /var/lib/alsa $dirshm/alsa
ln -s $dirshm/alsa /var/lib
```

증상: `alsactl: ... Too many levels of symbolic links`

`/usr/local/bin/alsa-shm-fix.sh`:

```bash
#!/bin/bash
if [ -L /dev/shm/alsa ]; then
    tgt=$(readlink -f /dev/shm/alsa 2>/dev/null)
    rm -f /dev/shm/alsa
    mkdir -p /dev/shm/alsa
    [ -n "$tgt" ] && [ -f "$tgt/asound.state" ] && cp -f "$tgt/asound.state" /dev/shm/alsa/ 2>/dev/null
fi
[ -d /dev/shm/alsa ] || mkdir -p /dev/shm/alsa
if [ ! -e /var/lib/alsa ] && [ ! -L /var/lib/alsa ]; then
    ln -s /dev/shm/alsa /var/lib/alsa
fi
exit 0
```

`/etc/systemd/system/alsa-shm-fix.service`:

```ini
[Unit]
Description=Fix /dev/shm/alsa symlink loop
After=startup.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/alsa-shm-fix.sh

[Install]
WantedBy=multi-user.target
```

```bash
chmod 755 /usr/local/bin/alsa-shm-fix.sh
systemctl daemon-reload
systemctl enable --now alsa-shm-fix.service
alsactl store && echo OK
```

### 반영 후 확인

```bash
cat /etc/udev/rules.d/99-raudio-dac.rules                         # 규칙 2줄
udevadm trigger --action=add --subsystem-match=usb \
    --attr-match=idVendor=152a --attr-match=idProduct=8750
systemctl show -p Result --value usb-dac-ready.service            # success

grep device /srv/http/data/mpdconf/output.conf                    # hw:CARD=Lite
grep output_device /etc/shairport-sync.conf                       # hw:CARD=Lite

mpc clear; mpc add "NAS/jazz/<파일>"; mpc play                    # 상대경로
grep ^rate /proc/asound/card2/pcm0p/sub0/hw_params                # rate: …
mpc stop

cat /sys/bus/usb/devices/1-1/power/control                        # on
systemctl is-enabled alsa-shm-fix.service                         # enabled
```

## C-7. htop

```bash
pacman -Sy --needed --noconfirm htop
```

> ⚠️ 전체 업그레이드는 `pacman -Syu` 대신 **Addons → Update** 를 사용하세요.

## C-8. 반영 파일 요약

| 경로 | 역할 | 재설치 시 |
|---|---|---|
| `/etc/fstab` | NAS 자동 마운트 | 다시 등록 |
| `/usr/local/etc/radio-sources.tsv` | 라디오 15채널 소스 | 다시 생성 |
| `/usr/local/bin/radio-refresh.sh` | 스트림 URL 갱신 | 다시 생성 |
| `/usr/local/bin/radio-watchdog.sh` | MPD 자동 복구 | 다시 생성 |
| `/usr/local/bin/usb-dac-ready.sh` | DAC 재연결 복구 | 다시 생성 |
| `/usr/local/bin/alsa-shm-fix.sh` | alsa 링크 루프 교정 | 다시 생성 |
| `/etc/systemd/system/radio-refresh.*` | 6시간 갱신 타이머 | 다시 생성 |
| `/etc/systemd/system/radio-watchdog.*` | 1분 워치독 | 다시 생성 |
| `/etc/systemd/system/usb-dac-ready.service` | DAC 이벤트 처리 | 다시 생성 |
| `/etc/systemd/system/alsa-shm-fix.service` | 부팅 시 alsa 교정 | 다시 생성 |
| `/etc/udev/rules.d/99-raudio-dac.rules` | DAC/허브 udev | 다시 생성 |

---

# D. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| 웹 UI가 로딩에서 멈춤 | `websocket.service` 실패 (nqptp와 UDP 9000 충돌) | B 업데이트 적용. 구버전은 websocket.py 9000→9001 |
| 웹 UI가 빈 화면 (서비스는 정상) | MPD 교착 → 빈 `status.json` | 워치독이 3분 내 복구 (C-5) |
| 웹 UI가 빈 화면 (player=airplay 고정) | AirPlay 세션 비정상 종료 → `/dev/shm/player` 가 `airplay` 로 남음 | 워치독이 자동 복구. 수동: `echo mpd > /dev/shm/player` 후 `status-push.sh` |
| NAS 마운트 실패 (`-101`) | 부팅 시 네트워크 경합 | `x-systemd.automount` (C-3) |
| 스캔이 멈춘 듯 | MPD는 완료 시 일괄 커밋 | `mpc status`의 `Updating DB` 로 판단 |
| 웹라디오 `unrecognized file` | MPD가 원격 `.pls` 미지원 | 실제 스트림 URL(m3u8) 저장 (C-4) |
| 웹라디오가 며칠 뒤 재생 안 됨 | 서명 토큰 만료 | `systemctl start radio-refresh.service` |
| 라디오 개수가 예전 값 | `counts` 미갱신 또는 캐시 | `radio-refresh.service` 실행 후 ⌘⇧R |
| 장시간 유휴 후 소리 안 남 | DAC USB 재열거 + `hw:2` 고정 | C-6 (udev 자동복구 + `hw:CARD`) |
| AirPlay 연결했는데 무반응 | `shairport` 메타데이터 감시가 stale (D-Bus 연결 끊김) | `systemctl restart shairport` (워치독이 자동 처리) |
| AirPlay는 되는데 소리만 안 남 | `/etc/shairport-sync.conf` 가 온보드로 덮어써짐 | `output_device = "hw:CARD=<카드id>"` 로 복원 후 `systemctl restart shairport-sync` |
| `alsactl: Too many levels of symbolic links` | `/var/lib/alsa` 루프 | C-6 ④ |

---

# E. 체크리스트

**A. 이미지**
- [ ] 굽기 + `cmdline.txt` / `kernel8.img` 검증
- [ ] 첫 부팅, 루트 확장 확인, `systemctl --failed` 0개

**B. 업데이트**
- [ ] Addons → Update (20261101 이상) 후 재부팅
- [ ] `websocket` active, UDP 9000/9001 분리 확인

**C. 수동 반영**
- [ ] root 비밀번호 변경
- [ ] (선택) AirPlay 2 활성화
- [ ] NAS fstab + `x-systemd.automount` + `mpc update`
- [ ] Radio Paradise 삭제 → 라디오 15채널 + 타이머
- [ ] MPD 워치독 (동작 테스트 포함)
- [ ] USB DAC 안정화 4항목 + 확인 7항목
- [ ] htop
