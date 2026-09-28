#!/usr/bin/env bash
# 命令行构建 MediaViewer.app（不需要打开 Xcode）。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Debug}"
DERIVED_DATA=".build/DerivedData"

xcodebuild \
  -project MediaViewer.xcodeproj \
  -scheme MediaViewer \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

echo
echo "构建产物：$DERIVED_DATA/Build/Products/$CONFIGURATION/MediaViewer.app"