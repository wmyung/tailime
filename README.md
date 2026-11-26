# TailIME

**Zero-lag Korean/English switching on macOS — locally and across Tailscale-connected remote Macs. Works with Karabiner, native shortcuts, RustDesk (Translate & Map), Screen Sharing, and VNC. Zero dependencies. No telemetry.**

**English** | [한국어 (Korean Guide)](README.ko.md)

[![Platform](https://img.shields.io/badge/macOS-13%20%E2%80%93%2026%2B-black)](https://github.com/wmyung/tailime/releases/latest)
[![Arch](https://img.shields.io/badge/arch-Universal%20(arm64%20%2B%20x86__64)-blue)](https://github.com/wmyung/tailime/releases/latest)
[![Runtime](https://img.shields.io/badge/runtime-native%20Swift%20%2B%20AppKit-orange)](#architecture)
[![Dependencies](https://img.shields.io/badge/dependencies-zero%20external%20packages-brightgreen)](#build-from-source)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Download](https://img.shields.io/badge/Download-TailIME--1.0.1--macos.zip-0071e3)](https://github.com/wmyung/tailime/releases/download/v1.0.1/TailIME-1.0.1-macos.zip)

---

**TailIME** is a lightweight native macOS menu bar utility built to end two chronic headaches for Korean Mac users:

1. **Sluggish local switching & dropped first characters** — macOS switches on key-up (causing rollover typos like `한dud` → `하dud`), and macOS 26+ kills `com.apple.TextInputSwitcher` under memory pressure so the first switch press after idle does nothing.
2. **Broken Korean/English switching over remote desktop** — when controlling a remote Mac over Tailscale via RustDesk, Apple Screen Sharing, VNC, Jump Desktop, or Parsec, your local OS or Karabiner intercepts the switch key, Translate vs Map mode breaks Hangul composition, or local Hangul IME hijacks keystrokes meant for the remote host.

Install `TailIME.app` on both Macs, pair in 10 seconds with a 6-digit SAS code, and keep your existing Karabiner or macOS keyboard setup completely untouched.

---

## Direct Download

Download the Universal (`arm64` + `x86_64`) package from GitHub Releases:

- **[TailIME-1.0.1-macos.zip](https://github.com/wmyung/tailime/releases/download/v1.0.1/TailIME-1.0.1-macos.zip)** ([SHA-256](https://github.com/wmyung/tailime/releases/download/v1.0.1/TailIME-1.0.1-macos.zip.sha256))

```bash
unzip TailIME-1.0.1-macos.zip
cd TailIME-1.0.1
./install.sh --link-cli
```

> **Note on existing settings:** `TailIME` **never modifies** `~/.config/karabiner/karabiner.json` or `com.apple.symbolichotkeys`. It reads your existing switch keys (`F18`, `F19`, `Ctrl+Space`, `Lang1`, etc.) automatically.

---

## Why Hybrid Two-Channel Remote Sync?

Remote desktop keystreams (TCP/QUIC) and out-of-band UDP packets travel different queues. Sending a naive UDP "toggle" races ahead of or behind rapid typing (`안녕` + `<switch>` + `hello` turns into `안녀d` or `ㅗello`) and double-toggles on retry.

`TailIME` combines **two channels** and sends **absolute target states (`ko` / `en`)** instead of non-idempotent toggles:

| | In-Band Carrier Channel | Tailscale Authenticated UDP Channel |
|---|---|---|
| **Role** | Exact keystream ordering when supported (e.g. RustDesk Map/Legacy, Screen Sharing) | Real-time language state push, 6-digit SAS pairing, auto-probe, and instant execution when carrier keys are filtered (e.g. RustDesk Translate) |
| **Payload** | Conflict-free unused F-key pair (`F16` = Korean, `F17` = English), injected synchronously in the HID event tap | Compact `TIV1` UDP packet over Tailscale WireGuard, authenticated with per-peer HKDF-SHA256 HMAC |
| **Ordering** | Arrives at the exact character boundary inside the remote keystream — even over 200ms DERP relay | Adaptive FIFO `HoldGate` on direct Tailscale paths + strict monotonic sequence ordering (stale older commands rejected) |
| **Double-toggle risk** | ❌ None (absolute target + remote anti-leak guard) | ❌ None (absolute target + idempotent cached ACK) |

---

## Comparison with Alternatives

| Feature | **TailIME** | `gksdud` | `HangulSync` | Karabiner + RustDesk Map Mode | macOS Built-in |
|---|---|---|---|---|---|
| **Zero-delay local `keyDown` switching** | ✅ Yes | ✅ Yes | ❌ No | ❌ Key-up delay | ❌ Key-up / Caps delay |
| **macOS 26+ `TextInputSwitcher` warm-up** | ✅ Automatic | ✅ Automatic | ❌ No | ❌ No | ❌ Drops first press |
| **Works without touching Karabiner** | ✅ Read-only auto-detect | ⚠️ HID conflict risk | ✅ Yes | ⚠️ Manual per-device rules | ✅ Yes |
| **Remote Mac over Tailscale (RustDesk Map & Translate)** | ✅ Both modes | ❌ Local only | ⚠️ Local IME collision | ❌ Breaks in Translate & Karabiner | ❌ Local intercepts key |
| **Auto-ABC lock on remote window focus** | ✅ Yes (prevents jamo split) | ❌ No | ❌ Mirrors both Macs | ❌ Manual | ❌ No |
| **In-band keystream ordering + UDP fallback** | ✅ Auto-hybrid | ❌ No | ❌ TCP mirror only | ❌ Key-only | ❌ No |
| **Unpaired / Windows remote fallback** | ✅ Safe OS-aware fallback | ❌ No | ❌ Mac-to-Mac only | ⚠️ Manual Right Alt | ❌ No |
| **CJK TSM direct switch fallback (`macism`-style)** | ✅ Built-in | ✅ Helper process | ❌ `TISSelectInputSource` only | ❌ No | ❌ Native only |
| **Runtime dependencies** | **Zero** (Native Swift) | Zero (Native Swift) | Zero (Native Swift) | Karabiner DriverKit | Built-in |

---

## Architecture

```mermaid
flowchart LR
    K["Local Keyboard / Karabiner<br/>(F18, F19, Ctrl+Space, Lang1, Right Cmd)"] --> HT["HID CGEventTap<br/>(.cghidEventTap, dedicated thread)"]
    HT -->|"Local app focused"| LE["LocalSwitchEngine<br/>TextInputSwitcher warm-up + atomic pulse + TSM fallback"]
    HT -->|"Remote viewer focused<br/>(RustDesk / Screen Sharing / VNC)"| RC["RemoteCoordinator<br/>Auto-ABC Lock + 4-Tier Session Resolver"]
    RC -->|"In-Band Carrier (F16/F17)<br/>exact keystream order"| RD["Remote Desktop Stream"]
    RC -->|"Tailscale UDP :39418<br/>X25519 + HMAC-SHA256"| TS["Tailscale WireGuard (utun)"]
    RD --> ST["Remote Session CGEventTap<br/>(.cgSessionEventTap, paired-gated)"]
    TS --> RE["Remote TailIME Daemon<br/>Absolute set(ko/en) + State Push + ACK"]
    ST --> RE
    RE --> RLE["Remote LocalSwitchEngine<br/>Instant Korean / English Switch"]
```

### Universal Trigger Compatibility (Zero Config Needed)

- **macOS System Hotkey `60`** (`Select the previous input source`): Auto-detected read-only. Preserves Hotkey `61` and 3+ input source semantics untouched.
- **Karabiner-Elements**: Watches `~/.config/karabiner/` directory (survives atomic file replacement) and auto-detects per-device `simple_modifications` and `complex_modifications` (`Right Cmd → F18`, `Right Opt → F19`, `Caps Lock → Ctrl+Space`, etc.).
- **Hardware Hangul (`Lang1`) & Custom Keys**: Built-in **Key Recorder** in Settings captures any key, shortcut, or standalone modifier tap (`Right Command` / `Right Option` / `Right Control`).
- **Optional Non-Karabiner HID Remapper**: Opt-in physical-keyboard-only `UserKeyMapping` (OFF by default, automatically locked if Karabiner is running).

---

## Quick Start (2 Minutes)

### 1. Install on Both Macs

Install [TailIME-1.0.1-macos.zip](https://github.com/wmyung/tailime/releases/download/v1.0.1/TailIME-1.0.1-macos.zip) on both your controller Mac (e.g. MacBook Air/Pro) and your remote Mac (e.g. Mac Pro / Mac Studio / Mac mini):

```bash
./install.sh --link-cli
```

- Because the default release bundle is ad-hoc signed, on first launch right-click `TailIME.app` → **Open** (or allow in **System Settings → Privacy & Security**).
- Grant **Accessibility** permission (**System Settings → Privacy & Security → Accessibility → TailIME**) on both Macs.

> **Developer Tip (Keep Accessibility Permission Across Rebuilds):** Run `./scripts/setup-local-cert.sh` once to create a local code-signing certificate in your Login Keychain, then build with `CODESIGN_IDENTITY="TailIME Local Signing" ./scripts/package-dist.sh`.

### 2. Pair Your Macs Over Tailscale (10 Seconds)

Open the menu bar icon (`한` / `EN`) → **설정 → 원격 Tailscale**:

- **Option A — Direct 6-Digit SAS Pairing**
  1. Select your remote Mac from the auto-discovered Tailscale peer list and click **직접 페어링 요청**.
  2. Both Macs immediately exchange Curve25519 public keys and display the exact same **6-digit SAS code** (`123-456`).
  3. Confirm both codes match and click **승인 및 신뢰** on both Macs.
  4. Click **연결 테스트(Ping)** to confirm direct RTT (typically `1–5 ms` on LAN/Direct Tailscale).

- **Option B — Copy/Paste Token (Convenient Inside a Remote Session)**
  1. Click **내 페어링 토큰 복사** on Mac A → paste into **상대 토큰 붙여넣기** on Mac B.
  2. Repeat from Mac B → Mac A.

### 3. Use Normally

- Focus any local app → press your usual Korean/English key → instant `keyDown` switch.
- Focus **RustDesk**, **Apple Screen Sharing**, **TigerVNC**, **Jump Desktop**, **Parsec**, **Moonlight**, **NoMachine**, or **AnyDesk**:
  - Local Mac automatically locks to **English (ABC)** so local Hangul IME never garbles remote typing.
  - Press your usual local Korean/English key → remote Mac switches instantaneously (`⚡한` / `⚡EN` in menu bar + subtle non-focus-stealing mini HUD).
  - Unpaired or Windows peers automatically use safe OS-aware fallback (`Right Option` for Windows Map mode; never injects `Shift+Space` unless explicitly selected).

---

## CLI (`tailime-ctl`)

```bash
tailime-ctl status                          # Local/remote state, permissions, detected triggers
tailime-ctl toggle                          # Fast local toggle
tailime-ctl set ko                          # Deterministic local switch to Korean
tailime-ctl set en                          # Deterministic local switch to English
tailime-ctl peers                           # Tailscale peers & TailIME daemon reachability
tailime-ctl remote-set 100.64.0.10 ko       # Deterministic remote Mac switch over Tailscale
tailime-ctl pair-export                     # Print your TKP1 pairing token
echo "TKP1:..." | tailime-ctl pair-import   # Register peer token via stdin (kept out of argv)
tailime-ctl pause                           # Temporarily pause interception
tailime-ctl resume                          # Resume interception
tailime-ctl quit                            # Quit TailIME cleanly
```

---

## Security & Privacy Model

- **Zero Telemetry / Zero Cloud Relay**: All remote traffic stays strictly inside your Tailscale WireGuard Tailnet.
- **No `0.0.0.0` Binding**: UDP listener (`39418`) binds exclusively to your Tailscale IPv4 (`100.64.0.0/10`), Tailscale IPv6 (`fd7a:115c:a1e0::/48`), and `127.0.0.1`.
- **Kernel Interface Verification**: Incoming packets are checked via `IP_RECVIF` / `IPV6_PKTINFO` to ensure arrival on `utun*` (or `lo*` for loopback self-tests) and verified against `tailscale status` / `tailscale whois`.
- **Per-Peer Cryptography**: Each Mac generates a persistent `Curve25519` identity in macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and derives a unique per-peer 256-bit HMAC key via `HKDF-SHA256`, verified in constant time via CryptoKit.
- **Replay & Order Protection**: Monotonic 64-bit sliding-window replay guard per `(deviceID, bootSessionID)` with strict latest-sequence enforcement for state-mutating commands and `(deviceID, sourceIP, nonce, replyToSeq)` ACK binding.
- **Zero Keystroke Storage**: Typed text is never logged or persisted. The Diagnostics monitor only displays transient keyCode/modifier metadata while the Diagnostics tab is explicitly open.

---

## Troubleshooting

### 1. Pressing the switch key inside RustDesk / Screen Sharing does not switch the remote Mac
- **Check Accessibility on BOTH Macs:** Run `tailime-ctl status` on both Macs and verify `accessibility: true`, `hidTap: true`, and `sessionTap: true`.
- **Check Tailscale pairing & reachability:** Run `tailime-ctl peers` and confirm the remote Mac shows `daemonReachable: true`. If not, pair both Macs under **Settings → 원격 Tailscale** (6-digit SAS or `TKP1` token exchange).
- **Check the menu bar indicator:** When focused on RustDesk/Screen Sharing, the menu bar should show **`⚡한`** / **`⚡EN`**. If it shows plain `한`/`EN`, TailIME hasn't matched the remote window yet — select the remote Mac manually from **Menu Bar → 원격 대상 Mac 선택**, or verify Tailscale Direct IP is enabled in RustDesk.
- **Quit competing IME switchers:** Running **`gksdud`**, **`HangulSync`**, **Input Source Pro**, or **Kawa** alongside TailIME causes `CGEventTap` conflicts (the competing app can swallow `F18`/`F19` before TailIME sees it). Check `conflictingApps` in `tailime-ctl status` or the **Diagnostics** tab and quit competing utilities.

### 2. Pressing the switch key triggers unexpected shortcuts (window maximize, Dock focus, etc.)
- **Update both Macs to `v1.0.1` or later:** `v1.0.1` eliminates synthetic `maskSecondaryFn` (`Fn/Globe`) modifier latching on `keyUp` and uses **Tailscale UDP Direct** by default (never injecting synthetic `F16`/`F17`/`F20` keys into RustDesk, whose `rdev`/`enigo` macOS keycode translation can mis-map extended F-keys).
- **Recommended transport setting for RustDesk:** Keep **Settings → 원격 Tailscale → 전송 방식** set to **Tailscale UDP 직접 전송 (권장 · RustDesk 안전)**.
- **If `Fn/Globe` was stuck from `v1.0.0`:** Tap the physical `Fn (Globe)` key once on each Mac, then update to `v1.0.1`.

### 3. Custom switch keys (`Left/Right Control`, `Ctrl+Space`, `Cmd+Space`, `Shift+Space`, `Caps Lock`, Karabiner `to_if_alone`) are not detected
- Open **Settings → 한영키** and either pick a preset (supports all left/right `Control`, `Option`, `Command`, `Shift` standalone taps and `*+Space` combos) or click **한영키 직접 녹화...** to capture your exact key.
- For macOS native **`Caps Lock (한/A)`**, confirm *System Settings → Keyboard → Input Sources → Use the Caps Lock key to switch to and from ABC* is enabled and not overridden by Karabiner.
- **Secure Input active:** When a password field (`sudo` in Terminal, 1Password, login prompt) enables macOS Secure Input, macOS blocks all event taps by design. TailIME displays the blocking app in the menu bar and **Diagnostics** tab — close that prompt to resume automatically.

### 4. Accessibility toggle is ON after updating/rebuilding, yet keys stop working
- Ad-hoc signed macOS builds change their code signature hash on rebuild, causing macOS TCC to hold a stale grant. Open **System Settings → Privacy & Security → Accessibility**, select `TailIME`, click **`-`** to remove it, then click **`+`** to re-add `/Applications/TailIME.app`.
- If you rebuild frequently from source, run `./scripts/setup-local-cert.sh` once and build with `CODESIGN_IDENTITY="TailIME Local Signing" ./scripts/package-dist.sh` so permissions persist across rebuilds.

### 5. Fast 10-Second Diagnostic Checklist
```bash
tailime-ctl status   # Verify accessibility, hidTap, sessionTap, triggers, conflictingApps, remoteFocused
tailime-ctl peers    # Verify Tailscale peer online, direct path, and daemonReachable
```
Or open **Menu Bar → 진단 및 실시간 키 테스트...** to inspect live keyCodes/modifier flags (displayed transiently in-memory only; never written to disk) and copy a sanitized diagnostic summary.

---

## Build From Source

Requires only macOS 13+ and Xcode Command Line Tools (`xcode-select --install`) — full Xcode.app is not required.

```bash
git clone https://github.com/wmyung/tailime.git
cd tailime

# Run all 22 unit & live macOS loopback/CSystemBridge tests
swift run tailime-test

# Build Universal (arm64 + x86_64) TailIME.app + distribution zip
./scripts/package-dist.sh
```

Outputs are written to `dist/TailIME.app` and `dist/TailIME-1.0.1-macos.zip`.

---

## Acknowledgements

TailIME stands on the shoulders of excellent open-source macOS input engineering:

- [`codingnoye/gksdud`](https://github.com/codingnoye/gksdud) — `keyDown` synthetic pulse & macOS 26 `TextInputSwitcher` wake-up insights
- [`catgarret/HangulSync`](https://github.com/catgarret/HangulSync) — Tailscale remote Korean sync & Curve25519 SAS pairing inspiration
- [`laishulu/macism`](https://github.com/laishulu/macism) — `com.apple.tsm.portname` direct CJK switching technique
- [`mark-made/imeguard`](https://github.com/mark-made/imeguard) — remote server `eventSourceUnixProcessID` filtering & local signing workflow

## License

[MIT](./LICENSE) © 2026 wmyung
