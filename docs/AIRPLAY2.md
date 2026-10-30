# rAudio AirPlay 2 구현 계획 (main 기준)

- 문서 버전: v0.4
- 작성일: 2026-10-30
- 기준 커밋: **`origin/main` @ `16f5cc454`** (upstream 반영 최종)
- 작업 브랜치: `feature/airplay2` (main에서 분기)
- 대상 저장소
  - `togobeyond/rAudio` (본 작업)
  - `rAudio-status` (C++ `status` 바이너리 — 상태 파이프라인 수정 필요)
  - `togobeyond/rOS` (이미지 빌드)
- 1차 대상 기기: **Raspberry Pi 2 (armv7h, BCM2836, 1 GB)**

> 변경 이력
> - v0.4: 운영 이미지 태그(`20260529`) 대신 **main 최종 커밋** 기준으로 재작성. main은 `status-shairport.sh`(D-Bus 감시) + C++ `status` 바이너리 구조이므로, AirPlay 2 대응 지점이 bash가 아니라 **C++ `shairport_meta.hpp`**임을 반영.
> - v0.3: `20260529` 기준(메타데이터 파이프 + bash `status.sh`)
> - v0.2: shairport-sync 5.0.4 소스 확인 결과 반영
> - v0.1: 최초 초안

---

## 0. 요약 (TL;DR)

main 기준 rAudio의 AirPlay 상태 경로는 **D-Bus + C++ `status` 바이너리**다.

```
shairport-sync (D-Bus: org.gnome.ShairportSync)
   │
   ├─ status-shairport.sh  (dbus-monitor 로 PropertiesChanged 감시)
   │     └ playerStart / pushStatus / playerStop
   │
   └─ status (C++, rAudio-status) ← status.sh 가 실행
         └ shairport_meta.hpp : PlayerState / ProgressString / SourceFormat / MPRIS Metadata
```

따라서 작업 핵심은 **"빌드"가 아니라 다음 4가지**다.

1. **C++ `shairport_meta.hpp` 방어** — AirPlay 2에서 `ProgressString`/`SourceFormat`이 비어 있을 때 `std::stoll`/`std::stoi` 예외로 **status 바이너리가 죽는다**. 이거 하나로 Web UI 상태 전체가 멈춘다.
2. **상태 훅 정리** — `playerStop()`이 자기 자신(`shairport.service`)을 stop 해서 뒷부분이 실행되지 않는다.
3. **`nqptp` 수명주기** — 5.0.4는 nqptp 없으면 기동 실패. AirPlay Off 시 함께 정리해야 한다.
4. **UI/문서** — "AirPlay" → "AirPlay 2", 미지원 범위 안내.

패키지는 이미 AirPlay 2 빌드다(`shairport-sync 5.0.4-3`, armv7h/aarch64 모두 존재, `depend = nqptp`).

---

## 0.1 이 브랜치에서 이미 반영된 것

| 위치 | 내용 | 상태 |
|---|---|---|
| `rAudio-status` `feature/airplay2` | Metadata 조회 대상 수정(네이티브 + MPRIS fallback), ProgressString/SourceFormat 방어, idle=stop, Title 기본값 | 완료 |
| `rAudio` `status.armv7h` | 위 수정으로 armv7h 재빌드(Docker+qemu) | 완료 |
| `rAudio` `common.sh` | `playerStop()` 자기 stop 문제 | 완료 |
| `rAudio` `status-shairport.sh` | `Stopped` 시 exit, timestamp/elapsed 가드 | 완료 |
| `rAudio` `settings/features.sh` | AirPlay Off 시 `nqptp` 정리 | 완료 |
| `rAudio` `install.sh` | `nqptp` 설치 보장(업그레이드) | 완료 |
| `rAudio` UI | "AirPlay 2" 라벨/도움말 | 완료 |
| `rOS` `feature/airplay2` | 포크 URL, `nqptp` 패키지, `status-shairport.sh` unit | 완료 |
| 실기기 검증 (RPi 2) | 재생/상태/메타데이터/회귀 | **대기** |
| aarch64 / armv6h 바이너리 | 동일 수정 반영 | 미완(armv7h만) |

---

## 1. 목표와 범위

### 1.1 목표

- iOS/iPadOS/macOS에서 **AirPlay 2 수신기**로 보이고 동작한다.
- 기존 AirPlay 1(Classic) 송신기도 연결된다.
- 기존 기능(MPD, Spotify, UPnP, Bluetooth, Snapcast, CamillaDSP)에 회귀가 없다.
- 기존 운영 기기(RPi 2, armv7h)에 **이미지 재빌드로 설치 가능**해야 한다.

### 1.2 포함 범위

