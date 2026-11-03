"""Genera iconos de Windows, macOS, iOS y TV desde el ic_launcher de Android."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png"
PHONE = ROOT / "android/app/src/main/res"
master = Image.open(SRC).convert("RGBA")


def resized(size: int) -> Image.Image:
    return master.resize((size, size), Image.Resampling.LANCZOS)


def save_png(path: Path, size: int, rgb: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    im = resized(size)
    if rgb:
        im = im.convert("RGB")
    im.save(path, format="PNG")


def save_ico(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sizes = [16, 24, 32, 48, 64, 128, 256]
    base = resized(256)
    base.save(
        path,
        format="ICO",
        sizes=[(s, s) for s in sizes],
    )


def copy_launchers(dest_res: Path) -> None:
    for src in PHONE.rglob("ic_launcher*.png"):
        rel = src.relative_to(PHONE)
        target = dest_res / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(src.read_bytes())


def font(size: int) -> ImageFont.ImageFont:
    for name in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    ):
        if Path(name).exists():
            return ImageFont.truetype(name, size)
    return ImageFont.load_default()


def banner(path: Path, width: int, height: int) -> None:
    bg = (28, 28, 30, 255)
    im = Image.new("RGBA", (width, height), bg)
    pad = max(8, int(height * 0.1))
    side = int(height * 0.72)
    icon = resized(side)
    y = (height - side) // 2
    im.paste(icon, (pad, y))
    draw = ImageDraw.Draw(im)
    tx = pad + side + pad
    avail = width - tx - pad

    def fit(text: str, ratio: float) -> ImageFont.ImageFont:
        px = max(10, int(height * ratio))
        while px > 8:
            f = font(px)
            if draw.textlength(text, font=f) <= avail:
                return f
            px -= 1
        return font(8)

    title = fit("GatoMix", 0.26)
    sub = fit("Karaoke", 0.2)
    th = draw.textbbox((0, 0), "GatoMix", font=title)[3]
    sh = draw.textbbox((0, 0), "Karaoke", font=sub)[3]
    gap = max(2, int(height * 0.04))
    block = th + gap + sh
    ty = (height - block) // 2
    draw.text((tx, ty), "GatoMix", font=title, fill=(255, 255, 255, 255))
    draw.text((tx, ty + th + gap), "Karaoke", font=sub, fill=(176, 180, 188, 255))
    path.parent.mkdir(parents=True, exist_ok=True)
    im.convert("RGB").save(path, format="PNG")


def macos(folder: Path) -> None:
    for size, name in (
        (16, "app_icon_16.png"),
        (32, "app_icon_32.png"),
        (64, "app_icon_64.png"),
        (128, "app_icon_128.png"),
        (256, "app_icon_256.png"),
        (512, "app_icon_512.png"),
        (1024, "app_icon_1024.png"),
    ):
        save_png(folder / name, size, rgb=True)


def ios(folder: Path) -> None:
    specs = {
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
    for name, size in specs.items():
        save_png(folder / name, size, rgb=True)


def main() -> None:
    save_ico(ROOT / "windows/runner/resources/app_icon.ico")
    save_ico(ROOT / "gatomix_tv/windows/runner/resources/app_icon.ico")
    macos(ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset")
    macos(ROOT / "gatomix_tv/macos/Runner/Assets.xcassets/AppIcon.appiconset")
    ios(ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset")
    ios(ROOT / "gatomix_tv/ios/Runner/Assets.xcassets/AppIcon.appiconset")
    copy_launchers(ROOT / "gatomix_tv/android/app/src/main/res")
    banners = {
        "drawable-mdpi/tv_banner.png": (160, 90),
        "drawable-hdpi/tv_banner.png": (240, 135),
        "drawable-xhdpi/tv_banner.png": (320, 180),
        "drawable-xxhdpi/tv_banner.png": (480, 270),
        "drawable-xxxhdpi/tv_banner.png": (640, 360),
    }
    base = ROOT / "gatomix_tv/android/app/src/main/res"
    for rel, (w, h) in banners.items():
        banner(base / rel, w, h)
    web = ROOT / "gatomix_tv/web"
    save_png(web / "icons/Icon-192.png", 192, rgb=True)
    save_png(web / "icons/Icon-512.png", 512, rgb=True)
    save_png(web / "icons/Icon-maskable-192.png", 192, rgb=True)
    save_png(web / "icons/Icon-maskable-512.png", 512, rgb=True)
    save_png(web / "favicon.png", 32, rgb=True)
    print("ok", master.size)


if __name__ == "__main__":
    main()
