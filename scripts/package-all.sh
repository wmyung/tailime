#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/package-dist.sh"
"$ROOT_DIR/scripts/build-windows.sh"
