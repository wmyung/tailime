# TailIME

**로컬 Mac에서는 딜레이·씹힘 없이 빠릿하게, Tailscale로 연결된 원격 Mac에서는 Karabiner·원격 앱 모드와 무관하게 정확하게 한영을 전환하는 macOS 네이티브 메뉴바 앱**

[English](README.md) | **한국어**

[![Platform](https://img.shields.io/badge/macOS-13%20%E2%80%93%2026%2B-black)](https://github.com/wmyung/tailime/releases/latest)
[![Arch](https://img.shields.io/badge/arch-Universal%20(arm64%20%2B%20x86__64)-blue)](https://github.com/wmyung/tailime/releases/latest)
[![Dependencies](https://img.shields.io/badge/dependencies-zero%20external%20packages-brightgreen)](#소스에서-빌드)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Download](https://img.shields.io/badge/Download-TailIME--1.0.1--macos.zip-0071e3)](https://github.com/wmyung/tailime/releases/download/v1.0.1/TailIME-1.0.1-macos.zip)

---

## 왜 만들었나요?

Mac 사용자(특히 **Karabiner-Elements**로 우측 `⌘`/`⌥`를 `F18`/`F19`로 바꿔 쓰며 **RustDesk·화면공유·VNC**로 다른 Mac에 접속하는 환경)는 두 가지 고질적인 고통을 겪습니다.

1. **로컬 한영 전환 딜레이 & 첫 글자 씹힘**: macOS는 키를 **뗄 때** 전환되어 빠르게 치면 글자가 꼬이고(`한dud` → `하dud`), macOS 26+에서는 메모리 절약으로 `TextInputSwitcher`가 종료되어 첫 한영키 입력이 통째로 무시됩니다.
2. **원격 Mac 제어 시 한영 전환 불능 & 자소 분리**: 로컬 macOS/Karabiner가 한영키를 먼저 가로채 버리거나, RustDesk의 Translate/Map 모드 차이 때문에 원격 Mac의 한영 전환이 안 되거나, 로컬 한글 입력기가 켜진 채 원격 창에 입력해 자소가 깨집니다.

**TailIME**는 기존 Karabiner·macOS 단축키 설정을 **단 한 줄도 건드리지 않고** 이 두 문제를 한 번에 해결합니다.

---

## 바로 다운로드 & 설치

- **[TailIME-1.0.1-macos.zip 다운로드 (Universal arm64 + x86_64)](https://github.com/wmyung/tailime/releases/download/v1.0.1/TailIME-1.0.1-macos.zip)** ([SHA-256](https://github.com/wmyung/tailime/releases/download/v1.0.1/TailIME-1.0.1-macos.zip.sha256))

```bash
unzip TailIME-1.0.1-macos.zip
cd TailIME-1.0.1
./install.sh --link-cli
```

- macOS `renamex_np(RENAME_SWAP)` 단일 시스템콜로 기존 앱을 안전하게 원자적 교체하며, 실패 시 자동 복원합니다.
- 기존 `~/.config/karabiner/karabiner.json`이나 시스템 단축키 설정은 절대 수정하지 않습니다.

---

## 기존 방식과의 비교

| 기능 | **TailIME** | `gksdud` | `HangulSync` | Karabiner + RustDesk Map 모드 | macOS 기본 |
|---|---|---|---|---|---|
| **로컬 `keyDown` 즉시 전환 (씹힘 없음)** | ✅ 지원 | ✅ 지원 | ❌ 미지원 | ❌ Key-up 지연 | ❌ 지연 있음 |
| **macOS 26+ `TextInputSwitcher` 자동 깨우기** | ✅ 자동 | ✅ 자동 | ❌ 미지원 | ❌ 미지원 | ❌ 첫 키 씹힘 |
| **Karabiner 다중 키보드 설정 무충돌 자동 감지** | ✅ 읽기 전용 자동 감지 | ⚠️ HID 충돌 주의 | ✅ 호환 | ⚠️ 수동 설정 | ✅ 호환 |
| **RustDesk Map / Translate 모두 원격 전환** | ✅ 모두 지원 | ❌ 로컬 전용 | ⚠️ 로컬 IME 충돌 | ❌ Translate/Karabiner 깨짐 | ❌ 로컬 가로챔 |
| **원격 창 포커스 시 로컬 자동 영문(ABC) 고정** | ✅ 기본 내장 | ❌ 없음 | ❌ 양쪽 미러링 | ❌ 수동 | ❌ 없음 |
| **In-Band 순서 보장 + Tailscale UDP 하이브리드** | ✅ 자동 프로브 | ❌ 없음 | ❌ TCP 미러링 | ❌ 키 전달만 | ❌ 없음 |
| **미설치 원격지(Windows 등) 안전 폴백** | ✅ OS별 폴백 | ❌ 없음 | ❌ Mac 전용 | ⚠️ 수동 우측 Alt | ❌ 없음 |

---

## 핵심 기능

### 1. 어떤 한영키 설정이든 자동 호환 (기존 설정 불변)
- macOS 시스템 단축키 `60`번(`이전 입력 소스 선택`) 자동 감지 (입력 소스가 3개 이상일 때 기존 `60`/`61`번 동작 보존)
- **Karabiner-Elements** 설정 폴더 감시 및 자동 파싱(전역·장치별 `simple_modifications` 및 `complex_modifications`에서 `F13`–`F20`·`Lang1`·조합키 자동 추출)
- 하드웨어 `한/영 (Lang1)` 키 자동 감지 + 설정 창 **키 직접 녹화** (`Ctrl+Space`, `Shift+Space`, `우측 ⌘/⌥/⌃ 단독 탭` 등)
- Karabiner 미사용자만 원할 경우 선택적으로 물리 키보드 전용 HID 리매핑 제공 (기본 OFF, Karabiner 실행 중 자동 잠금)

### 2. 로컬 Mac 초저지연 한영 전환 (macOS 13 ~ 26+)
- 전용 `.userInteractive` 스레드 **HID 레벨 `CGEventTap`**(`.cghidEventTap`)으로 `keyDown` 즉시 전환
- macOS 26+ `com.apple.TextInputSwitcher` 백그라운드 자동 웜업
- `CGEventSource(.privateState)` 원자적 펄스 + `TSMDirectBridge`(`macism` 방식 포커스 앱 직접 전환) 폴백 + 짧은 FIFO `HoldGate`(포커스 변경 시 고아 `keyUp`·모디파이어 보존으로 키 stuck 방지)

### 3. Tailscale 원격 Mac 한영 전환 (RustDesk·화면공유·VNC·Jump·Parsec 등)
- **하이브리드 절대 상태 동기화**: 토글 대신 **절대 목표 언어(`ko` / `en`)** 전송
  - 캐리어 키가 통과하는 클라이언트(RustDesk Map, 화면공유 등): HID 탭 내 동기 In-Band 캐리어(`F16`/`F17`) + UDP `expectSet` 안전망으로 DERP 릴레이 환경에서도 순서 역전(`안녀d`/`ㅗello`) 없음
  - 캐리어가 차단되는 모드(RustDesk Translate 등): 자동으로 **Tailscale 직접 UDP** + Direct 경로 적응형 FIFO 버퍼링으로 전환
- **원격 창 포커스 시 로컬 Mac 자동 영문(ABC) 고정**: 로컬 한글 IME가 원격 입력을 가로채 자소가 깨지는 문제 방지
- **메뉴바 원격 상태 표시(`⚡한` / `⚡EN`) + 비활성화 미니 HUD**
- **보안**: `0.0.0.0` 미바인딩(Tailscale IPv4/IPv6 + `127.0.0.1` 전용), `utun*` 인터페이스 검증, `tailscale status`/`whois` 검증, Keychain Curve25519 기기 신원 + **6자리 SAS 상호 확인** + 피어별 HKDF-SHA256 HMAC + 슬라이딩 윈도우 재전송 방지

---

## 빠른 설정 가이드 (2분)

1. **양쪽 Mac에 설치**: 각 Mac에서 `./install.sh --link-cli` 실행
2. **권한 허용**: 첫 실행 시 Gatekeeper 안내가 뜨면 `우클릭 → 열기` 후, **[시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용]**에서 `TailIME` 허용
3. **10초 페어링**: 메뉴바 `TailIME` → **설정 → 원격 Tailscale** 탭에서
   - **직접 페어링**: 피어 선택 → **직접 페어링 요청** → 양쪽 화면에 동시에 뜨는 **6자리 확인 코드(SAS)** 일치 확인 후 **승인 및 신뢰**
   - **토큰 교환 (RustDesk 화면 안에서 바로 페어링할 때 편리)**: Mac A **내 페어링 토큰 복사** → Mac B **상대 토큰 붙여넣기** (반대 방향도 동일)

---

## CLI (`tailime-ctl`)

```bash
tailime-ctl status
tailime-ctl toggle
tailime-ctl set ko
tailime-ctl set en
tailime-ctl peers
tailime-ctl remote-set 100.64.0.10 ko
tailime-ctl pair-export
echo "TKP1:..." | tailime-ctl pair-import
```

---

## 트러블슈팅 (문제 해결)

### 1. RustDesk · 화면공유에서 한영키를 눌러도 원격 Mac이 바뀌지 않을 때
- **양쪽 Mac 손쉬운 사용 권한 확인:** 양쪽 Mac에서 `tailime-ctl status`를 실행해 `accessibility: true`, `hidTap: true`, `sessionTap: true`인지 확인하세요.
- **Tailscale 페어링 및 통신 확인:** `tailime-ctl peers`에서 원격 Mac의 `daemonReachable: true`를 확인하세요. `false`라면 **설정 → 원격 Tailscale**에서 6자리 SAS 직접 페어링 또는 `TKP1` 토큰 교환을 완료해야 합니다.
- **메뉴바 `⚡` 표시 확인:** RustDesk 창을 클릭했을 때 메뉴바가 **`⚡한` / `⚡EN`**으로 바뀌어야 원격 제어 상태로 인식된 것입니다. 일반 `한`/`EN`만 보이면 메뉴바 **원격 대상 Mac 선택**에서 대상 Mac을 직접 고정(Pin)하거나 RustDesk Direct IP 연결을 사용하세요.
- **중복 한영 전환 앱 종료:** **`gksdud`**, **`HangulSync`**, **Input Source Pro**, **Kawa** 등이 동시에 켜져 있으면 같은 이벤트 탭을 먼저 가로채 충돌합니다. `tailime-ctl status`의 `conflictingApps` 또는 **설정 → 진단** 탭에서 충돌 앱을 확인하고 종료해 주세요.

### 2. 한영키를 누른 뒤 창 최대화, Dock 선택 등 엉뚱한 단축키가 실행될 때
- **양쪽 Mac 모두 `v1.0.1` 이상으로 업데이트:** `v1.0.1`은 합성 키 입력 시 `Fn(Globe)` / 모디파이어 플래그가 macOS WindowServer에 남는 문제를 원천 차단하고, 기본 전송 방식을 **Tailscale UDP 직접 전송**으로 설정해 RustDesk에 보조 F키(`F16`/`F17`/`F20`)를 주입하지 않습니다.
- **RustDesk 권장 설정:** **설정 → 원격 Tailscale → 전송 방식**을 **Tailscale UDP 직접 전송 (권장 · RustDesk 안전)**으로 유지하세요.
- **`v1.0.0`에서 이미 `Fn(Globe)` 키가 걸린 경우:** 양쪽 Mac에서 물리 키보드의 `Fn(Globe)` 키를 한 번 눌렀다 뗀 뒤 `v1.0.1`로 업데이트하세요.

### 3. 다양한 한영키(좌/우 `Control`, `Ctrl+Space`, `Cmd+Space`, `Shift+Space`, `Caps Lock`, Karabiner `to_if_alone` 등)가 안 먹힐 때
- **설정 → 한영키** 탭에서 원하는 프리셋(모든 좌/우 `Control`·`Option`·`Command`·`Shift` 단독 탭 및 `*+Space` 조합 포함)을 추가하거나 **한영키 직접 녹화...**로 직접 등록하세요.
- macOS 기본 **`Caps Lock(한/A)`** 사용 시: *시스템 설정 → 키보드 → 입력 소스 → 'Caps Lock 키를 사용하여 ABC 입력 소스로 전환'*이 켜져 있는지, Karabiner에서 `caps_lock`을 다른 키로 덮어쓰지 않았는지 확인하세요.
- **암호 입력 보호(Secure Input):** 터미널 `sudo`, 1Password, 잠금 화면 등 암호 입력창이 열려 있으면 macOS 보안 정책상 모든 이벤트 탭이 일시 차단됩니다. 메뉴바와 **진단** 탭에 표시되는 앱의 암호 입력창을 닫으면 즉시 복구됩니다.

### 4. 업데이트·재빌드 후 손쉬운 사용 토글은 켜져 있는데 동작하지 않을 때
- Ad-hoc 서명 앱은 바이너리가 교체되면 macOS TCC가 이전 서명을 기억해 권한이 무효화될 수 있습니다. **[시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용]**에서 `TailIME`을 선택해 **`-` 버튼으로 제거한 뒤 `+`로 `/Applications/TailIME.app`을 다시 추가**하세요.
- 소스에서 자주 재빌드한다면 `./scripts/setup-local-cert.sh`로 로컬 인증서를 1회 생성해 서명하면 권한이 유지됩니다.

### 5. 10초 빠른 진단
```bash
tailime-ctl status   # 권한, 이벤트 탭, 감지된 트리거, 충돌 앱(conflictingApps), 원격 인식 상태 확인
tailime-ctl peers    # Tailscale 온라인/Direct 경로 및 상대 TailIME 응답(daemonReachable) 확인
```
또는 메뉴바 **진단 및 실시간 키 테스트...**를 열어 키 입력 시 실제로 들어오는 키코드·플래그를 실시간으로 확인할 수 있습니다.

---

## 소스에서 빌드

Xcode 전체 앱 없이 **Xcode Command Line Tools**(`xcode-select --install`)만으로 빌드·테스트됩니다.

```bash
git clone https://github.com/wmyung/tailime.git
cd tailime
swift run tailime-test
./scripts/package-dist.sh
```

> 재빌드 후에도 macOS 손쉬운 사용 권한을 유지하려면 `./scripts/setup-local-cert.sh`로 로컬 서명 인증서를 한 번 만든 뒤 `CODESIGN_IDENTITY="TailIME Local Signing" ./scripts/package-dist.sh`로 빌드하세요.

## 라이선스

[MIT](./LICENSE) © 2026 wmyung
