#!/usr/bin/env bash
# 构建并启动 App，可选传入一个要打开的文件夹。
#   ./scripts/run.sh /path/to/folder
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-Debug}"
./scripts/build.sh "$CONFIGURATION"

APP=".build/DerivedData/Build/Products/$CONFIGURATION/MediaViewer.app"

if [ "$#" -gt 0 ]; then
  open "$APP" --args "$1"
else
  open "$APP"
fi