# Clock Alarm Volume Guard

macOS 시계 앱의 활성 알람을 읽기 전용으로 감지하고, 알람 10초 전에 내장 스피커를 선택해 음소거를 해제하고 최소 80% 음량을 보장하는 로그인 백그라운드 에이전트입니다.

## 안전 원칙

- 시계 데이터베이스는 `SQLITE_OPEN_READONLY`로만 열며 알람 제목을 조회하거나 기록하지 않습니다.
- AirPods, HDMI 및 외부 스피커의 음량은 올리지 않습니다. CoreAudio에서 Built-in 출력 장치를 찾아 기본 출력과 시스템 효과 출력으로 설정합니다.
- 알람을 중단하거나 다시 알림으로 미루면 이전 출력·음량·음소거 상태를 복원합니다. 사용자가 알람 중 직접 오디오를 바꾼 경우에는 그 선택을 덮어쓰지 않습니다.
- Mac이 깨어 있고 사용자가 로그인된 동안만 사전 적용을 보장합니다.

## 설치와 확인

```zsh
./scripts/install.sh
./scripts/status.sh
```

`doctor`는 시계 DB와 CoreAudio 접근을 확인하지만 오디오를 변경하지 않습니다.

```zsh
~/Library/Application\ Support/ClockAlarmVolumeGuard/bin/clock-alarm-volume-guard doctor
```

로그는 `~/Library/Logs/ClockAlarmVolumeGuard/`에 JSON Lines 형식으로 저장됩니다. 각 알람 실행은 현재 DB 상태를 새 근거로 사용하며, 과거 로그는 현재 실행의 완료 근거로 재사용하지 않습니다.

## 제거

```zsh
./scripts/uninstall.sh
```

로그까지 영구 삭제하려면 명시적으로 `./scripts/uninstall.sh --purge-logs`를 사용합니다.

## 개발 검증

```zsh
swift test
swift run clock-alarm-volume-guard self-test
swift build -c release
prek run --all-files
```

Command Line Tools만 설치된 일부 Mac에서는 `xctest` 실행기가 없어 `swift test`가 테스트 번들까지만 빌드할 수 있습니다. 이 경우 `self-test`가 동일한 핵심 스케줄·SQLite·복원 저널 사례를 실제로 실행합니다. 전체 Xcode가 있는 CI에서는 Swift Testing 테스트도 실행합니다.

## 실기 검증 기준선

2026-08-22에 실제 시계 알람으로 다음을 확인했습니다.

- T-10초에 기본 출력과 시스템 효과 출력이 외부 HDMI에서 MacBook Pro Speakers로 전환됨
- 내장 스피커 CoreAudio 스칼라가 0.20·음소거에서 0.80·음소거 해제로 변경됨
- `ZFIREDDATE`로 실제 발화를 확인하고, 알람 비활성화 후 외부 출력·내장 스피커 20%·음소거 상태가 자동 복원됨
- 검증 종료 후 사용자의 원래 상태인 내장 스피커 85%·음소거 해제로 되돌림
