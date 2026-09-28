#!/usr/bin/env python3
"""MediaViewer 应用图标生成器。

图标本身是纯代码画出来的（Pillow + numpy），没有二进制设计稿：
改了参数重跑一次就能得到全套尺寸，方便跟着设计走。

用法::

    python3 Tools/IconGen/make_icon.py                 # 只生成 docs/icon-preview.png
    python3 Tools/IconGen/make_icon.py --install       # 同时写入 AppIcon.appiconset
    python3 Tools/IconGen/make_icon.py --variant b --install
    python3 Tools/IconGen/make_icon.py --export dist/icon

依赖：Pillow、numpy（只用于生成图标，构建和运行 App 都不需要）。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError as exc:  # pragma: no cover - 环境问题，给出人话提示
    sys.exit(f"需要 Pillow 和 numpy 才能生成图标：{exc}")

ROOT = Path(__file__).resolve().parents[2]
ICONSET = ROOT / "MediaViewer/Assets.xcassets/AppIcon.appiconset"
PREVIEW = ROOT / "docs/icon-preview.png"

# ---------------------------------------------------------------- 设计参数 --

CANVAS = 1024          # 逻辑画布边长；AppIcon 的 1024 档就是这个尺寸
RENDER = 3072          # 实际绘制分辨率（1024 的 3 倍超采样，再逐档降采样）
INSET = 0.030          # 图标主体四周留白（占画布比例）
CORNER = 0.2237        # 圆角半径 / 主体边长（对齐 Apple 图标栅格）
SUPER = 5.0            # 超椭圆指数，5 近似 Apple 的连续圆角
FEATHER = 0.006        # 形状边缘羽化量（f 值域），保证降采样后不锯齿

BG_TOP = "5CAEFF"      # 背景渐变：上
BG_BOTTOM = "2540CC"   # 背景渐变：下
SKY_TOP = "ECF6FF"     # 照片里的天空：上
SKY_BOTTOM = "ADD3FF"  # 照片里的天空：下
RIDGE_BACK = "6E9BEE"  # 远山
RIDGE_FRONT = "2A57CC" # 近山
SUN = "FFB733"         # 太阳
SKY_FLAT_TOP = "E4F0FF"    # 变体 B 里后面几张照片
SKY_FLAT_BOTTOM = "C2DDFF"
BADGE = "FFFFFF"       # 播放角标：底
BADGE_TRI = "2A44C8"   # 播放角标：三角

VARIANTS = {
    "a": "A · 照片 + 播放角标（默认）",
    "b": "B · 多张堆叠 + 播放角标",
    "c": "C · 播放覆盖层",
}

# appiconset 里的档位：(逻辑尺寸, scale, 像素, 文件名)
APPICON_ENTRIES = [
    ("16x16", "1x", 16, "icon_16x16.png"),
    ("16x16", "2x", 32, "icon_16x16@2x.png"),
    ("32x32", "1x", 32, "icon_32x32.png"),
    ("32x32", "2x", 64, "icon_32x32@2x.png"),
    ("128x128", "1x", 128, "icon_128x128.png"),
    ("128x128", "2x", 256, "icon_128x128@2x.png"),
    ("256x256", "1x", 256, "icon_256x256.png"),
    ("256x256", "2x", 512, "icon_256x256@2x.png"),
    ("512x512", "1x", 512, "icon_512x512.png"),
    ("512x512", "2x", 1024, "icon_512x512@2x.png"),
]

FONT_CANDIDATES = [
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/SFNS.ttf",
]


# ------------------------------------------------------------------ 小工具 --

def hexc(value: str) -> tuple[int, int, int]:
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def _linear_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> np.ndarray:
    """斜向渐变，返回 HxWx3 的 0..1 浮点数组。"""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    t = ((x + y) / (2.0 * (size - 1)))[..., None]
    a = np.array(top, dtype=np.float32) / 255.0
    b = np.array(bottom, dtype=np.float32) / 255.0
    return a * (1.0 - t) + b * t


def _radial(size: int, center: tuple[float, float], radius: float,
            strength: float, color: tuple[int, int, int] = (255, 255, 255)) -> np.ndarray:
    """径向高光（加色），center / radius 都用画布比例表示。"""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    cx, cy = center[0] * size, center[1] * size
    d = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / (radius * size)
    falloff = np.clip(1.0 - d, 0.0, 1.0) ** 2 * strength
    return falloff[..., None] * (np.array(color, dtype=np.float32) / 255.0)


def _squircle_alpha(size: int) -> np.ndarray:
    """主体形状的 alpha（0..1），超椭圆近似 Apple 的连续圆角。"""
    margin = INSET * size
    body = size - 2 * margin
    r = body / 2.0
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    dx = (x + 0.5 - (margin + r)) / r
    dy = (y + 0.5 - (margin + r)) / r
    f = np.abs(dx) ** SUPER + np.abs(dy) ** SUPER
    return np.clip((1.0 - f) / FEATHER, 0.0, 1.0)


def _rounded_alpha(w: int, h: int, radius: float) -> Image.Image:
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)
    return mask


def _body_layer(size: int) -> Image.Image:
    """蓝色渐变 + 玻璃感高光的主体，已经带上形状 alpha。"""
    rgb = _linear_gradient(size, hexc(BG_TOP), hexc(BG_BOTTOM))
    rgb = rgb + _radial(size, (0.5, 0.02), 0.95, 0.30)
    rgb = np.clip(rgb, 0.0, 1.0)

    y = np.linspace(0.0, 1.0, size, dtype=np.float32)[:, None, None]
    band = np.clip(1.0 - y / 0.12, 0.0, 1.0) ** 1.5 * 0.12      # 顶部内高光
    rgb = rgb + band * (1.0 - rgb)
    rgb = rgb * (1.0 - 0.10 * np.clip((y - 0.86) / 0.14, 0.0, 1.0))  # 底部内阴影

    img = Image.fromarray((np.clip(rgb, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8), "RGB").convert("RGBA")
    alpha = (np.clip(_squircle_alpha(size), 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    img.putalpha(Image.fromarray(alpha, "L"))
    return img


def _photo(w: int, h: int, radius: float, *, scenery: bool, flat: bool = False,
           scrim: int = 0) -> Image.Image:
    """一张圆角照片：可选山 + 太阳，可选压暗（播放覆盖层用）。"""
    top = hexc(SKY_FLAT_TOP if flat else SKY_TOP)
    bottom = hexc(SKY_FLAT_BOTTOM if flat else SKY_BOTTOM)
    rgb = _linear_gradient(max(w, h), top, bottom)[:h, :w]
    img = Image.fromarray((np.clip(rgb, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8), "RGB").convert("RGBA")
    draw = ImageDraw.Draw(img)

    def px(fx: float, fy: float) -> tuple[float, float]:
        return (fx * w, fy * h)

    if scenery:
        draw.polygon([px(0, 0.80), px(0.32, 0.40), px(0.54, 0.66), px(0.76, 0.34), px(1, 0.76),
                      px(1, 1), px(0, 1)], fill=hexc(RIDGE_BACK))
        sun_r = 0.095 * w
        sx, sy = px(0.72, 0.245)
        draw.ellipse([sx - sun_r, sy - sun_r, sx + sun_r, sy + sun_r], fill=hexc(SUN))
        draw.polygon([px(0, 1), px(0, 0.86), px(0.20, 0.60), px(0.44, 0.88), px(0.62, 0.70),
                      px(1, 1)], fill=hexc(RIDGE_FRONT))
    if scrim:
        veil = Image.new("RGBA", (w, h), (10, 20, 60, scrim))
        img.alpha_composite(veil)

    img.putalpha(_rounded_alpha(w, h, radius))
    return img


def _badge(d: int, *, tri: bool = True) -> Image.Image:
    """白底圆形播放角标。"""
    img = Image.new("RGBA", (d, d), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse([0, 0, d - 1, d - 1], fill=hexc(BADGE))
    if tri:
        cx = cy = d / 2.0
        draw.polygon([(cx - 0.20 * d, cy - 0.27 * d), (cx - 0.20 * d, cy + 0.27 * d),
                      (cx + 0.26 * d, cy)], fill=hexc(BADGE_TRI))
    return img


def _paste_shadowed(canvas: Image.Image, layer: Image.Image, xy: tuple[float, float],
                    blur: float, offset: tuple[float, float], alpha: int) -> None:
    """在 canvas 上贴一层带投影的内容。"""
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", layer.size, (12, 26, 90, alpha)),
                 (int(xy[0] + offset[0]), int(xy[1] + offset[1])), layer)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(layer, (int(xy[0]), int(xy[1])))


# -------------------------------------------------------------------- 变体 --

def build_icon(variant: str = "a", size: int = RENDER) -> Image.Image:
    """画一枚图标，返回 size x size 的 RGBA 图。"""
    if variant not in VARIANTS:
        raise SystemExit(f"未知变体 {variant!r}，可选：{', '.join(VARIANTS)}")

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(_body_layer(size))

    margin = INSET * size
    body = size - 2 * margin

    def at(fx: float, fy: float) -> tuple[float, float]:      # 主体比例 -> 像素
        return (margin + fx * body, margin + fy * body)

    def length(f: float) -> float:
        return f * body

    card_w, card_h = length(0.71), length(0.525)
    card_r = length(0.075)
    card_pos = (0.145, 0.175)          # 照片左上角（主体比例）
    badge_d = length(0.235)
    shadow_blur = length(0.028)
    fan: list[tuple[float, tuple[float, float]]] = []    # 变体 B：后面的照片 (旋转角, 中心偏移)

    if variant == "b":
        card_w, card_h = length(0.62), length(0.46)      # 留出位置给扇形展开的两张
        card_r = length(0.068)
        card_pos = (0.19, 0.21)
        fan = [(-15.0, (-0.035, -0.030)), (14.0, (0.035, -0.026))]
        for angle, (ox, oy) in fan:
            back = _photo(int(card_w), int(card_h), card_r, scenery=False, flat=True)
            back = back.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
            pos = at(0.5 + ox, 0.44 + oy)
            _paste_shadowed(canvas, back, (pos[0] - back.width / 2, pos[1] - back.height / 2),
                            shadow_blur, (0, length(0.008)), 70)

    card = _photo(int(card_w), int(card_h), card_r, scenery=True, scrim=22 if variant == "c" else 0)
    _paste_shadowed(canvas, card, at(*card_pos), shadow_blur, (0, length(0.014)), 95)

    card_right = card_pos[0] + card_w / body
    card_bottom = card_pos[1] + card_h / body
    if variant == "c":
        badge_d = length(0.27)
        centre = at(card_pos[0] + card_w / body / 2, card_pos[1] + card_h / body / 2)  # 压在照片正中
    elif variant == "b":
        centre = at(card_right - 0.055, card_bottom + 0.075)      # 小卡片右下角
    else:
        centre = at(0.785, 0.725)
    badge = _badge(int(badge_d))
    _paste_shadowed(canvas, badge, (centre[0] - badge_d / 2, centre[1] - badge_d / 2),
                    length(0.018), (0, length(0.008)), 80)
    return canvas


_MASTERS: dict[str, Image.Image] = {}


def master(variant: str = "a") -> Image.Image:
    """按 RENDER 分辨率画一次的母版，后面所有尺寸都从它降采样。"""
    if variant not in _MASTERS:
        _MASTERS[variant] = build_icon(variant, RENDER)
    return _MASTERS[variant]


def _resize(img: Image.Image, size: int) -> Image.Image:
    """缩到目标尺寸（按预乘 alpha 做盒式面积平均）。

    直接对 RGBA 插值会把透明区的黑色混进边缘，小尺寸上就是一圈暗边。
    RENDER 是所有目标档位的公倍数，factor 整除，所以这里是精确的像素平均。
    """
    if size == RENDER:
        return img.copy()
    if RENDER % size:
        return img.resize((size, size), Image.Resampling.LANCZOS)

    factor = RENDER // size
    arr = np.asarray(img).astype(np.float32) / 255.0
    alpha = arr[..., 3:4]
    boxed = np.concatenate([arr[..., :3] * alpha, alpha], axis=-1)
    boxed = boxed.reshape(size, factor, size, factor, 4).mean(axis=(1, 3))
    alpha = boxed[..., 3:4]
    rgb = np.clip(boxed[..., :3] / np.maximum(alpha, 1e-6), 0.0, 1.0)
    out = np.concatenate([rgb, alpha], axis=-1)
    return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGBA")


def render(variant: str = "a", size: int = CANVAS) -> Image.Image:
    """按目标尺寸输出。"""
    return _resize(master(variant), size)


# -------------------------------------------------------------------- 字体 --

def _font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default(size)  # type: ignore[arg-type]


# ------------------------------------------------------------------ 输出 --

def install(variant: str) -> list[Path]:
    """把选定变体写进 AppIcon.appiconset，并更新 Contents.json。"""
    ICONSET.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for _, _, px, name in APPICON_ENTRIES:
        path = ICONSET / name
        render(variant, px).save(path, "PNG")
        written.append(path)

    contents = {
        "images": [
            {"filename": name, "idiom": "mac", "scale": scale, "size": size}
            for size, scale, _, name in APPICON_ENTRIES
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (ICONSET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")
    return written


def export(variant: str, directory: Path) -> list[Path]:
    directory.mkdir(parents=True, exist_ok=True)
    written = []
    for px in (1024, 512, 256):
        path = directory / f"MediaViewer-icon-{px}.png"
        render(variant, px).save(path, "PNG")
        written.append(path)
    return written


def build_poster(variants: list[str], chosen: str, out_path: Path) -> Path:
    """多尺寸 + 多变体 + 明暗背景的对照图，给人看效果用。"""
    pad = 60
    icon = 256
    label_gap, label_h = 16, 34
    width = 1460
    panel_h = 340
    ladder = [256, 128, 64, 32, 16]
    ladder_dark = [128, 64, 32, 16]

    height = 1000 + 160 + 60
    poster = Image.new("RGBA", (width, height), hexc("F5F5F7") + (255,))
    draw = ImageDraw.Draw(poster)
    title_f, sub_f, label_f = _font(38), _font(20), _font(22)

    draw.text((pad, 52), "MediaViewer 应用图标", font=title_f, fill=hexc("1D1D1F"), anchor="lm")
    draw.text((pad, 100), f"{VARIANTS[chosen]} 已装进 Assets.xcassets/AppIcon.appiconset"
                          " · 由 Tools/IconGen/make_icon.py 生成",
              font=sub_f, fill=hexc("6E6E73"), anchor="lm")

    y = 170
    for i, variant in enumerate(variants):
        x = pad + i * (icon + 70)
        draw.text((x, y - 22), VARIANTS[variant].split(" · ")[0], font=sub_f, fill=hexc("6E6E73"), anchor="lm")
    y += 20
    for i, variant in enumerate(variants):
        x = pad + i * (icon + 70)
        poster.alpha_composite(render(variant, icon), (x, y))
        draw.text((x + icon / 2, y + icon + 6), VARIANTS[variant], font=label_f,
                  fill=hexc("1D1D1F"), anchor="ma")

    y = 560
    draw.text((pad, y - 30), "尺寸阶梯（1:1，浅色 / 深色背景）", font=sub_f, fill=hexc("6E6E73"), anchor="lm")
    light = Image.new("RGBA", (760, panel_h), (255, 255, 255, 255))
    ImageDraw.Draw(light).rounded_rectangle([0, 0, 759, panel_h - 1], radius=28, outline=hexc("E3E3E8"), width=2)
    dark = Image.new("RGBA", (520, panel_h), hexc("1C1C1E") + (255,))

    lx, ly = 40, panel_h - 40
    for px in ladder:
        light.alpha_composite(render(chosen, px), (lx, ly - px))
        lx += px + 40
    dx, dy = 40, panel_h - 40
    for px in ladder_dark:
        dark.alpha_composite(render(chosen, px), (dx, dy - px))
        dx += px + 40
    poster.alpha_composite(light, (pad, y))
    poster.alpha_composite(dark, (pad + 760 + 60, y))

    y = 560 + panel_h + 60
    draw.text((pad, y - 30), "小尺寸放大检查（最近邻）", font=sub_f, fill=hexc("6E6E73"), anchor="lm")
    zoom_x = pad
    for px, factor in ((16, 10), (32, 5), (64, 3)):
        big = render(chosen, px).resize((px * factor, px * factor), Image.Resampling.NEAREST)
        poster.alpha_composite(big, (zoom_x, y))
        draw.text((zoom_x, y + big.height + 12), f"{px} px → {factor}×", font=sub_f,
                  fill=hexc("6E6E73"), anchor="la")
        zoom_x += big.width + 60
    poster.alpha_composite(render(chosen, 256), (width - pad - 256, y))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    poster.convert("RGB").save(out_path, "PNG")
    return out_path


# -------------------------------------------------------------------- CLI --

def main() -> None:
    parser = argparse.ArgumentParser(description="生成 MediaViewer 应用图标")
    parser.add_argument("--variant", default="a", choices=sorted(VARIANTS), help="要安装的变体（默认 a）")
    parser.add_argument("--install", action="store_true", help="写入 AppIcon.appiconset")
    parser.add_argument("--export", metavar="DIR", help="额外导出 1024/512/256 源图到目录")
    parser.add_argument("--no-poster", action="store_true", help="不生成 docs/icon-preview.png")
    parser.add_argument("--poster", metavar="PATH", default=str(PREVIEW), help="预览图输出路径")
    args = parser.parse_args()

    if not args.no_poster:
        path = build_poster(sorted(VARIANTS), args.variant, Path(args.poster))
        print(f"预览图  {path.relative_to(ROOT)}")

    if args.export:
        for path in export(args.variant, Path(args.export)):
            print(f"导出    {path}")

    if args.install:
        written = install(args.variant)
        print(f"图标    {ICONSET.relative_to(ROOT)}/  ({len(written)} 档，变体 {args.variant})")

    if args.no_poster and not args.install and not args.export:
        print("什么都没做：加 --install 安装到 appiconset，或去掉 --no-poster 生成预览图。")


if __name__ == "__main__":
    main()
