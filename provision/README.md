# provision — rAudio 기기 설정 자동화

새 이미지를 구운 뒤 **한 번에** 기기 설정을 적용하는 스크립트입니다.
`POST-INSTALL.md` 의 C장(내가 반영할 것) 내용을 코드로 옮긴 것입니다.

## 적용 항목

| 항목 | 내용 |
|---|---|
| NAS 마운트 | `/mnt/MPD/NAS` CIFS + `x-systemd.automount` + 성능/복구 옵션 |
| 라디오 | 한국 15채널 + 6시간 토큰 갱신 타이머 |
| MPD/AirPlay 워치독 | 교착·`player` 고착·DAC 설정 표류 자동 복구 (1분) |
| NAS 워치독 | CIFS 세션 끊김 시 리마운트 (2분) |
| USB DAC | udev 재연결 훅, `hw:CARD=<id>` 고정, 허브 절전 해제, alsa 링크 루프 교정 |

## 사용법

```bash
# 1) 점검만 (변경 없음)
sudo ./provision.sh --check

# 2) 적용
sudo ./provision.sh \
     --nas-src  //192.168.1.4/win/music \
     --nas-user carrot \
     --nas-pass 'secret'

# DAC 이 다르면 함께 지정
sudo ./provision.sh --dac-name "Topping E30 II Lite" --dac-card Lite --dac-usbid 152a:8750
```

설정을 반복 사용하려면 `/etc/raudio-provision.conf` 에 두고 인자 없이 실행합니다.

```bash
cat > /etc/raudio-provision.conf <<'EOF'
NAS_SRC="//192.168.1.4/win/music"
NAS_USER="carrot"
NAS_PASS="secret"
DAC_NAME="E30 II Lite"
DAC_CARD="Lite"
DAC_USBID="152a:8750"
EOF
chmod 600 /etc/raudio-provision.conf
sudo ./provision.sh
```

## 전제

- `rAudio-64bit-20260719.img` 이상, **Addons 업데이트 완료** 상태
  (업데이트 전에는 websocket/nqptp 포트 충돌로 웹 UI가 멈출 수 있음)
- `root` 로 실행
- NAS 자격증명은 `fstab` 에 평문으로 들어갑니다. 필요하면 마운트 옵션을
  `credentials=/root/.smbcred` 방식으로 바꿔 쓰세요.

## 동작 방식

- 모든 파일은 **내용이 다를 때만** 씁니다 (멱등)
- `--check` 는 파일·fstab·타이머 상태를 점검해 `[ OK ]` / `[MISS]` 로 출력
- DAC 이름/카드/USB ID는 인자로 받아 스크립트 안에 치환됩니다

## 적용 후 확인

```bash
sudo ./provision.sh --check          # [MISS] 가 없어야 정상
systemctl list-timers | grep -E 'radio-|nas-'
mpc update && mpc stats | egrep 'Songs'
```
