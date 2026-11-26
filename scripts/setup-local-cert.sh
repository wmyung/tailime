#!/bin/bash
set -euo pipefail

CERT_NAME="${1:-TailIME Local Signing}"
TMP_DIR="$(mktemp -d /tmp/tailime-cert.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "로컬 코드 서명 인증서 생성 중: $CERT_NAME"
echo "(생성 후 build-app.sh에서 CODESIGN_IDENTITY=\"$CERT_NAME\" 로 빌드하면 재빌드 후에도 손쉬운 사용 권한이 유지됩니다.)"

openssl req -x509 -newkey rsa:2048 \
  -keyout "$TMP_DIR/key.pem" \
  -out "$TMP_DIR/cert.pem" \
  -days 3650 -nodes \
  -subj "/CN=$CERT_NAME" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1

PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy \
  -out "$TMP_DIR/identity.p12" \
  -inkey "$TMP_DIR/key.pem" \
  -in "$TMP_DIR/cert.pem" \
  -passout "pass:$PASS"

security import "$TMP_DIR/identity.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" \
  -T /usr/bin/codesign

security add-trusted-cert -r trustRoot -p codeSign \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$TMP_DIR/cert.pem"

echo "✓ 완료! 이제 아래 명령으로 서명 빌드할 수 있습니다:"
echo "  CODESIGN_IDENTITY=\"$CERT_NAME\" ./scripts/package-dist.sh"
