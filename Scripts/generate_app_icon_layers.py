#!/usr/bin/env python3
"""Generate the layered tvOS app icon from the approved V2 artwork."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = PROJECT_ROOT / "Design/AppIcon/v2/PhotoEarth-AppIcon-v2-1280x768.png"
DEFAULT_DESIGN_OUTPUT = PROJECT_ROOT / "Design/AppIcon/v2/layers"
BRAND_ASSETS = PROJECT_ROOT / "PhotoEarth/Assets.xcassets/App Icon & Top Shelf Image.brandassets"

# Hand-aligned to the memory lights in the approved 1280 x 768 V2 composition.
MEMORY_LIGHTS = (
    (0.555, 0.327),
    (0.518, 0.378),
    (0.405, 0.438),
    (0.457, 0.438),
    (0.537, 0.452),
    (0.417, 0.508),
    (0.580, 0.504),
    (0.473, 0.546),
    (0.389, 0.646),
    (0.270, 0.688),
    (0.330, 0.691),
    (0.525, 0.638),
    (0.660, 0.738),
    (0.742, 0.684),
)


def smoothstep(value: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0.0, 1.0)
    return value * value * (3.0 - 2.0 * value)


def planet_boundary(width: int, height: int) -> np.ndarray:
    """Approximate the luminous upper limb of the generated planet."""
    x = np.arange(width, dtype=np.float32)
    center_x = width * 0.5
    radius_x = width * 0.742
    center_y = height * 0.974
    radius_y = height * 0.879
    normalized_x = np.clip((x - center_x) / radius_x, -0.999, 0.999)
    return center_y - radius_y * np.sqrt(1.0 - normalized_x * normalized_x)


def remove_embedded_lights(source_rgb: np.ndarray) -> np.ndarray:
    """Replace embedded light cores so the visible lights can live on Front."""
    result = source_rgb.astype(np.float32).copy()
    height, width = result.shape[:2]

    for normalized_x, normalized_y in MEMORY_LIGHTS:
        center_x = int(round(normalized_x * width))
        center_y = int(round(normalized_y * height))
        outer_radius = max(10, int(round(width * 0.012)))
        inner_radius = max(6, int(round(width * 0.007)))

        left = max(0, center_x - outer_radius)
        right = min(width, center_x + outer_radius + 1)
        top = max(0, center_y - outer_radius)
        bottom = min(height, center_y + outer_radius + 1)

        patch = result[top:bottom, left:right]
        yy, xx = np.mgrid[top:bottom, left:right]
        dx = (xx - center_x).astype(np.float32)
        dy = (yy - center_y).astype(np.float32)
        distance = np.sqrt(dx * dx + dy * dy)
        ring = (distance >= inner_radius * 1.05) & (distance <= outer_radius)

        if np.count_nonzero(ring) < 20:
            continue

        normalized_dx = dx / outer_radius
        normalized_dy = dy / outer_radius
        features = np.stack(
            (
                np.ones_like(normalized_dx),
                normalized_dx,
                normalized_dy,
                normalized_dx * normalized_dx,
                normalized_dx * normalized_dy,
                normalized_dy * normalized_dy,
            ),
            axis=-1,
        )
        ring_features = features[ring]
        estimate = np.empty_like(patch)
        for channel in range(3):
            coefficients, *_ = np.linalg.lstsq(
                ring_features,
                patch[..., channel][ring],
                rcond=None,
            )
            estimate[..., channel] = np.sum(features * coefficients, axis=-1)

        estimate = np.clip(estimate, 0.0, 255.0)
        blend = smoothstep((inner_radius - distance) / max(1.0, inner_radius * 0.55))
        blend = blend[..., np.newaxis]
        result[top:bottom, left:right] = patch * (1.0 - blend) + estimate * blend

    return np.clip(result, 0, 255).astype(np.uint8)


def make_back(source: Image.Image) -> Image.Image:
    source_rgb = np.asarray(source.convert("RGB"), dtype=np.float32)
    height, width = source_rgb.shape[:2]
    boundary = planet_boundary(width, height)
    yy, xx = np.mgrid[0:height, 0:width]

    horizontal = 1.0 - np.abs(xx - width * 0.5) / (width * 0.7)
    vertical = yy / height
    blue_lift = np.clip(horizontal, 0.0, 1.0) * np.clip(vertical, 0.0, 1.0)
    base = np.zeros_like(source_rgb)
    base[..., 0] = 1.0 + 1.0 * blue_lift
    base[..., 1] = 4.0 + 3.0 * blue_lift
    base[..., 2] = 11.0 + 10.0 * blue_lift

    # Preserve the sparse stars and subtle source-space texture above the limb.
    keep_source = smoothstep((boundary[np.newaxis, :] - 22.0 - yy) / 18.0)
    keep_source = keep_source[..., np.newaxis]
    back = source_rgb * keep_source + base * (1.0 - keep_source)
    return Image.fromarray(np.clip(back, 0, 255).astype(np.uint8), mode="RGB")


def make_middle(source: Image.Image) -> Image.Image:
    source_rgb = np.asarray(source.convert("RGB"), dtype=np.uint8)
    cleaned_rgb = remove_embedded_lights(source_rgb)
    height, width = cleaned_rgb.shape[:2]
    boundary = planet_boundary(width, height)
    yy = np.arange(height, dtype=np.float32)[:, np.newaxis]

    # Include the cyan atmosphere with a soft edge while removing the space field.
    alpha = smoothstep((yy - (boundary[np.newaxis, :] - 30.0)) / 42.0)
    rgba = np.dstack((cleaned_rgb, np.clip(alpha * 255.0, 0, 255).astype(np.uint8)))
    return Image.fromarray(rgba, mode="RGBA")


def make_front(width: int, height: int) -> Image.Image:
    front = Image.new("RGBA", (width, height), (0, 0, 0, 0))

    for index, (normalized_x, normalized_y) in enumerate(MEMORY_LIGHTS):
        center_x = int(round(normalized_x * width))
        center_y = int(round(normalized_y * height))
        intensity = (0.88, 1.0, 0.94, 0.82)[index % 4]

        halo = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        halo_draw = ImageDraw.Draw(halo)
        halo_radius = max(6, int(round(width * 0.0115)))
        halo_draw.ellipse(
            (
                center_x - halo_radius,
                center_y - halo_radius,
                center_x + halo_radius,
                center_y + halo_radius,
            ),
            fill=(34, 151, 255, int(150 * intensity)),
        )
        halo = halo.filter(ImageFilter.GaussianBlur(radius=max(3.0, width * 0.0065)))
        front = Image.alpha_composite(front, halo)

        glow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        glow_draw = ImageDraw.Draw(glow)
        glow_radius = max(3, int(round(width * 0.0048)))
        glow_draw.ellipse(
            (
                center_x - glow_radius,
                center_y - glow_radius,
                center_x + glow_radius,
                center_y + glow_radius,
            ),
            fill=(126, 222, 255, int(220 * intensity)),
        )
        glow = glow.filter(ImageFilter.GaussianBlur(radius=max(1.0, width * 0.0022)))
        front = Image.alpha_composite(front, glow)

        core = ImageDraw.Draw(front)
        core_radius = max(1, int(round(width * 0.0016)))
        core.ellipse(
            (
                center_x - core_radius,
                center_y - core_radius,
                center_x + core_radius,
                center_y + core_radius,
            ),
            fill=(228, 250, 255, int(245 * intensity)),
        )

    return front


def resize(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    return image.resize(size, Image.Resampling.LANCZOS)


def write_png(image: Image.Image, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, format="PNG", optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--design-output", type=Path, default=DEFAULT_DESIGN_OUTPUT)
    args = parser.parse_args()

    source = Image.open(args.source).convert("RGB")
    if source.size != (1280, 768):
        source = resize(source, (1280, 768)).convert("RGB")

    back = make_back(source)
    middle = make_middle(source)
    front = make_front(*source.size)

    preview = Image.alpha_composite(back.convert("RGBA"), middle)
    preview = Image.alpha_composite(preview, front).convert("RGB")
    write_png(preview, args.design_output / "PhotoEarth-AppIcon-layered-preview-1280x768.png")

    layers = {"Back": back, "Middle": middle, "Front": front}
    for layer_name, layer in layers.items():
        write_png(layer, args.design_output / f"{layer_name}-1280x768.png")
        write_png(resize(layer, (800, 480)), args.design_output / f"{layer_name}-800x480.png")
        write_png(resize(layer, (400, 240)), args.design_output / f"{layer_name}-400x240.png")

        standard_imageset = (
            BRAND_ASSETS
            / "App Icon.imagestack"
            / f"{layer_name}.imagestacklayer"
            / "Content.imageset"
        )
        write_png(resize(layer, (400, 240)), standard_imageset / f"PhotoEarth-{layer_name}.png")
        write_png(resize(layer, (800, 480)), standard_imageset / f"PhotoEarth-{layer_name}@2x.png")

        store_imageset = (
            BRAND_ASSETS
            / "App Icon - App Store.imagestack"
            / f"{layer_name}.imagestacklayer"
            / "Content.imageset"
        )
        write_png(layer, store_imageset / f"PhotoEarth-AppStore-{layer_name}.png")


if __name__ == "__main__":
    main()
