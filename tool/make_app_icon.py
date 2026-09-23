"""Render the SocialSave launcher icon at every required size."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "brand"
C1 = (15, 118, 110)  # #0F766E
C2 = (20, 184, 166)  # #14B8A6
WHITE = (255, 255, 255, 255)


def gradient_square(size: int) -> Image.Image:
    img = Image.new("RGB", (size, size))
    px = img.load()
    last = size - 1 or 1
    for y in range(size):
        for x in range(size):
            t = (x * 0.55 + y * 0.45) / last
            t = 0 if t < 0 else 1 if t > 1 else t
            px[x, y] = (
                int(C1[0] + (C2[0] - C1[0]) * t),
                int(C1[1] + (C2[1] - C1[1]) * t),
                int(C1[2] + (C2[2] - C1[2]) * t),
            )
    return img


def draw_glyph(size: int) -> Image.Image:
    """White download arrow + tray, padded for adaptive-icon safe zone."""
    scale = size / 1024
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)

    def n(v: float) -> int:
        return int(round(v * scale))

    # Shaft
    d.rounded_rectangle([n(462), n(188), n(562), n(512)], radius=n(50), fill=255)
    # Arrow head — point sits clear of the shaft
    d.polygon([(n(268), n(448),), (n(756), n(448)), (n(512), n(708))], fill=255)
    # Tray: open-top bucket
    stroke = n(78)
    x0, y0, x1, y1 = n(248), n(742), n(776), n(912)
    d.rounded_rectangle([x0, y0, x1, y1], radius=n(86), fill=255)
    d.rectangle([x0 + stroke, y0 - n(80), x1 - stroke, y1 - stroke], fill=0)

    return mask


def composite_full(size: int) -> Image.Image:
    bg = gradient_square(size).convert("RGBA")
    glyph = draw_glyph(size)
    overlay = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    overlay.putalpha(glyph)
    return Image.alpha_composite(bg, overlay)


def foreground(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glyph = draw_glyph(size)
    overlay = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    overlay.putalpha(glyph)
    return Image.alpha_composite(img, overlay)


def rounded_web(size: int, radius_ratio: float = 0.22) -> Image.Image:
    full = composite_full(size)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1],
        radius=int(size * radius_ratio),
        fill=255,
    )
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(full, (0, 0))
    out.putalpha(mask)
    return out


def save_resized(src: Image.Image, path: Path, size: int, *, rgba: bool = False) -> None:
    img = src.resize((size, size), Image.Resampling.LANCZOS)
    path.parent.mkdir(parents=True, exist_ok=True)
    if rgba:
        img.save(path, "PNG")
    else:
        img.convert("RGB").save(path, "PNG")


def main() -> None:
    source = OUT / "source_icon.png"
    if source.exists():
        print(f"launcher art is {source}; sizes are already exported")
        return
    OUT.mkdir(parents=True, exist_ok=True)
    master = composite_full(1024)
    fg = foreground(1024)
    bg = gradient_square(1024)
    web = rounded_web(1024)
    master.save(OUT / "icon_1024.png", "PNG")
    fg.save(OUT / "icon_foreground_1024.png", "PNG")
    bg.save(OUT / "icon_background_1024.png", "PNG")
    web.save(OUT / "icon_web_1024.png", "PNG")
    save_resized(web, OUT / "icon_512.png", 512, rgba=True)
    save_resized(web, OUT / "icon_192.png", 192, rgba=True)

    android = ROOT / "android" / "app" / "src" / "main" / "res"
    mip = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    fg_sizes = {
        "mipmap-mdpi": 108,
        "mipmap-hdpi": 162,
        "mipmap-xhdpi": 216,
        "mipmap-xxhdpi": 324,
        "mipmap-xxxhdpi": 432,
    }
    for folder, size in mip.items():
        save_resized(master, android / folder / "ic_launcher.png", size)
        save_resized(master, android / folder / "ic_launcher_round.png", size)
    for folder, size in fg_sizes.items():
        save_resized(fg, android / folder / "ic_launcher_foreground.png", size, rgba=True)

    ios = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    ios_sizes = {
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
    for name, size in ios_sizes.items():
        save_resized(master, ios / name, size)

    save_resized(web, ROOT / "web" / "icon-512.png", 512, rgba=True)
    save_resized(web, ROOT / "backend" / "static" / "icon-512.png", 512, rgba=True)

    launch_sizes = {
        "mipmap-mdpi": 160,
        "mipmap-hdpi": 240,
        "mipmap-xhdpi": 320,
        "mipmap-xxhdpi": 480,
        "mipmap-xxxhdpi": 640,
    }
    for folder, size in launch_sizes.items():
        save_resized(master, android / folder / "launch_image.png", size)

    # Splash / launch images on iOS
    launch = ROOT / "ios" / "Runner" / "Assets.xcassets" / "LaunchImage.imageset"
    save_resized(master, launch / "LaunchImage.png", 168)
    save_resized(master, launch / "LaunchImage@2x.png", 336)
    save_resized(master, launch / "LaunchImage@3x.png", 504)

    print("wrote icons")


if __name__ == "__main__":
    main()
