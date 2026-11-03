# rAudio 설치 후 설정 가이드 (Raspberry Pi 4 / 64bit)

`rAudio-64bit-20260719.img` 를 Pi 4에 설치한 뒤 **실제로 적용한 작업만** 정리했습니다.
검증 환경: Raspberry Pi 4 Model B Rev 1.1 (aarch64, 4GB), Addons 업데이트 20261101

---

## 1. 이미지 굽기 (macOS)

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

---

## 2. 첫 부팅과 접속

1. SD카드를 Pi 4에 꽂고 전원 인가
2. 첫 부팅 시 루트 파티션이 카드 끝까지 자동 확장 (2~3분)
3. 공유기에서 IP 확인

```bash
ssh root@<Pi IP>          # 기본 암호: ros

df -h /                   # 카드 크기로 확장됐는지
systemctl --failed        # 0 loaded units
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1/    # 200
```

기본 활성 서비스: `nginx`, `php-fpm`, `mpd`, `websocket`, `startup`

### 2-3. rAudio 최신 업데이트 (필수)

이미지는 빌드 시점(20260719) 기준이고, **Addons 업데이트가 별도로 존재**합니다.
현재 운영 중인 버전은 **20261101** 입니다.

```
웹 UI → Addons → Update
```

```bash
cat /srv/http/data/addons/r1      # 예: 20261101
```

**업데이트를 먼저 해야 하는 이유**

- AirPlay 2(`nqptp`)와 `websocket` 의 **UDP 9000 포트 충돌이 업데이트에서 해결**됩니다 (3장)
- 업데이트 전 이미지는 `websocket.py` 수동 패치가 필요합니다

즉 **2-3(업데이트) → 재부팅 → 3~8장 설정** 순서를 지키면 3장의 구버전 패치가 필요 없습니다.
업데이트 전에 AirPlay를 켜면 웹 UI가 멈출 수 있습니다.

**업데이트가 건드리지 않는 것** (직접 만든 파일)

```
/usr/local/bin/*.sh
/etc/systemd/system/*.service, *.timer
/etc/udev/rules.d/
/etc/fstab
/srv/http/data/          ← 설정·라디오·MPD DB
```

**업데이트 후 다시 해야 할 수 있는 것**

- 기본 웹라디오(Radio Paradise)가 되살아남 → **5-1 다시 삭제** 후 `systemctl start radio-refresh.service`
- `/srv/http/bash/` 아래 파일은 덮어써짐 (수동 패치는 사라짐)

---

## 3. AirPlay 2 (선택)

이미지 기본값은 `shairport-sync` / `nqptp` **모두 disabled** 입니다.

```bash
systemctl enable --now nqptp            # AirPlay 2 필수 (PTP 타이밍)
systemctl enable --now shairport-sync   # RAOP

avahi-browse -t _airplay._tcp | grep -i raudio   # 광고 확인
ss -tlnp | grep 7000                             # AirPlay 2 포트
```

**품질 참고**: AirPlay 2는 송신 측에서 AAC 256kbps로 재인코딩 → 손실.
무손실·Hi-Res는 MPD(4장 NAS 파일 직접 재생)를 사용합니다.

---

## 4. NAS 자동 마운트

### 4-1. fstab 등록

SMB는 하위 폴더만 따로 마운트할 수 없으므로 **소스 경로에 하위 디렉터리를 포함**합니다.

