"""从生成的原图切出应用图标全套尺寸。

背景交代：原图是 AI 生成的 1024×1024 图标，右下角带了一块半透明水印
（「AI生成 WORKBUDDY」）。图标不能带水印，所以这里不是「压缩原图」，
而是**重新合成**：

  1. 用亮度阈值把白色剪影抠成遮罩（剪影实测 ~252，水印最亮 ~230，阈值 235）
  2. 限定 y < 880，把水印所在的底部整块排除在遮罩之外
  3. 在一张干净的纯色底上重新贴回剪影，并按尺寸精确控制留白

这样做还有个额外好处：**留白比例可控**。Android 的自适应图标会被系统
按不同形状裁切（圆形、方形、水滴…），前景内容必须落在中央约 66% 的
安全区内，否则圆角裁切会把耳朵和尾巴切掉。直接缩放原始 PNG 是控不住这一点的。

用法（依赖 pillow，装在托管 venv 里）：
    <venv>/bin/python tool/make_icons.py
"""
from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw, ImageFont

# ---------------------------------------------------------------- 配置

BRAND = (118, 78, 207)  # 从原图采样得到的主色，与 AppColors.primary(#7657E8) 同一族
WHITE = (255, 255, 255)

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)                      # app/
RES = os.path.join(APP, "android", "app", "src", "main", "res")
STORE = os.path.join(os.path.dirname(APP), "docs", "store")
IOS_APPICON = os.path.join(APP, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")

# 原图随仓库一起放着（android/icon/），这样换台机器也能重跑。
# 也可以从命令行传一个路径覆盖它。
SRC = (
    sys.argv[1]
    if len(sys.argv) > 1
    else os.path.join(APP, "android", "icon", "icon-source.png")
)

# 各密度：密度名 → 倍数
DENSITIES = {
    "mdpi": 1,
    "hdpi": 1.5,
    "xhdpi": 2,
    "xxhdpi": 3,
    "xxxhdpi": 4,
}

# 内容占画布的比例。
# - legacy 图标：0.70（系统不裁切，留一点呼吸感即可）
# - 自适应前景：0.58（必须落在中央 66% 安全区内，留足余量给圆形裁切）
# - iOS：0.62。iOS 自己套圆角遮罩（1024 下半径约 229px），所以不能用 0.70 ——
#   那个留白是按「Android 不裁切」定的，iOS 上耳朵和尾巴会贴着圆角边缘。
LEGACY_RATIO = 0.70
ADAPTIVE_RATIO = 0.58
IOS_RATIO = 0.62

# iOS 的 19 个图标尺寸：文件名 → 边长。
# 文件名必须与 flutter create 写进 Contents.json 的那套完全一致 —— 是**替换**
# 已有文件，不是新增；名字对不上 actool 会当成缺图，编译期报 warning 并打出
# 一块空白图标（长得像成功，装到桌面上才发现）。
IOS_SIZES = {
    "Icon-App-20x20@1x.png": 20,
    "Icon-App-20x20@2x.png": 40,
    "Icon-App-20x20@3x.png": 60,
    "Icon-App-29x29@1x.png": 29,
    "Icon-App-29x29@2x.png": 58,
    "Icon-App-29x29@3x.png": 87,
    "Icon-App-40x40@1x.png": 40,
    "Icon-App-40x40@2x.png": 80,
    "Icon-App-40x40@3x.png": 120,
    "Icon-App-60x60@2x.png": 120,
    "Icon-App-60x60@3x.png": 180,
    "Icon-App-76x76@1x.png": 76,
    "Icon-App-76x76@2x.png": 152,
    "Icon-App-83.5x83.5@2x.png": 167,
    "Icon-App-1024x1024@1x.png": 1024,
}

# 原图里水印所在的高度，超过它的一律不参与抠图
WATERMARK_Y = 880


def load_silhouette(src: str) -> Image.Image:
    """从原图抠出白色剪影遮罩（已裁到包围盒）。"""
    im = Image.open(src).convert("RGB")
    w, h = im.size
    px = im.load()

    mask = Image.new("L", (w, h), 0)
    mp = mask.load()
    for y in range(0, min(WATERMARK_Y, h)):
        for x in range(w):
            r, g, b = px[x, y]
            if min(r, g, b) > 235:
                mp[x, y] = 255

    bbox = mask.getbbox()
    if bbox is None:
        raise SystemExit("没抠到任何剪影，阈值可能不对")
    return mask.crop(bbox)


def compose(
    silhouette: Image.Image,
    size: int,
    ratio: float,
    *,
    background: tuple[int, int, int] | None,
) -> Image.Image:
    """把剪影按 [ratio] 的内容占比居中贴到 size×size 画布上。"""
    canvas = Image.new(
        "RGBA",
        (size, size),
        (*(background or (0, 0, 0)), 255 if background else 0),
    )

    box = size * ratio
    sw, sh = silhouette.size
    scale = min(box / sw, box / sh)
    tw, th = max(1, round(sw * scale)), max(1, round(sh * scale))

    # LANCZOS：缩到 48px 时边缘容易发毛，用高质量重采样保住轮廓。
    small = silhouette.resize((tw, th), Image.LANCZOS)
    white = Image.new("RGBA", (tw, th), (*WHITE, 255))
    canvas.paste(white, ((size - tw) // 2, (size - th) // 2), small)
    return canvas


def write(path: str, img: Image.Image) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG", optimize=True)
    print(f"  {os.path.relpath(path, APP)}  {img.size[0]}x{img.size[1]}")


def make_ios_icons(silhouette: Image.Image) -> None:
    """生成 iOS 的 15 个 AppIcon 尺寸。

    两个 iOS 特有的硬要求：

    1. **绝不能带 alpha 通道。** `.convert("RGB")` 不够 —— 「alpha 恰好全 255」
       仍然算带透明通道，App Store Connect 会拒。所以这里显式丢掉 alpha 那一路。
    2. **图要满幅方形，不要自己裁圆角。** iOS 会自己套圆角遮罩；自己留透明角
       的话，那些角在 iOS 上会被填成黑色或露出底色。
    """
    print("生成 iOS AppIcon：")
    for filename, size in IOS_SIZES.items():
        write(
            os.path.join(IOS_APPICON, filename),
            compose(silhouette, size, IOS_RATIO, background=BRAND).convert("RGB"),
        )


def render_text(draw: ImageDraw.ImageDraw, xy, text, font, fill):
    draw.text(xy, text, font=font, fill=fill)


# 中文字体候选：Windows 用微软雅黑，macOS 用苹方。
# 宣传图是中文文案，两边都得能出图，否则在 Mac 上重跑会退化成默认位图字体。
_FONT_CANDIDATES = {
    True: [
        r"C:\Windows\Fonts\msyhbd.ttc",
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
    ],
    False: [
        r"C:\Windows\Fonts\msyh.ttc",
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/STHeiti Light.ttc",
    ],
}


def _load_font(size: int, *, bold: bool) -> ImageFont.FreeTypeFont:
    for path in _FONT_CANDIDATES[bold]:
        if not os.path.exists(path):
            continue
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main() -> int:
    if not os.path.exists(SRC):
        print(f"找不到原图：{SRC}", file=sys.stderr)
        return 1

    print("抠剪影…")
    silhouette = load_silhouette(SRC)
    print(f"  剪影 {silhouette.size[0]}x{silhouette.size[1]}")

    print("生成桌面图标（legacy）：")
    for name, mult in DENSITIES.items():
        size = round(48 * mult)
        write(
            os.path.join(RES, f"mipmap-{name}", "ic_launcher.png"),
            compose(silhouette, size, LEGACY_RATIO, background=BRAND).convert("RGB"),
        )

    print("生成自适应图标前景（透明底）：")
    for name, mult in DENSITIES.items():
        size = round(108 * mult)
        write(
            os.path.join(RES, f"mipmap-{name}", "ic_launcher_foreground.png"),
            compose(silhouette, size, ADAPTIVE_RATIO, background=None),
        )

    print("商店与宣传图：")
    write(
        os.path.join(STORE, "icon-512.png"),
        compose(silhouette, 512, LEGACY_RATIO, background=BRAND).convert("RGB"),
    )

    make_ios_icons(silhouette)

    # Play 商店的置顶宣传图 1024×500。中文用微软雅黑；macOS 上没有这个字体，
    # 退回 PingFang（宣传图是中文区的产物，在 Mac 上重跑也要能出图）。
    fg = Image.new("RGB", (1024, 500), BRAND)
    d = ImageDraw.Draw(fg)
    icon = compose(silhouette, 300, LEGACY_RATIO, background=None)
    fg.paste(icon, (96, 100), icon)
    f_big = _load_font(68, bold=True)
    f_small = _load_font(30, bold=False)
    render_text(d, (450, 180), "我的宠物", f_big, WHITE)
    render_text(d, (452, 268), "疫苗 · 驱虫 · 体重 · 就医，一处记全", f_small, (222, 214, 250))
    write(os.path.join(STORE, "feature-graphic-1024x500.png"), fg)

    print("\n完成。注意：adaptive 的 XML 与背景色资源是手写的，见 res/mipmap-anydpi-v26/ 与 res/values/。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
