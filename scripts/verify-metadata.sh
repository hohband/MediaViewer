#!/usr/bin/env bash
# 端到端验证：生成样例媒体文件 -> 用命令行探针跑 App 里的同一份扫描 / 元数据实现。
set -euo pipefail
cd "$(dirname "$0")/.."

SAMPLES=".build/samples"
BIN=".build/metadata-probe"
mkdir -p .build

./scripts/make-samples.sh "$SAMPLES"

echo
echo "== 编译探针（复用 App 的模型与 Services 源码）=="
swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -module-cache-path .build/modulecache \
  -o "$BIN" \
  MediaViewer/Models/MediaItem.swift \
  MediaViewer/Services/MediaScanner.swift \
  MediaViewer/Services/MediaLibrary.swift \
  MediaViewer/Services/MetadataModels.swift \
  MediaViewer/Services/MetadataFormat.swift \
  MediaViewer/Services/MetadataReader.swift \
  Tools/MetadataProbe/Probe.swift

echo
echo "== 运行探针（--check 会校验样例契约）=="
"$BIN" "$SAMPLES" --check

echo
echo "== 交叉验证：用系统自带工具独立解析同一批样例 =="

echo "--- sips 读取 img-1.jpg 的 EXIF ---"
sips -g all "$SAMPLES/img-1.jpg" 2>/dev/null \
  | grep -E "make:|model:|software:|creation:|pixelWidth:|pixelHeight:" \
  | sed 's/^/    /'

sips_make="$(sips -g make "$SAMPLES/img-1.jpg" 2>/dev/null | awk -F': ' '/ make:/{print $2}')"
sips_model="$(sips -g model "$SAMPLES/img-1.jpg" 2>/dev/null | awk -F': ' '/ model:/{print $2}')"
if [ "$sips_make" != "Probe Cam" ] || [ "$sips_model" != "Probe Cam X" ]; then
  echo "sips 交叉验证失败：make=$sips_make model=$sips_model" >&2
  exit 1
fi
echo "    sips 断言通过：make=Probe Cam / model=Probe Cam X ✅"

echo "--- ffprobe 读取 vid-1.mp4 的容器元数据 ---"
ffprobe -v error -show_entries format_tags=title,artist,creation_time \
  -of default=noprint_wrappers=1 "$SAMPLES/vid-1.mp4" 2>/dev/null | sed 's/^/    /'

ffprobe_title="$(ffprobe -v error -show_entries format_tags=title -of default=noprint_wrappers=1:nokey=1 "$SAMPLES/vid-1.mp4" 2>/dev/null)"
if [ "$ffprobe_title" != "Probe Video" ]; then
  echo "ffprobe 交叉验证失败：title=$ffprobe_title" >&2
  exit 1
fi
echo "    ffprobe 断言通过：title=Probe Video ✅"

echo
echo "全部验证通过 ✅"