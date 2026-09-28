#!/usr/bin/env bash
# 打安装包：DMG（拖进 Applications）/ PKG（双击安装）/ ZIP（挂 GitHub Release）。
#
#   ./scripts/package.sh
#
# 产物输出到 dist/（已 gitignore），中间文件都放在 .build/package-check/。
#
# 默认 ad-hoc 签名（本机可用）。有 Apple 开发者账号时可以这样出正式分发包：
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="notary" ./scripts/package.sh
#   其中 NOTARY_PROFILE 是 `xcrun notarytool store-credentials` 存好的 keychain profile 名。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MediaViewer"
BUNDLE_ID="com.hohband.MediaViewer"
DERIVED_DATA=".build/DerivedData"
DIST="dist"
WORK=".build/package-check"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# 验证用的文件夹：docs/ 里有一张 screenshot.png，App 打开它会加载 1 个文件。
CHECK_FOLDER="$PWD/docs"

fail() {
  echo "❌ $*" >&2
  hdiutil detach "$WORK/rw-mnt" > /dev/null 2>&1 || true
  hdiutil detach "$WORK/mnt" > /dev/null 2>&1 || true
  pkill -f "MacOS/$APP_NAME" > /dev/null 2>&1 || true
  exit 1
}

# 注意：-showBuildSettings 也要带 -derivedDataPath，否则会去写全局 DerivedData。
build_setting() {
  xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$DERIVED_DATA" -showBuildSettings 2>/dev/null \
    | awk -F' = ' -v key="$1" '$1 ~ "^ *" key " *$" { print $2; exit }'
}

VERSION="$(build_setting MARKETING_VERSION)"
BUILD="$(build_setting CURRENT_PROJECT_VERSION)"
[ -n "$VERSION" ] || fail "读不到 MARKETING_VERSION"

echo "== 打包 $APP_NAME $VERSION ($BUILD)，签名标识: $SIGN_IDENTITY =="
rm -rf "$DIST" "$WORK"
mkdir -p "$DIST" "$WORK"

echo
echo "== 1/5 Release 通用二进制构建（arm64 + x86_64）=="
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  build

APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || fail "没有找到构建产物 $APP"

echo
echo "== 2/5 检查产物 =="
echo "  架构: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /' || fail "签名校验失败"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier" | sed 's/^/  /' || true

if [ "$SIGN_IDENTITY" != "-" ]; then
  echo "  用 $SIGN_IDENTITY 重新签名（hardened runtime）"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
fi

ZIP="$DIST/$APP_NAME-$VERSION.zip"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
PKG="$DIST/$APP_NAME-$VERSION.pkg"

echo
echo "== 3/5 ZIP =="
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "  ${ZIP}（$(du -h "$ZIP" | cut -f1)）"

echo
echo "== 4/5 DMG =="
STAGE="$WORK/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 这里用 makehybrid + convert，而不是 `hdiutil create -srcfolder`：
# 后者内部要先挂载一个临时镜像，在沙箱/CI 这类受限环境里会以 "目录非空" 失败。
# makehybrid 直接构建文件系统，不挂载，行为在哪儿都一样。
RAW_DMG="$WORK/$APP_NAME-$VERSION-raw.dmg"
RW_DMG="$WORK/$APP_NAME-$VERSION-rw.dmg"
hdiutil makehybrid -hfs -hfs-volume-name "$APP_NAME $VERSION" -o "$RAW_DMG" "$STAGE" > /dev/null 2>&1 \
  || fail "makehybrid 生成 DMG 失败"

# makehybrid 会给卷里每个文件带上 com.apple.FinderInfo，
# 那会让 `codesign --verify --strict` 报 "resource fork, Finder information ... not allowed"。
# 所以再走一遍可写镜像，把扩展属性清掉，最后压成只读 UDZO。
hdiutil convert "$RAW_DMG" -format UDRW -ov -o "$RW_DMG" > /dev/null 2>&1 \
  || fail "转换为可写镜像失败"
RW_MOUNT="$WORK/rw-mnt"
hdiutil detach "$RW_MOUNT" > /dev/null 2>&1 || true
rm -rf "$RW_MOUNT"
mkdir -p "$RW_MOUNT"
hdiutil attach "$RW_DMG" -nobrowse -mountpoint "$RW_MOUNT" > /dev/null || fail "挂载可写镜像失败"
xattr -cr "$RW_MOUNT/$APP_NAME.app" || true
hdiutil detach "$RW_MOUNT" > /dev/null || fail "卸载可写镜像失败"

hdiutil convert "$RW_DMG" -format UDZO -ov -o "$DMG" > /dev/null 2>&1 \
  || fail "压缩 DMG 失败"
