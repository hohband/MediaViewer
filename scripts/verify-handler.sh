#!/usr/bin/env bash
# 验证「Finder 里用 MediaViewer 打开」这条链路能跑通：
#   1. 构建产物的 Info.plist 声明了支持的文稿类型（没有它 Finder 不会列出本 App）
#   2. LaunchServices 真的把这些类型登记给了本 App（右键「打开方式」里出现它的前提）
#   3. 走 LaunchServices 打开一个文件（等于双击 / 右键「打开方式」），窗口标题变成该文件名
#
# 需要图形界面会话（和 scripts/ui-smoke.sh 一样）。只查窗口标题，不需要屏幕录制权限。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-Debug}"
APP=".build/DerivedData/Build/Products/$CONFIGURATION/MediaViewer.app"
APP_ABS=""
PROBE=".build/handler-probe"
WIN_PROBE=".build/window-probe"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
SAMPLES=".build/samples"

fail() { echo "❌ $*" >&2; pkill -f "MacOS/MediaViewer" 2>/dev/null || true; exit 1; }

./scripts/build.sh "$CONFIGURATION" > /dev/null
./scripts/make-samples.sh "$SAMPLES" > /dev/null

[ -d "$APP" ] || fail "没有构建产物 $APP"
APP_ABS="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
PLIST="$APP/Contents/Info.plist"

echo "== 1/3 Info.plist 里的文稿类型声明 =="
TYPES="$(plutil -extract CFBundleDocumentTypes xml1 -o - "$PLIST" 2>/dev/null)" \
  || fail "Info.plist 里没有 CFBundleDocumentTypes（Finder 不会把本 App 列进「打开方式」）"
for uti in public.jpeg public.png public.heic com.apple.quicktime-movie public.mpeg-4; do
  printf '%s' "$TYPES" | grep -q "<string>$uti</string>" || fail "Info.plist 没有声明 $uti"
  echo "  ✅ $uti"
done

echo
echo "== 2/3 LaunchServices 注册 =="
"$LSREGISTER" -f "$APP_ABS"

swiftc -swift-version 5 -parse-as-library -O \
  -module-cache-path .build/modulecache \
  -o "$PROBE" Tools/HandlerProbe/HandlerProbe.swift

for sample in "$SAMPLES/img-1.jpg" "$SAMPLES/vid-1.mp4"; do
  handlers="$("$PROBE" handlers "$sample")"
  if ! printf '%s\n' "$handlers" | grep -qF "$APP_ABS"; then
    fail "$(basename "$sample") 的处理程序候选里没有 $APP_ABS
     候选：$(printf '%s\n' "$handlers" | cut -f2 | paste -sd', ' -)"
  fi
  default_app="$(printf '%s\n' "$handlers" | awk -F'\t' '$1 == "default" { print $2 }')"
  echo "  ✅ $(basename "$sample")：候选里有 MediaViewer（系统默认：${default_app:-无}）"
done

echo
echo "== 3/3 用「打开方式」的方式打开文件 =="
swiftc -swift-version 5 -parse-as-library -O \
  -module-cache-path .build/modulecache \
  -o "$WIN_PROBE" Tools/WindowProbe/WindowProbe.swift

check_open() {
  local file="$1" expected="$2" window title

  pkill -f "MacOS/MediaViewer" 2>/dev/null || true
  sleep 1

  open -a "$APP_ABS" "$file" || fail "LaunchServices 拒绝把 $file 交给 MediaViewer"
  sleep 6

  window="$("$WIN_PROBE" window MediaViewer)" || fail "拿不到 MediaViewer 的窗口信息"
  title="$(printf '%s\n' "$window" | awk '{$1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print}')"
  [ "$title" = "$expected" ] || fail "窗口标题应为 $expected，实际是 \"$title\""
  echo "  ✅ $file → 窗口标题 $title"
}

check_open "$SAMPLES/img-1.jpg" "img-1.jpg"
check_open "$SAMPLES/vid-1.mp4" "vid-1.mp4"

pkill -f "MacOS/MediaViewer" 2>/dev/null || true

# 收尾：同一个 bundle id 有多份拷贝时，别让 Finder 打开到 .build 里的构建产物。
# 装了正式版就只留它的注册；没装就把构建产物留在注册表里（开发时右键菜单才好用）。
if [ -d /Applications/MediaViewer.app ]; then
  "$LSREGISTER" -u "$APP_ABS" > /dev/null 2>&1 || true
  "$LSREGISTER" -f -trusted /Applications/MediaViewer.app
  echo
  echo "已把处理程序注册指回 /Applications/MediaViewer.app（构建产物 $APP_ABS 已从注册表移除）"
fi

echo
echo "Finder 处理程序验证全部通过 ✅"
