#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/TailIME.app"
if [[ ! -d "$APP_SRC" ]]; then
  APP_SRC="$SCRIPT_DIR/../dist/TailIME.app"
fi
[[ -d "$APP_SRC" ]] || { echo "오류: TailIME.app을 찾을 수 없습니다. 먼저 scripts/build-app.sh를 실행하세요." >&2; exit 1; }

DEST_DIR="/Applications"
LINK_CLI=0
LAUNCH=1

for arg in "$@"; do
  case "$arg" in
    --user) DEST_DIR="$HOME/Applications" ;;
    --link-cli) LINK_CLI=1 ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help)
      echo "사용법: ./install.sh [--user] [--link-cli] [--no-launch]"
      echo "  --user       ~/Applications에 설치 (기본: /Applications)"
      echo "  --link-cli   ~/.local/bin/tailime-ctl 심볼릭 링크 생성"
      echo "  --no-launch  설치 후 앱 자동 실행 생략"
      exit 0
      ;;
  esac
done

echo "번들 서명 무결성 확인 중..."
codesign --verify --deep --strict "$APP_SRC"

mkdir -p "$DEST_DIR"
APP_DST="$DEST_DIR/TailIME.app"
STAGING_DST="$DEST_DIR/.TailIME.app.staging.$$"
SWAPPED_EXCHANGE=0
FRESH_INSTALL=0

atomic_swap_dirs() {
  python3 - "$1" "$2" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
RENAME_SWAP = 0x00000002
a, b = os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2])
rc = libc.renamex_np(a, b, ctypes.c_uint(RENAME_SWAP))
if rc != 0:
    err = ctypes.get_errno()
    raise OSError(err, os.strerror(err))
PY
}

cleanup_on_exit() {
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$SWAPPED_EXCHANGE" == "1" && -d "$STAGING_DST" && -d "$APP_DST" ]]; then
      echo "설치 중 오류 발생 — 기존 설치본으로 원자적 복원 중..." >&2
      atomic_swap_dirs "$APP_DST" "$STAGING_DST" || true
    elif [[ "$FRESH_INSTALL" == "1" && -d "$APP_DST" ]]; then
      rm -rf "$APP_DST" || true
    fi
  fi
  rm -rf "$STAGING_DST" || true
  exit "$rc"
}
trap cleanup_on_exit EXIT

echo "임시 경로로 복사 중..."
ditto "$APP_SRC" "$STAGING_DST"
xattr -dr com.apple.quarantine "$STAGING_DST" 2>/dev/null || true
codesign --verify --deep --strict "$STAGING_DST"

if pgrep -x TailIME >/dev/null 2>&1; then
  echo "기존 실행 중인 TailIME 종료 중..."
  pkill -x TailIME || true
  sleep 0.5
fi

# True single-syscall atomic exchange via macOS renamex_np(RENAME_SWAP):
# zero gap where TailIME.app is absent, and previous version remains at $STAGING_DST for instant rollback
# until ALL post-swap steps (including CLI symlink) succeed!
if [[ -d "$APP_DST" ]]; then
  atomic_swap_dirs "$STAGING_DST" "$APP_DST"
  SWAPPED_EXCHANGE=1
else
  mv "$STAGING_DST" "$APP_DST"
  FRESH_INSTALL=1
fi

if [[ "$LINK_CLI" == "1" ]]; then
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$APP_DST/Contents/Helpers/tailime-ctl" "$HOME/.local/bin/tailime-ctl"
  echo "CLI 링크 생성됨: $HOME/.local/bin/tailime-ctl"
fi

# Post-install steps succeeded; safe to remove swapped-out backup via trap cleanup
SWAPPED_EXCHANGE=0
FRESH_INSTALL=0

echo "✓ 설치 완료: $APP_DST"
echo "※ 기존 Karabiner-Elements 및 macOS 단축키 설정은 변경하지 않았습니다."
echo "※ 기본 패키지는 로컬/ad-hoc 서명이므로 첫 실행 시 Gatekeeper 차단이 뜨면 [우클릭 → 열기] 또는 [개인정보 보호 및 보안 → 확인 없이 열기]로 허용하세요."
echo "※ 그다음 [시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용]에서 TailIME을 허용해 주세요."

if [[ "$LAUNCH" == "1" ]]; then
  open "$APP_DST"
fi