rm -f "$RAW_DMG" "$RW_DMG"
hdiutil verify "$DMG" > /dev/null || fail "DMG 校验失败"
if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
echo "  ${DMG}（$(du -h "$DMG" | cut -f1)）"

echo
echo "== 5/5 PKG =="
PKG_ROOT="$WORK/pkg-root"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP" "$PKG_ROOT/Applications/"
pkgbuild \
  --root "$PKG_ROOT" \
  --identifier "$BUNDLE_ID" \
  --version "$VERSION" \
  --install-location / \
  "$PKG" > /dev/null
echo "  ${PKG}（$(du -h "$PKG" | cut -f1)）"
echo "  载荷条目数: $(pkgutil --payload-files "$PKG" | wc -l | tr -d ' ')"
pkgutil --payload-files "$PKG" | grep -q "Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
  || fail "PKG 载荷里没有 App 可执行文件"
if [ -n "$NOTARY_PROFILE" ]; then
  echo "  提交公证（$NOTARY_PROFILE）"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
fi

# ---------------------------------------------------------------- 验证
# 把包里的 App 真的跑一遍（--dump-state 是 App 自带的诊断入口），
# 确认打出来的东西是完整可运行的，而不是只有一个壳。
echo
echo "== 验证：包里的 App 能不能跑 =="

verify_app() {
  local binary="$1"
  local label="$2"
  local state="$WORK/state-$label.txt"
  rm -f "$state"
  "$binary" --dump-state "$state" "$CHECK_FOLDER" > /dev/null 2>&1 || true
  [ -f "$state" ] || fail "$label: App 没能写出状态文件（跑不起来？）"
  grep -q "count=1" "$state" || fail "$label: 打开 docs/ 应该加载到 1 个文件，实际: $(grep count= "$state")"
  grep -q "current=screenshot.png" "$state" || fail "$label: 首个文件应为 screenshot.png，实际: $(grep current= "$state")"
  echo "  ✅ $label: $(grep -h '^count=\|^current=' "$state" | tr '\n' ' ')"
}

# ZIP
UNZIP_DIR="$WORK/unzip"
rm -rf "$UNZIP_DIR"
mkdir -p "$UNZIP_DIR"
ditto -x -k "$ZIP" "$UNZIP_DIR"
verify_app "$UNZIP_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" "zip"

# DMG：挂载后检查签名、拖拽用的 Applications 链接，再直接跑里面的 App
MOUNT_POINT="$WORK/mnt"
hdiutil detach "$MOUNT_POINT" > /dev/null 2>&1 || true
rm -rf "$MOUNT_POINT"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_POINT" > /dev/null || fail "挂载 DMG 失败"
[ -L "$MOUNT_POINT/Applications" ] || fail "DMG 里缺少 Applications 链接"
codesign --verify --strict "$MOUNT_POINT/$APP_NAME.app" 2>&1 | sed 's/^/    /' || fail "DMG 里的 App 签名校验失败"
echo "  ✅ dmg: Applications 链接在，App 签名有效"
verify_app "$MOUNT_POINT/$APP_NAME.app/Contents/MacOS/$APP_NAME" "dmg"
hdiutil detach "$MOUNT_POINT" > /dev/null

# PKG：展开载荷，直接跑里面的 App（目标目录必须不存在，否则 pkgutil 会失败）
EXPAND_DIR="$WORK/pkg-expand"
rm -rf "$EXPAND_DIR"
pkgutil --expand-full "$PKG" "$EXPAND_DIR" > /dev/null 2>&1 || fail "PKG 展开失败"
PKG_BINARY="$(find "$EXPAND_DIR" -path "*$APP_NAME.app/Contents/MacOS/$APP_NAME" -type f | head -1)"
[ -n "$PKG_BINARY" ] || fail "PKG 载荷里没有找到 App 可执行文件"
verify_app "$PKG_BINARY" "pkg"

echo
echo "== 完成 =="
for artifact in "$DMG" "$PKG" "$ZIP"; do
  echo "  $(shasum -a 256 "$artifact" | awk '{print $1}')  $(basename "$artifact")"
done

if [ "$SIGN_IDENTITY" = "-" ]; then
  cat <<'TIP'

注意：当前是 ad-hoc 签名，没有 Developer ID，也没有公证。
换一台 Mac 打开时 Gatekeeper 会拦（提示“无法验证开发者”/“已损坏”），
用户可以右键点 App 选「打开」，或者执行：
  xattr -dr com.apple.quarantine /Applications/MediaViewer.app
要正式分发，需要 Apple 开发者账号里的 Developer ID Application 证书，
然后按脚本头部的说明带上 SIGN_IDENTITY 和 NOTARY_PROFILE 重新打包。
TIP
fi