```bash
cat >> /etc/fstab <<'EOF'
//<NAS IP>/win/music /mnt/MPD/NAS cifs username=<USER>,password=<PASS>,uid=45,gid=45,iocharset=utf8,_netdev,nofail,noatime,actimeo=60,x-systemd.automount,x-systemd.mount-timeout=30 0 0
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
| `x-systemd.automount` | **부팅 시 네트워크 경합 회피** (필수) |
| `_netdev,nofail` | NAS가 꺼져 있어도 부팅 지속 |

> ⚠️ `_netdev,nofail` 만 쓰면 부팅 시 `cifs_mount failed w/return code = -101` 로
> 실패하고 재시도하지 않습니다. 반드시 `x-systemd.automount` 를 함께 쓰세요.

### 4-2. MPD 라이브러리 스캔

```bash
mpc update
mpc status | head -1                    # Updating DB → 사라지면 완료
mpc stats | egrep 'Artists|Albums|Songs'
```

- 17,680개 파일 기준 **40~45분** 소요
- 스캔 중에는 곡 수가 늘지 않음 (완료 시 일괄 커밋)

---

## 5. 웹라디오 (한국 라디오 15채널)

### 5-1. 기본 방송 삭제

이미지에 포함된 Radio Paradise 5개 채널을 제거합니다.
**Addons 업데이트 후 다시 생길 수 있으므로 업데이트를 마친 뒤 실행하세요.**

```bash
rm -rf /srv/http/data/webradio/Radio*
```

### 5-2. 원리

```
/srv/http/data/webradio/<방송 이름>/data   ← 1번째 줄: 스트림 URL
/srv/http/data/mpd/radio                   ← "URL^^경로" 목록 (자동 생성)
```

KBS·MBC·SBS 등 국내 방송은 **서명 토큰이 붙은 HLS(m3u8)** 를 `.pls` 로 감싼 형태입니다.

- MPD는 원격 `.pls`를 읽지 못함 (`unrecognized file`)
- m3u8 토큰은 **약 48시간 후 만료**

따라서 m3u8 주소를 저장하고 주기적으로 재조회합니다.

### 5-3. 소스 목록

`/usr/local/etc/radio-sources.tsv` — `pls주소|방송이름` 형식

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

### 5-4. 갱신 스크립트

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
    # 폴백: 목록만 직접 재생성
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

> ⚠️ 채널을 추가·삭제한 뒤에는 반드시 `webradioCount` 까지 실행해야 합니다.
> `/srv/http/data/mpd/counts` 의 `"webradio"` 값과 `dirmpd/radio` 목록을
> 함께 갱신하고 UI에 푸시하는 역할을 합니다. 위 스크립트가 자동으로 처리합니다.

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

### 5-5. 적용

```bash
chmod 755 /usr/local/bin/radio-refresh.sh
systemctl daemon-reload
systemctl enable --now radio-refresh.timer
systemctl start radio-refresh.service        # 즉시 1회 실행 → 15개 채널 생성
systemctl list-timers radio-refresh.timer    # NEXT 확인
ls /srv/http/data/webradio                   # 채널 목록
```

### 5-6. 채널 추가/삭제

- **추가**: `/usr/local/etc/radio-sources.tsv` 에 `pls주소|이름` 한 줄 추가 → `systemctl start radio-refresh.service`
- **삭제**: `rm -rf "/srv/http/data/webradio/<이름>"` + TSV에서 해당 줄 제거 → 서비스 재실행

서비스가 `webradioCount` 를 호출하므로 `counts`·목록·UI 푸시가 한 번에 처리됩니다.
그래도 화면 숫자가 그대로면 **브라우저 강제 새로고침(⌘⇧R)** 하세요
(`/data/mpd/counts` 에 `ETag` 가 붙어 브라우저가 이전 응답을 재사용합니다).

---

## 6. 편의 설정

```bash
pacman -Sy --needed --noconfirm htop
passwd                                 # 기본값 ros
```

> ⚠️ 전체 업그레이드는 `pacman -Syu` 대신 **Addons → Update** 를 사용하세요.

---

## 7. MPD 워치독

HLS 라디오를 빠르게 전환하다 보면 MPD가 교착될 수 있습니다.
이때 `status` 명령이 MPD에 붙지 못해 **빈 `status.json`** 이 기록되고,
**웹 UI가 아무것도 표시하지 않습니다** (OS 자체는 정상).

수동 복구:

```bash
systemctl restart mpd
rm -f /dev/shm/pidstatuspush && /srv/http/bash/status-push.sh
```

이를 자동화한 워치독입니다. 1분마다 MPD 응답을 확인하고, 3회 연속 실패하면 재시작합니다.

`/usr/local/bin/radio-watchdog.sh`:

```bash
#!/bin/bash
# MPD 무응답 감지 → 자동 복구
STATE=/run/radio-watchdog.fail
MAX=3

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

