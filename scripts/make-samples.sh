#!/usr/bin/env bash
# 生成用于验证的样例媒体文件（图片带 EXIF / GPS，视频带元数据）。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-.build/samples}"
FFMPEG="${FFMPEG:-ffmpeg}"

rm -rf "$OUT"
mkdir -p "$OUT"

if ! command -v "$FFMPEG" >/dev/null 2>&1; then
  echo "需要 ffmpeg 才能生成样例文件：brew install ffmpeg" >&2
  exit 1
fi

# --- 图片 ---------------------------------------------------------------
"$FFMPEG" -y -loglevel error -f lavfi -i "testsrc2=size=800x600" -frames:v 1 "$OUT/img-1.jpg"
"$FFMPEG" -y -loglevel error -f lavfi -i "gradients=size=640x480" -frames:v 1 "$OUT/img-2.jpg"
"$FFMPEG" -y -loglevel error -f lavfi -i "testsrc2=size=320x240" -frames:v 1 "$OUT/img-10.png"

python3 scripts/inject_exif.py "$OUT/img-1.jpg" \
  --make "Probe Cam" \
  --model "Probe Cam X" \
  --software "MediaViewer Probe" \
  --lens "Probe Lens 50mm f/1.8" \
  --datetime "2024:05:06 07:08:09" \
  --fnumber 1.8 \
  --exposure 0.004 \
  --iso 200 \
  --focal 50 \
  --width 800 \
  --height 600

python3 scripts/inject_exif.py "$OUT/img-2.jpg" \
  --make "Probe Cam" \
  --model "Probe Cam Y" \
  --datetime "2024:06:07 08:09:10" \
  --gps-lat 37.7749 \
  --gps-lon -122.4194 \
  --gps-alt 12.5 \
  --width 640 \
  --height 480

# --- 视频 ---------------------------------------------------------------
"$FFMPEG" -y -loglevel error \
  -f lavfi -i "testsrc2=size=640x480:rate=30" \
  -f lavfi -i "sine=frequency=440" \
  -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
  -metadata title="Probe Video" \
  -metadata artist="MediaViewer Probe" \
  -metadata creation_time="2024-05-06T07:08:09Z" \
  "$OUT/vid-1.mp4"

"$FFMPEG" -y -loglevel error \
  -f lavfi -i "testsrc2=size=320x240:rate=24" \
  -t 2 -c:v libx264 -pix_fmt yuv420p -an \
  -metadata title="Second Clip" \
  "$OUT/vid-2.mov"

# --- 干扰项：非媒体文件应当被忽略 ---------------------------------------
echo "这不是媒体文件，扫描时应该被忽略" > "$OUT/notes.txt"

echo "样例文件已生成：$OUT"
ls -1 "$OUT"