- AirPlay 2 재생(스테레오), 볼륨, 세션 시작/종료
- 상태 표시(`state`, `elapsed`, `Title`, `sampling`) 정합성
- 메타데이터가 제공될 때 곡명/아티스트/앨범/커버 표시
- AirPlay 2 그룹(멀티룸) 참여
- 패키지/서비스 설치·비활성화 경로
- Web UI 표기/도움말

### 1.3 제외 범위

- AirPlay 비디오/사진
- Dolby Atmos, 96/192 kHz
- Windows iTunes의 AirPlay 2
- macOS 10.15 미만
- AirPlay 2 송신 기능

---

## 2. 기준 베이스라인 구조 (main)

### 2.1 실행 경로

```
[송신기] ── AirPlay 2 (RTSP/RTP, mDNS _airplay._tcp / _raop._tcp)
                │
┌───────────────▼────────────────────────────────────────────┐
│ rAudio                                                     │
│  avahi-daemon      mDNS 광고                                │
│  nqptp             PTP (UDP 319/320)  ← AirPlay 2 필수      │
│  shairport-sync    AirPlay 2 수신/디코딩 → ALSA hw:X         │
│     └ D-Bus org.gnome.ShairportSync                        │
│                                                             │
│  shairport.service → status-shairport.sh                    │
│     ├ 시작: playerStart airplay, timestamp 기록, pushStatus  │
│     ├ PropertiesChanged 감시                                │
│     └ Stopped: playerStop                                   │
│                                                             │
│  /srv/http/bash/status.sh → status (C++ 바이너리)            │
│     └ shairport_meta.hpp: PlayerState/ProgressString/       │
│        SourceFormat/MPRIS Metadata                          │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 핵심 파일

| 파일 | 역할 | AirPlay 2 관련성 |
|---|---|---|
| `srv/http/bash/status-shairport.sh` | `dbus-monitor`로 `PropertiesChanged` 감시, 상태 push, 종료 처리 | **P0** (종료 처리 버그) |
| `srv/http/bash/status.sh` | arch별 `status` 바이너리 실행 래퍼(armv6h) 또는 바이너리 | 변경 없음 |
| `srv/http/bash/status.armv7h` 외 | C++ `status` 사전 빌드 바이너리 | **재빌드 필요** |
| `rAudio-status/shairport_meta.hpp` | D-Bus 속성 → 상태 JSON | **P0** (예외/기본값) |
| `rAudio-status/_status.cpp` | 상태 조립(`V.STATE`, `V.TIME`, `V.ELAPSED`) | **P0** (idle 상태) |
| `srv/http/bash/common.sh` | `playerStart()` / `playerStop()` | **P0** (자기 stop) |
| `srv/http/bash/settings/features.sh` | AirPlay On/Off, SnapServer pipe 전환 | **P1** (`nqptp` 정리) |
| `srv/http/bash/settings/player-conf.sh` | ALSA 블록 교체 | **P1** (설정 보존) |
| `srv/http/bash/settings/system.sh` | hostname 변경 시 conf 갱신 | 낮 |
| `srv/http/bash/shairport.sh` | 레거시 메타데이터 파이프 파서(신규 이미지에선 미사용) | 참고용 |
| `install.sh` | 날짜별 마이그레이션 + 패키지 설치 | **P1** |
| `srv/http/settings/features.php`, `assets/js/{features,main}.js` | 라벨/도움말 | 낮 |

### 2.3 main에서 달라진 점 (구 이미지 대비)

- `shairport.service`의 ExecStart가 `shairport.sh` → **`status-shairport.sh`**로 교체된다(`install.sh` 20260922 블록에서 sed).
- `install.sh`가 `/etc/shairport-sync.conf`를 **전체 재작성**한다(`general`/`sessioncontrol`/`alsa`).
- `status.sh`는 armv7h/aarch64에서 **C++ 바이너리로 대체**된다(이미지 빌드 시 `mv status.armv7h status`, `rm status.sh`).
- 레거시 `shairport.sh`(메타데이터 파이프)와 `$dirshm/airplay/*` bash 파이프라인은 **더 이상 사용되지 않는다**.

---

## 3. 확인된 사실 (근거 포함)

### 3.1 패키지

| 항목 | 값 | 근거 |
|---|---|---|
| armv7h `shairport-sync` | `5.0.4-3` | ALARM `armv7h/extra` DB |
| armv7h `nqptp` | `1.2.8-1` | ALARM `armv7h/extra` DB |
| aarch64 | 동일 버전 | ALARM `aarch64/extra` DB |
| `shairport-sync` 의존성 | `openssl avahi libsoxr popt alsa-lib libconfig libpipewire libpulse jack mosquitto ffmpeg nqptp libplist` | 패키지 DB `depends` |
| 빌드 옵션 | AirPlay 2 포함(`--with-airplay-2`) | `shairport-sync -V` → `-AirPlay2-smiN` |
| unit | `Requires=avahi-daemon.service nqptp.service` | 패키지 내 unit |

- `ffmpeg`가 의존성이라 AAC(fltp) 디코딩은 자동 충족된다.
- **5.0.4에는 `service_type`이 없다.** AirPlay 2 빌드면 항상 AirPlay 2 모드이고, nqptp가 없으면 `die()`로 종료된다(Classic 자동 fallback 없음).
- Classic 전용/Windows iTunes 호환이 필요하면 **5.1+ 패키징**이 필요하다(후속).

### 3.2 D-Bus 인터페이스 (5.0.4 `org.gnome.ShairportSync.xml`)

| 인터페이스 | 속성 |
|---|---|
| `org.gnome.ShairportSync` | `SourceFormat`, `OutputFormat`, `Protocol`, `FramePosition`, `FirstFramePosition`, `VersionString` |
| `...RemoteControl` | `PlayerState`, `ProgressString`, `Client`, `ClientName`, `AirplayVolume` |
| `...AdvancedRemoteControl` | `Metadata`(a{sv}), `Available`, `PlaybackStatus`, `Volume` |
| `org.mpris.MediaPlayer2.Player` (path `/org/mpris/MediaPlayer2`) | `Metadata`, `PlaybackStatus`, `Position` |

- 시작 시 `PlayerState`는 **`"Not Available"`**로 초기화된다(`dbus-service.c`).
- `ProgressString`은 소스가 `progress:`를 보낼 때만 갱신된다(`rtsp.c`: “this can be sent even when metadata is not solicited”). **AirPlay 2에서 항상 오지는 않는다.**
- `SourceFormat`은 재생 시작 후에야 채워진다(형식: `AAC/48000/F24/2`).
- `ProgressString` 값은 **소스 샘플레이트 기준 프레임**(`start/current/end`)이다.

---

## 4. 코드 수준 문제 목록

### P0-0. 메타데이터 조회 대상이 잘못됨 (곡 정보가 절대 안 나옴)

`rAudio-status/shairport_meta.hpp`

```cpp
sd_bus_get_property(bus, "org.gnome.ShairportSync",
                    "/org/mpris/MediaPlayer2",
                    "org.mpris.MediaPlayer2.Player", "Metadata", ...);
```

shairport-sync 5.0.4/5.6.1 소스 확인 결과 두 인터페이스는 **서로 다른 버스 이름**을 쓴다.

| 대상 | 버스 이름 | 경로 | 인터페이스 |
|---|---|---|---|
| 네이티브 | `org.gnome.ShairportSync` | `/org/gnome/ShairportSync` | `org.gnome.ShairportSync.RemoteControl` (`Metadata`) |
| MPRIS | `org.mpris.MediaPlayer2.ShairportSync` | `/org/mpris/MediaPlayer2` | `org.mpris.MediaPlayer2.Player` (`Metadata`) |

현재 코드는 `org.gnome.ShairportSync` + `/org/mpris/MediaPlayer2` 조합이라 **항상 실패**한다.
→ Album/Artist/Title/커버/길이가 한 번도 채워지지 않는다. (배포 바이너리 문자열로도 동일 확인)

**수정**: 네이티브 `RemoteControl.Metadata`를 먼저 조회하고, 실패 시 MPRIS로 fallback.

> 참고: `Metadata` 사전 키는 양쪽 동일하다(`xesam:album`, `xesam:artist`, `xesam:title`, `mpris:artUrl`, `mpris:length`).
> `mpris:artUrl`은 `file:///path` 형식이므로 `file://` 접두사를 제거해야 한다.

### P0-1. `ProgressString` 파싱 예외 → status 크래시

`rAudio-status/shairport_meta.hpp`

```cpp
progress = get_prop(bus, "ProgressString");   // 실패 시 "Unknown", 미설정 시 ""
start    = std::stoll(progress.substr(0, p0)); // p0 == npos → 예외 → std::terminate
```

- AirPlay 2에서 `ProgressString`이 비어 있으면 `std::invalid_argument` → **프로세스 abort**.
- 결과: Web UI 상태 조회가 전부 실패(재생/볼륨/대기 모두).

**수정**: `find('/')` 결과 검증 + `try/catch` + 실패 시 0 반환.

### P0-2. `SourceFormat` 분기가 죽은 코드

```cpp
format = get_prop(bus, "SourceFormat", "org.gnome.ShairportSync");
if (format.empty()) { ... }   // get_prop은 실패 시 "Unknown"을 반환 → empty()가 될 수 없음
else { V.SAMPLERATE = std::stoi(format.substr(p0 + 1, p1 - p0 - 1)); }  // "Unknown" → 예외
```

**수정**: `format.find('/') == npos` 또는 `format == "Unknown"`을 실패로 처리하고 기본 44100/16bit로 fallback.

### P0-3. 세션 없음(`Not Available`) → UI가 `pause`로 표시

```cpp
void shairportMeta(...) {
    std::string state = get_prop(bus, "PlayerState");
    if ( state == "Not Available" ) return;   // V.STATE 미설정
```

`_status.cpp`에서 빈 `V.STATE`는 `else V.PAUSE = true`로 처리된다 → AirPlay 대기 중인데 "일시정지"로 보인다.

**수정**: `V.STATE = "stop"`으로 명시하고 반환.

### P0-4. `playerStop()` 자기 종료

`common.sh`

```bash
airplay )
    systemctl stop shairport        # 지금 실행 중인 서비스 = 자기 자신
    systemctl restart shairport-sync  # ← 실행되지 않음
    rm -f $dirshm/{coverart,elapsed,timestamp}
    ;;
```

`status-shairport.sh`(=`shairport.service`의 ExecStart)에서 `playerStop()`을 호출하면, `systemctl stop shairport`가 자신을 SIGTERM으로 종료시켜 **이후 라인이 모두 유실**된다. `pushStatus`, shm 정리, shairport-sync 재시작이 실행되지 않는다.

**수정**: `playerStop`에서 `systemctl stop shairport`를 제거하고, 종료는 호출자(`status-shairport.sh`의 `Stopped` 처리)에서 `exit`로 끝낸다. 재시작/정리는 종료 전에 수행.

### P1-1. `V.TIME == 0`이면 `elapsed`가 항상 0

```cpp
if (V.ELAPSED > V.TIME) V.ELAPSED = V.TIME;   // TIME 미제공 시 0으로 고정
```

AirPlay 2는 `mpris:length`를 주지 않는 경우가 있다 → 진행 시간이 계속 0.

**수정**: `V.TIME > 0`일 때만 clamp.

### P1-2. 메타데이터 미제공 시 `Title` 공백

`getMetadata()`가 `xesam:title`을 못 받으면 `S["Title"]`이 비어 UI가 빈다.

**수정**: `S["Title"]`이 비면 `"AirPlay"`로 채운다(기존 이미지에서 검증된 처리와 동일).

### P1-3. `status-shairport.sh`의 파일 부재/산술 오류

```bash
ms_prog=$( < $dirshm/timestamp )   # 파일 없으면 빈 문자열
echo $(( ( ms_pause - ms_prog + 500 ) / 1000 )) > $dirshm/elapsed
```

- `timestamp`가 없으면 `bash` 산술 오류.
- `Paused` 시 `elapsed`를 덮어쓰는데, `Remove`/`Stopped` 이후 잔상 가능.

**수정**: `[[ -e $dirshm/timestamp ]]` 가드, 기본값 처리.

### P1-4. `nqptp` 수명주기 미관리

- `features.sh`에서 AirPlay Off 시 `systemctl disable --now shairport-sync`만 수행한다.
- `Requires=`는 **시작만** 전파하므로 `nqptp`는 계속 실행된다.
- AirPlay를 다시 켜면 문제 없지만, 사용자가 껐는데 UDP 319/320을 점유하는 것은 바람직하지 않다.

**수정**: Off 시 `systemctl disable --now shairport-sync nqptp` (순서: shairport-sync → nqptp).

### P1-5. 설정 보존

`/etc/shairport-sync.conf`를 수정하는 주체가 4곳이다.

- `install.sh` — 전체 재작성
- `settings/player-conf.sh` — `sed '/^alsa/,/}/ d'` 후 `alsa {}` 재작성 (블록 **밖**은 보존)
- `settings/features.sh` — SnapServer On 시 `.default` 백업 후 `pipe` 전환
- `settings/system.sh` — hostname 변경

→ 새 설정(`metadata` 등)은 **반드시 `alsa` 밖**에 두고, SnapServer On/Off 및 `system-datareset.sh`(`.default` 복원)에서도 유지되도록 처리한다.

---

## 5. 설계 결정

### D1. 패키지

- armv7h/aarch64: ALARM `shairport-sync 5.0.4-3` + `nqptp 1.2.8-1` 그대로 사용.
- 별도 빌드 없음. `install.sh`에서 `nqptp` 설치만 보장.

### D2. 모드

- 5.0.4는 **AirPlay 2 고정**. 런타임 Classic 전환 불가.
- Classic 전용이 필요해지면 5.1+ 패키징으로 분리(후속 브랜치).

### D3. 상태 파이프라인

- main 구조 유지: `status-shairport.sh` + C++ `status`.
- bash로 되돌리지 않는다(중복·회귀 위험).
- C++ 수정은 **`togobeyond/rAudio-status` `feature/airplay2`** 에서 하고, 빌드 결과(`status.armv7h`)를 rAudio에 커밋한다.
- 빌드는 **Docker + qemu(linux/arm/v7)** 의 Arch Linux ARM 루트fs에서 네이티브 컴파일한다(기기 점유 없음, 반복 빌드 빠름).

### D4. 오디오 경로

- `shairport-sync` → ALSA `hw:X` 직결 유지.
- SnapServer On 시 `output_backend = "pipe"` → `/tmp/snapfifo`(기존 동작 유지).
- CamillaDSP/Equalizer 사용 시 stereo(`mixdown = "auto"`).

### D5. RPi 2 대응 (1차 대상)

| 항목 | 내용 |
|---|---|
| 아키텍처 | armv7h (`ArchLinuxARM-rpi-armv7-latest.tar.gz`) |
| 바이너리 | `status.armv7h` |
| CPU | Cortex-A7 ×4 @900 MHz |
| 권장 | 44.1/48 kHz 스테레오. 5.1/7.1·96 kHz 비권장 |
| 확인 | 1시간 재생 underrun 0, CPU 여유 20% 이상 |
| 주의 | rOS `shairport-sync.service.d/override.conf`의 `CPUAffinity=3` (4코어라 유효) |

---

## 6. 작업 분해 (WBS)

### Phase 0. 사전 감사

| ID | 작업 | 완료 기준 |
|---|---|---|
| 0-1 | RPi 2에 현재 이미지 설치, 패키지 확인 | `pacman -Q shairport-sync nqptp` |
| 0-2 | `shairport-sync -V` | `-AirPlay2` 포함 |
| 0-3 | nqptp/포트/mDNS 확인 | 319·320 LISTEN, `_airplay._tcp`·`_raop._tcp` |
| 0-4 | 상태 파이프라인 기준선 | `status` 정상 JSON, 재생/정지 상태 |
| 0-5 | AirPlay 2 세션에서 D-Bus 속성 캡처 | `PlayerState`, `ProgressString`, `SourceFormat`, `Metadata` 실측 |

```bash
pacman -Q shairport-sync nqptp
shairport-sync -V
systemctl status nqptp shairport-sync --no-pager
ss -lunp | grep -E ':(319|320)\b'
avahi-browse -rt _airplay._tcp

# 재생 중 실측
busctl get-property org.gnome.ShairportSync /org/gnome/ShairportSync \
  org.gnome.ShairportSync.RemoteControl PlayerState
busctl get-property org.gnome.ShairportSync /org/gnome/ShairportSync \
  org.gnome.ShairportSync.RemoteControl ProgressString
busctl get-property org.gnome.ShairportSync /org/gnome/ShairportSync \
  org.gnome.ShairportSync SourceFormat
busctl get-property org.gnome.ShairportSync /org/mpris/MediaPlayer2 \
  org.mpris.MediaPlayer2.Player Metadata
```

### Phase 1. C++ 상태 파이프라인 방어 (P0)

| ID | 작업 | 파일 |
|---|---|---|
| 1-0 | `Metadata` 조회 대상을 네이티브 `RemoteControl`로 (MPRIS fallback) | `shairport_meta.hpp` |
| 1-1 | `ProgressString` 파싱 방어 | `shairport_meta.hpp` |
| 1-2 | `SourceFormat` fallback | `shairport_meta.hpp` |
| 1-3 | `PlayerState == "Not Available"` → `state=stop` | `shairport_meta.hpp` |
| 1-4 | `V.TIME == 0` clamp 제외 | `_status.cpp` |
| 1-5 | `Title` 기본값 `AirPlay` | `shairport_meta.hpp` |
| 1-6 | armv7h 빌드 후 `srv/http/bash/status.armv7h` 갱신 | rAudio |

**패치 스케치**

```cpp
// shairport_meta.hpp
static bool parseProgress(const std::string& s, long long& a, long long& b, long long& c) {
    if (s.empty() || s == "Unknown" || s == "Not Available") return false;
    size_t p0 = s.find('/');
    if (p0 == std::string::npos) return false;
    size_t p1 = s.find('/', p0 + 1);
    if (p1 == std::string::npos) return false;
    try {
        a = std::stoll(s.substr(0, p0));
        b = std::stoll(s.substr(p0 + 1, p1 - p0 - 1));
        c = std::stoll(s.substr(p1 + 1));
    } catch (...) { return false; }
    return true;
}
```

```cpp
    std::string state = get_prop(bus, "PlayerState");
    if (state == "Not Available" || state.empty()) {
        V.STATE = "stop";               // idle: stop
        S["Title"] = "AirPlay";
        return;
    }
```

### Phase 2. 서비스/수명주기 (P0~P1)

| ID | 작업 | 파일 |
|---|---|---|
| 2-1 | `playerStop()`에서 자기 `stop` 제거 | `common.sh` |
| 2-2 | `status-shairport.sh` 종료 처리 정리(`Stopped` → 정리 후 exit) | `status-shairport.sh` |
| 2-3 | `timestamp` 부재 가드 | `status-shairport.sh` |
| 2-4 | AirPlay Off 시 `nqptp` 정리 | `settings/features.sh` |
| 2-5 | `nqptp` 설치 보장 | `install.sh` |

```bash
# install.sh (신규 날짜 블록)
if [[ -e /bin/shairport-sync ]]; then
	[[ $( uname -m ) != armv6l ]] && ! pacman -Qq nqptp &> /dev/null && packages+=' nqptp'
fi
```

```bash
# settings/features.sh (Off 분기)
systemctl disable --now $CMD
[[ $CMD == shairport-sync ]] && systemctl disable --now nqptp
```

### Phase 3. 설정/오디오

| ID | 작업 | 파일 |
|---|---|---|
| 3-1 | SnapServer pipe 전환 시 신규 설정 보존(`.default` 동기) | `features.sh` |
| 3-2 | `player-conf.sh` ALSA 교체 시 블록 밖 설정 보존 확인 | `player-conf.sh` |
| 3-3 | `system-datareset.sh` 복원 후 설정 유지 | `system-datareset.sh` |
| 3-4 | CamillaDSP On 시 stereo 정책 명시 | 문서/`player-conf.sh` |

### Phase 4. UI/UX

| ID | 작업 | 파일 |
|---|---|---|
| 4-1 | 기능 라벨 `AirPlay 2` | `settings/features.php`, `assets/js/features.js` |
| 4-2 | 플레이어 라벨 | `assets/js/main.js` |
| 4-3 | 도움말(지원/미지원) | `settings/features.php` |

```
AirPlay 2 (shairport-sync)
- 지원: iOS/iPadOS 16+, macOS 12+, Apple TV, HomePod
- 미지원: Windows iTunes, macOS 10.15 미만, 96/192 kHz, Dolby Atmos
- 곡 정보가 안 나오면 송신기가 메타데이터를 안 보내는 경우입니다.
- Raspberry Pi 2에서는 44.1/48 kHz 스테레오를 권장합니다.
```

### Phase 5. 테스트/QA

| ID | 시나리오 | 기대 |
|---|---|---|
| T-01 | iPhone 제어센터에서 선택 | AirPlay 2 기기로 표시 |
| T-02 | ALAC 44.1 / 48 재생 | 정상, `sampling` 표시 |
| T-03 | AAC 256 재생 | 정상(ffmpeg) |
| T-04 | 재생/일시정지/정지 | `state` 일치 |
| T-05 | 세션 종료 | `state=stop`, 잔상 없음, **status 크래시 없음** |
| T-06 | 메타데이터 없는 송신기 | `Title=AirPlay`, UI 정상 |
| T-07 | 볼륨 슬라이더 | 반영 |
| T-08 | AirPlay 2 그룹 | 동시 재생/동기 |
| T-09 | SnapServer pipe 모드 | Snapcast 경유 재생 |
| T-10 | AirPlay Off → On | nqptp 정리/재기동 |
| T-11 | 재부팅 | 자동 기동 |
| T-12 | 회귀: MPD/Spotify/UPnP/BT/CamillaDSP | 이상 없음 |

### Phase 6. 빌드/배포

| ID | 작업 |
|---|---|
| 6-1 | `rAudio-status` 수정 → armv7h 빌드 → `status.armv7h` 커밋 |
| 6-2 | `install.sh` 마이그레이션 추가 |
| 6-3 | rOS로 armv7 이미지 생성 |
| 6-4 | RPi 2 설치/검증 |

**armv7h 빌드 절차 (Docker + qemu)**

```bash
# 1) binfmt 등록 (1회)
docker run --privileged --rm tonistiigi/binfmt --install arm

# 2) Arch Linux ARM armv7h 루트fs 준비
curl -LO http://fl.us.mirror.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz
#   (SMACK xattr 때문에 docker import가 실패하므로 xattr 제거 후 재포장)
docker run --rm -v "$PWD:/w" debian:trixie-slim bash -c '
  cd /w && mkdir -p x &&
  tar --numeric-owner -xf ArchLinuxARM-armv7-latest.tar.gz -C x &&
  tar --numeric-owner -cf armv7-rootfs.tar -C x .'
docker import --platform linux/arm/v7 armv7-rootfs.tar alarm-armv7:base

# 3) 빌드 환경
docker run --name alarm-build --platform linux/arm/v7 alarm-armv7:base bash -c '
  sed -i "s|^Server.*|Server = http://fl.us.mirror.archlinuxarm.org/\$arch/\$repo|" /etc/pacman.d/mirrorlist
  sed -i "/^\[options\]/ a DisableSandbox" /etc/pacman.conf   # qemu에서 Landlock 없음
  pacman -Syu --noconfirm
  pacman -S --noconfirm --needed base-devel alsa-lib dbus curl libmpdclient \
        systemd-libs libupnpp taglib pkgconf'
docker commit alarm-build alarm-armv7:build

# 4) 컴파일
docker run --rm --platform linux/arm/v7 -v "$PWD/rAudio-status:/src" -w /src alarm-armv7:build \
  g++ -O2 -Wno-psabi _status.cpp -o status \
  $( pkg-config --cflags --libs alsa dbus-1 libcurl libmpdclient libsystemd libupnpp taglib )
```

- 결과물 `status`를 `rAudio/srv/http/bash/status.armv7h`로 복사해 커밋한다.
- aarch64/armv6h 바이너리는 각 arch 환경에서 동일하게 빌드한다(당장은 armv7h만).


---

## 7. 파일별 변경 목록

| 파일 | 변경 | 위험도 |
|---|---|---|
| `rAudio-status/shairport_meta.hpp` | 파싱 방어, idle 상태, Title 기본값 | 높음(핵심) |
| `rAudio-status/_status.cpp` | `V.TIME` clamp 조건 | 중 |
| `srv/http/bash/status.armv7h` | 재빌드 바이너리 | 높음 |
| `srv/http/bash/common.sh` | `playerStop` 자기 종료 제거 | 중 |
| `srv/http/bash/status-shairport.sh` | 종료/가드 정리 | 중 |
| `srv/http/bash/settings/features.sh` | `nqptp` 정리, pipe 설정 보존 | 중 |
| `srv/http/bash/settings/player-conf.sh` | 설정 보존 확인 | 낮 |
| `srv/http/bash/settings/system-datareset.sh` | 설정 유지 | 낮 |
| `install.sh` | `nqptp` 설치 | 낮 |
| `srv/http/settings/features.php` | 라벨/도움말 | 낮 |
| `srv/http/assets/js/{features,main}.js` | 라벨 | 낮 |
| `docs/AIRPLAY2.md` | 본 문서 | 낮 |

---

## 8. 리스크

| 리스크 | 영향 | 완화 |
|---|---|---|
| `ProgressString` 부재 | status 크래시 → UI 전체 먹통 | Phase 1 방어(필수) |
| AirPlay 2 메타데이터 부재 | 곡 정보 없음 | `Title=AirPlay`, (후속) MPRIS 보강 |
| 5.0.4 Classic 전환 불가 | Windows iTunes 미지원 | 문서화, 필요 시 5.1+ |
| nqptp 미기동 | AirPlay 전체 실패 | `Requires=` 유지 + 설치 보장 |
| RPi 2 성능 | underrun/끊김 | 44.1/48 스테레오, CPUAffinity 확인 |
| ALSA 독점 | 재생 실패 | MPD stop, DSP 정책 |
| 바이너리 재빌드 누락 | 수정 미반영 | 빌드/커밋 체크리스트 |
| SnapServer pipe 설정 유실 | 설정 초기화 | `.default` 동기 |

---

## 9. 롤백

1. UI에서 AirPlay Off → `shairport-sync`, `nqptp` stop
2. 문제 지속 시 `status.armv7h`를 이전 커밋 버전으로 되돌림
3. 브랜치 revert 후 이미지 재빌드

### 9.1 이미지 빌드/설치 경로 (RPi 2)

rOS 이미지 빌드(`create.sh` → 첫 부팅 `create-ros.sh`)는 **rern/rAudio를 고정 URL로 받아온다.** 포크를 설치하려면 rOS도 포크해야 한다.

이 저장소 기준 준비된 포크:

| 저장소 | 브랜치/태그 | 변경 |
|---|---|---|
| `togobeyond/rAudio` | `feature/airplay2`, 태그 `i20261030` | 본 작업 |
| `togobeyond/rAudio-status` | `feature/airplay2` | C++ 수정 |
| `togobeyond/rOS` | `feature/airplay2` | 아래 4가지 |

rOS 변경 내용:

```bash
# common.sh
https_raudio=https://github.com/togobeyond/rAudio
https_ros=https://github.com/togobeyond/rOS/raw/$BRANCH

# create.sh (common.sh source 경로)
. <( curl -sL https://github.com/togobeyond/rOS/raw/$BRANCH/common.sh )

# create-ros.sh
#  - rAudio → togobeyond, rOS → togobeyond, rAudio-assets → rern
#  - packages 에 nqptp 추가

# etc/systemd/system/shairport.service
ExecStart=/srv/http/bash/status-shairport.sh
```

`create-ros.sh`는 `install.sh`를 실행하지 않는다. 따라서 새 이미지에는 위 설정이 **rOS에 직접 반영**되어 있어야 한다.

- `RELEASE`는 `togobeyond/rAudio`의 태그(예: `i20261030`)를 지정한다.
- `create-ros.sh`가 `status.armv7h` → `status`로 이동시키므로, 태그에 **새 바이너리가 커밋되어 있어야** 한다.
- 반대로 **기존 운영 기기 업데이트**는 `install.sh`가 위 설정을 마이그레이션한다.

> `install.sh`를 수동 실행하면 `r1` 애드온 `installurl`(rern/rAudio)에서 다시 받아와 포크 내용을 덮어쓴다. 포크 이미지에서는 `install.sh`를 실행하지 않는다.

### 9.2 빌드된 이미지 (armv7h / RPi 2)

| 항목 | 값 |
|---|---|
| 파일 | `rAudio-airplay2-armv7.img` (6.3 GiB) / `.img.xz` |
| 베이스 | Arch Linux ARM `rpi-armv7` (2026-10) |
| rOS | `togobeyond/rOS` `feature/airplay2` |
| rAudio | `togobeyond/rAudio` tag `i20261030` |
| 파티션 | boot 300 MiB FAT32 `BOOT` / root 6 GiB ext4 `ROOT` |
| PARTUUID | `a7d3c5e1-01`, `a7d3c5e1-02` |
| 설치 기능 | 공식 이미지 기본값(전체): `bluealsa bluez bluez-utils python-dbus python-gobject python-requests camilladsp python-websocket-client firefox matchbox-window-manager plymouth-lite-rbp-git upower xf86-video-fbturbo iwd samba shairport-sync snapcast spotifyd upmpdcli` |

빌드는 SD 카드 없이 `create.sh`의 SD 작성 단계만 재현해서 만들었다.

```
bootcode.bin / start.elf / kernel7.img / initramfs-linux.img / dtbs / overlays
/root/create-ros.sh + DATA  (BRANCH=feature/airplay2, RELEASE=i20261030)
/etc/systemd/system/ros-setup.service  (enabled)
```

**첫 부팅 시 `ros-setup.service`가 `/root/create-ros.sh`를 자동 실행**한다(tty1, 네트워크 최대 5분 대기).
완료 후 스스로 `disable`하고 재부팅하므로 두 번 실행되지 않는다.

```bash
# 진행 상황 (모니터 없이)
journalctl -u ros-setup -f
# 수동 재실행
systemctl start ros-setup
```

빌드 스크립트: `rOS-build/build-image.sh` (재빌드 시 태그/브랜치만 바꿔 실행)




---

## 10. Definition of Done

- [ ] `shairport-sync -V`에 `-AirPlay2`
- [ ] `nqptp` 동반 기동, Off 시 정리
- [ ] AirPlay 2 세션 전 구간에서 `status` 크래시 없음
- [ ] 재생/일시정지/정지/볼륨/`elapsed` 정상
- [ ] 메타데이터 미제공 시 `Title=AirPlay`
- [ ] 세션 종료 후 `state=stop`, 잔상 없음
- [ ] 기존 렌더러 회귀 없음
- [ ] RPi 2(armv7h) 이미지 설치/1시간 재생 검증
- [ ] 문서/도움말 갱신

---

## 부록 A. 빠른 확인

```bash
# 패키지/서비스
pacman -Q shairport-sync nqptp
shairport-sync -V
systemctl status nqptp shairport-sync --no-pager
ss -lunp | grep -E ':(319|320)\b'

# mDNS
avahi-browse -rt _airplay._tcp
avahi-browse -rt _raop._tcp

# 상태
cat /srv/http/data/shm/player
/srv/http/bash/status.sh | head -20
journalctl -u shairport-sync -u nqptp -f
```

## 부록 B. 트러블슈팅

- 기기 목록에 안 보임 → `nqptp` 기동, 319/320 포트, `journalctl -u shairport-sync`
- 연결은 되는데 소리 없음 → 출력 장치/`mixer_control_name`, 송신기 볼륨
- UI 상태가 안 바뀜 → `status` 크래시 여부(`status.sh` 직접 실행), `status-shairport.sh` 로그
- 곡 정보 없음 → MPRIS `Metadata` 확인(송신기 미제공 가능)
- 진행 시간 0 → `ProgressString`/`mpris:length` 제공 여부
- 종료 후 상태 잔상 → `playerStop` 자기 stop 문제 확인
- 설정 초기화 → `player-conf.sh`/SnapServer `.default` 처리