# 상태 파일 재생성 (빈 status.json 으로 UI 가 멈추는 것 방지)
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

동작 방식과 부하:

| 항목 | 내용 |
|---|---|
| 확인 주기 | 1분 |
| 복구 조건 | `mpc status` 3회 연속 실패 (≈3분) |
| 복구 동작 | `mpd` 재시작 + `status.json` 재생성 |
| 정상 시 | 카운터 초기화 후 즉시 종료 (출력 없음) |
| 부하 | 분당 `mpc status` 1회 (수 ms) |

> `OnUnitActiveSec` 은 `NEXT`가 비어 보이는 경우가 있어 `OnCalendar` 를 사용합니다.

---

## 8. USB DAC 안정화

### 8-0. 적용 순서

재생이 잠깐 끊기므로 스피커를 끄거나 볼륨을 낮춘 뒤 진행합니다. 총 4단계, 10분 이내입니다.

| 순서 | 작업 | 절 |
|---|---|---|
| 1 | 대상 DAC의 USB ID / 카드 이름 확인 | 8-2 |
| 2 | udev 자동복구 등록 (DAC 재연결 시 서비스 재시작) | 8-3 |
| 3 | 장치 지정을 카드 번호 → 카드 이름으로 변경 | 8-4 |
| 4 | 허브 절전 해제 + ALSA 링크 루프 수정 | 8-5, 8-6 |
| 5 | 동작 검증 | 8-7, 8-8 |

> 다른 DAC를 쓸 때는 **세 곳**을 함께 바꿔야 합니다:
> udev 규칙의 `idVendor/idProduct`, `usb-dac-ready.sh` 의 `grep` 문자열, `hw:CARD=<id>`.

### 8-1. 증상

장시간 재생하지 않다가 재생하면 **DAC로 소리가 나가지 않고**, Pi를 재부팅해야 복구됩니다.
UI는 `playing` 으로 정상 표시되므로 원인이 보이지 않습니다.

### 8-2. 원인

먼저 대상 DAC의 식별자를 확인합니다.

```bash
aplay -l | grep -i usb              # 카드 번호와 이름
cat /proc/asound/card2/id           # → Lite  (hw:CARD=Lite 에 사용)
cat /proc/asound/card2/usbid        # → 152a:8750  (udev 규칙에 사용)
```

USB DAC가 하루에 여러 번 버스에서 **재열거(re-enumerate)** 됩니다.

```bash
journalctl -b -1 -k | grep "new high-speed USB device"
# Nov 03 12:14  usb 1-1.3: new high-speed USB device number 4
# Nov 03 21:23  usb 1-1.3: new high-speed USB device number 5
# Nov 03 22:12  usb 1-1.3: new high-speed USB device number 6
```

그런데 오디오 서비스는 장치를 **고정 카드 번호**로 잡고 있습니다.

```
MPD       /srv/http/data/mpdconf/output.conf  → device "hw:2"
shairport /etc/shairport-sync.conf            → output_device = "hw:2"
```

재열거로 기존 ALSA 핸들이 무효화되면 MPD는 죽은 핸들을 붙잡은 채 재생을 계속하고,
DAC로는 데이터가 가지 않습니다. 재부팅하면 USB가 재초기화되며 정상화됩니다.

### 8-3. 조치 ① — DAC 재연결 시 자동 복구

`/usr/local/bin/usb-dac-ready.sh`:

