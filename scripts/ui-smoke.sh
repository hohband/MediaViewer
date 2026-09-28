#!/usr/bin/env bash
# UI 冒烟测试：真的把 App 起来，检查窗口标题、预览区是否画出内容、元数据面板是否有文字。
#
# 需要「屏幕录制」权限（screencapture 用），没有权限时脚本会明确报错退出。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-Debug}"
SAMPLES=".build/samples"
APP=".build/DerivedData/Build/Products/$CONFIGURATION/MediaViewer.app"
BIN="$APP/Contents/MacOS/MediaViewer"
PROBE=".build/window-probe"
SHOT=".build/ui-shot.png"

fail() { echo "❌ $*" >&2; pkill -f "MacOS/MediaViewer" 2>/dev/null || true; exit 1; }

./scripts/build.sh "$CONFIGURATION" > /dev/null
./scripts/make-samples.sh "$SAMPLES" > /dev/null

echo "== 编译窗口探针 =="
swiftc -swift-version 5 -parse-as-library -O \
  -module-cache-path .build/modulecache \
  -o "$PROBE" Tools/WindowProbe/WindowProbe.swift

# 每个用例只放一个文件，保证它就是列表里的第一个。
rm -rf .build/ui-image .build/ui-video
mkdir -p .build/ui-image .build/ui-video
cp "$SAMPLES/img-1.jpg" .build/ui-image/
cp "$SAMPLES/vid-1.mp4" .build/ui-video/

# check <文件夹> <期望窗口标题> <预览区最低彩色比例>
check() {
  local folder="$1" expected_title="$2" min_colorful="$3"

  pkill -f "MacOS/MediaViewer" 2>/dev/null || true
  sleep 1

  echo
  echo "== 用例: $(basename "$folder") =="
  nohup "$BIN" "$folder" > .build/ui-smoke-app.log 2>&1 &
  disown 2>/dev/null || true
  sleep 8

  # 激活到最前，避免被别的窗口盖住（LaunchServices 激活不需要额外权限）。
  open -a "$PWD/$APP"
  sleep 2

  local x y w h title
  read -r x y w h title < <("$PROBE" window MediaViewer) || fail "拿不到窗口信息"
  echo "  窗口: ${w}x${h} @ ($x,$y) 标题=\"$title\""

  [ "$title" = "$expected_title" ] || fail "窗口标题应为 $expected_title，实际是 \"$title\""

  screencapture -x -R"$x,$y,$w,$h" "$SHOT" || fail "截屏失败（可能缺少屏幕录制权限）"
  [ -s "$SHOT" ] || fail "截屏文件是空的"

  local preview panel
  preview="$("$PROBE" stats "$SHOT" 0.01 0.68 0.08 0.88)"
  panel="$("$PROBE" stats "$SHOT" 0.72 0.98 0.14 0.84)"
  echo "  预览区: $(echo "$preview" | tr '\n' ' ')"
  echo "  元数据区: $(echo "$panel" | tr '\n' ' ')"

  local colorful preview_colors panel_dark
  colorful="$(echo "$preview" | awk -F= '/^colorful_percent=/{print $2}')"
  preview_colors="$(echo "$preview" | awk -F= '/^colors=/{print $2}')"
  panel_dark="$(echo "$panel" | awk -F= '/^dark_percent=/{print $2}')"

  awk -v value="$colorful" -v min="$min_colorful" 'BEGIN { exit !(value >= min) }' \
    || fail "预览区彩色像素只有 ${colorful}%，低于 ${min_colorful}%：画面没有真正画出来"
  awk -v value="$preview_colors" -v min=20 'BEGIN { exit !(value >= min) }' \
    || fail "预览区只有 ${preview_colors} 种颜色，疑似空白"
  awk -v value="$panel_dark" -v min=0.3 'BEGIN { exit !(value >= min) }' \
    || fail "元数据面板几乎没有深色像素（${panel_dark}%），文字可能没渲染"

  echo "  ✅ 通过"
}

check .build/ui-image "img-1.jpg" 50
check .build/ui-video "vid-1.mp4" 30

pkill -f "MacOS/MediaViewer" 2>/dev/null || true
echo
echo "UI 冒烟测试全部通过 ✅"