```bash
#!/bin/bash
# USB DAC 재연결 시 오디오 서비스 재시작 (죽은 ALSA 핸들 해소)
for i in $(seq 1 10); do
    grep -q "E30 II Lite" /proc/asound/cards 2>/dev/null && break
    sleep 1
done
grep -q "E30 II Lite" /proc/asound/cards 2>/dev/null || exit 0
systemctl try-restart mpd shairport-sync
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

> `152a:8750` = Topping E30 II Lite. 다른 DAC은 `lsusb`(또는 `cat /proc/asound/card*/usbid`)로 ID 확인 후 교체.

### 8-4. 조치 ② — 카드 번호 대신 이름으로 지정

재열거로 카드 번호가 바뀌어도 안전하도록 장치명을 고정합니다.

```bash
# 카드 id 확인
cat /proc/asound/card2/id          # → Lite

# 백업 후 수정
cp /srv/http/data/mpdconf/output.conf /srv/http/data/mpdconf/output.conf.bak
cp /etc/shairport-sync.conf /etc/shairport-sync.conf.bak

sed -i 's|device         "hw:2"|device         "hw:CARD=Lite"|' /srv/http/data/mpdconf/output.conf
sed -i 's|output_device = "hw:2"|output_device = "hw:CARD=Lite"|' /etc/shairport-sync.conf

systemctl restart mpd shairport-sync
```

카드 번호가 2가 아니면(예: 카드 1) `hw:1` → `hw:CARD=<id>` 로 바꿔 적용합니다.

검증:

```bash
mpc clear; mpc add "NAS/jazz/<파일>"; mpc play    # 경로는 music_directory(/mnt/MPD) 기준 상대경로
cat /proc/asound/card2/pcm0p/sub0/hw_params       # rate 가 잡히면 정상
```

> ⚠️ rAudio UI에서 출력 장치를 다시 선택하면 `output.conf`가 `hw:2` 로 되돌아갈 수 있습니다.

### 8-5. 조치 ③ — USB 허브 절전 해제

DAC이 허브(`2109:3431`) 뒤에 물려 있고 허브가 autosuspend `auto` 였습니다.

`/etc/udev/rules.d/99-raudio-dac.rules` 에 한 줄 추가:

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2109", ATTR{idProduct}=="3431", ATTR{power/control}="on"
```

```bash
udevadm control --reload-rules
echo on > /sys/bus/usb/devices/1-1/power/control      # 즉시 적용
```

### 8-6. 조치 ④ — `/var/lib/alsa` 심볼릭 링크 루프

rAudio `startup.sh` 는 부팅 시 아래를 실행합니다.

```bash
mv /var/lib/alsa $dirshm/alsa    # $dirshm=/srv/http/data/shm(=/dev/shm)
ln -s $dirshm/alsa /var/lib/alsa
```

`/var/lib/alsa` 가 이미 심볼릭 링크인 상태에서 다시 부팅하면 **링크 자체가 이동**되어
`/dev/shm/alsa → /srv/http/data/shm/alsa` 자기 참조 루프가 생기고, `alsactl` 이 실패합니다.

```
alsactl: save_state:1707: Cannot open /var/lib/alsa/asound.state for writing:
         Too many levels of symbolic links
```

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
alsactl store && echo "store OK"      # 검증
```

### 8-7. 동작 확인

udev 규칙이 실제로 서비스를 띄우는지 시뮬레이션:

```bash
udevadm trigger --action=add --subsystem-match=usb \
    --attr-match=idVendor=152a --attr-match=idProduct=8750
sleep 8
journalctl -u usb-dac-ready -n 3
# → Finished USB DAC reconnect - restart audio services.
```

### 8-8. 적용 후 체크리스트

```bash
# 1) udev 규칙 등록됨
cat /etc/udev/rules.d/99-raudio-dac.rules

# 2) 서비스가 이벤트에 반응함
udevadm trigger --action=add --subsystem-match=usb \
    --attr-match=idVendor=152a --attr-match=idProduct=8750
systemctl show -p Result --value usb-dac-ready.service     # → success

# 3) 장치 지정이 이름 기반
grep device /srv/http/data/mpdconf/output.conf             # → hw:CARD=Lite
grep output_device /etc/shairport-sync.conf                # → hw:CARD=Lite

# 4) 재생이 실제 DAC로 감
mpc clear; mpc add "NAS/jazz/<파일>"; mpc play
grep ^rate /proc/asound/card2/pcm0p/sub0/hw_params         # → rate: 192000 …
mpc stop

# 5) 허브 절전 해제
cat /sys/bus/usb/devices/1-1/power/control                 # → on

# 6) ALSA 상태 저장 정상
alsactl store && echo OK                                   # → OK

# 7) udev/서비스 파일이 부팅 시 자동 적용
systemctl is-enabled alsa-shm-fix.service                  # → enabled
```

| 항목 | 정상 값 |
|---|---|
| udev 규칙 | DAC 1줄 + 허브 1줄 |
| `usb-dac-ready.service` | `success` |
| MPD/shairport 장치 | `hw:CARD=<카드id>` |
| DAC `hw_params` | `rate: ...` 출력됨 |
| 허브 power/control | `on` |
| `alsactl store` | OK |
| `alsa-shm-fix.service` | enabled |

> 파일 수정 전 백업: `output.conf.bak`, `shairport-sync.conf.bak`

---

## 9. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| 웹 UI가 로딩에서 멈춤 | `websocket.service` 실패 (nqptp와 UDP 9000 충돌) | `systemctl status websocket` 확인. 구버전 이미지는 websocket.py의 9000을 9001로 변경 |
| NAS 마운트 실패 (`-101`) | 부팅 시 네트워크 경합 | `x-systemd.automount` 적용 |
| 스캔이 멈춘 듯 | MPD는 완료 시 일괄 커밋 | `mpc status`의 `Updating DB` 로 판단 |
| 웹라디오 `unrecognized file` | MPD가 원격 `.pls` 미지원 | 실제 스트림 URL(m3u8) 저장 |
| 웹라디오가 며칠 뒤 재생 안 됨 | 서명 토큰 만료 | `systemctl start radio-refresh.service` 로 즉시 갱신 |
| 라디오 개수가 예전 값으로 보임 | `counts` 파일 미갱신 또는 브라우저 캐시 | `webradioCount` 실행 후 강제 새로고침(⌘⇧R) |
| 웹 UI가 빈 화면 (서비스는 정상) | MPD 교착 → 빈 `status.json` | 워치독이 3분 내 자동 복구. 수동은 7장 |
| 장시간 유휴 후 소리 안 남 | DAC USB 재열거 + `hw:2` 고정 지정 | 8장 (udev 자동복구 + `hw:CARD=Lite`) |
| `alsactl: Too many levels of symbolic links` | `/var/lib/alsa` 심볼릭 링크 루프 | 8-6 `alsa-shm-fix.service` |
| 접속 IP가 바뀜 | DHCP | ARP에서 Pi MAC(`dc:a6:32`) 확인 |

---

## 10. 체크리스트

- [ ] 이미지 굽기 + `cmdline.txt` / `kernel8.img` 검증
- [ ] 첫 부팅, 루트 확장 확인, `systemctl --failed` 0개
- [ ] **Addons → Update** (20261101 이상) 후 재부팅
- [ ] root 비밀번호 변경
- [ ] (선택) AirPlay 2 활성화
- [ ] NAS fstab 등록 (`x-systemd.automount`, `actimeo=60`)
- [ ] `mpc update` 로 라이브러리 인덱싱
- [ ] 기본 라디오(Radio Paradise) 삭제
- [ ] 한국 라디오 15채널 + `radio-refresh.timer`
- [ ] MPD 워치독 (`radio-watchdog.timer`) + 동작 테스트
- [ ] USB DAC 안정화 (udev 자동복구 · `hw:CARD=<id>` · 허브 절전 · alsa 링크 루프)
- [ ] htop 설치
