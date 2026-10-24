"""Import the supplied map sheets without resampling their artwork.

Run with the directory containing the ten original clipboard PNGs.
The visible map occupies the upper-left 1920 x 1080 of its 2048 sheet.
"""
import argparse
import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SHEETS = {
    "packing": "a950faa2-f121-451a-aca1-2d5fdea50cae",
    "overview": "fadb8535-6d86-4129-a75b-d773d3732873",
    "boundaries": "9c00516e-11bf-4e95-bfe6-69e4b0331ad7",
    "region-fill-a": "3e182681-b3ed-4c1d-9ba3-a34ea8d5b127",
    "region-fill-b": "97a50386-e57f-471c-a5bd-5b663c86c377",
    "region-edge-a": "0b0e310e-2af8-43b7-9b01-3dc6d02defe2",
    "region-edge-b": "14498d53-3633-4a60-b219-ef03bc816b2d",
    "base": "728a9456-a46f-4c5d-82ee-6aaf1d0a81ed",
    "terrain": "ea344590-1964-4f1e-9e70-da63ac66d31b",
    "composite": "cadede1a-a69a-4e4a-be9c-741cd2b94d5c",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    target = ROOT / "assets/map/supplied"
    target.mkdir(parents=True, exist_ok=True)
    for name, ident in SHEETS.items():
        shutil.copyfile(args.source / f"codex-clipboard-{ident}.png", target / f"{name}.png")
    for name in ("terrain", "base"):
        Image.open(target / f"{name}.png").crop((0, 0, 1920, 1080)).save(target / f"world-{name}.png")
    # The boundary sheet is a black-backed line layer, not a black map backdrop.
    pixels = np.asarray(Image.open(target / "boundaries.png").convert("RGB"))[:1080, :1920]
    rgba = np.zeros((1080, 1920, 4), dtype=np.uint8)
    rgba[:, :, :3] = (87, 64, 42)
    rgba[:, :, 3] = np.clip(pixels.max(axis=2).astype(float) * 5, 0, 210).astype(np.uint8)
    Image.fromarray(rgba).save(target / "world-boundaries.png")
    walls = Image.fromarray((pixels.max(axis=2) > 12).astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(5))
    ImageDraw.floodfill(walls, (0, 0), 128)
    land = np.asarray(walls) != 128
    land_image = Image.new("RGBA", (1920, 1080), (255, 255, 255, 0))
    land_image.putalpha(Image.fromarray((land * 255).astype(np.uint8)))
    land_image.save(target / "world-land-mask.png")
    # Keep a stable baseline so repeat imports never accumulate coordinate offsets.
    baseline = target / "layout-baseline.json"
    if not baseline.exists():
        shutil.copyfile(ROOT / "data/world_map.json", baseline)
    data = json.loads(baseline.read_text(encoding="utf-8"))
    def project(point):
        x, y = point
        offset = float(np.interp(y, [72, 170, 400, 650, 850, 1030], [0, 300, 50, -180, -120, -80]))
        return [round(x + offset * (1800 - x) / 1640), round((y - 25) * 1.02)]
    region_masks = {}
    for region in data["regions"]:
        region["polygon"] = [project(p) for p in region["polygon"]]
        region["label"] = project(region["label"])
        mask = Image.new("L", (1920, 1080))
        ImageDraw.Draw(mask).polygon([tuple(p) for p in region["polygon"]], fill=255)
        inland = Image.fromarray((((np.asarray(mask) > 0) & land) * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(21))
        region_masks[region["id"]] = np.argwhere(np.asarray(inland) > 0)
    for place in data["places"]:
        x, y = project([place["x"], place["y"]])
        candidates = region_masks[place["region_id"]]
        # Snap displaced coastal points inland, with space for the city marker.
        if len(candidates) == 0:
            raise ValueError(f"No land in region {place['region_id']}")
        distances = (candidates[:, 1] - x) ** 2 + (candidates[:, 0] - y) ** 2
        py, px = candidates[int(distances.argmin())]
        place["x"], place["y"] = int(px), int(py)
    positions = {p["id"]: [p["x"], p["y"]] for p in data["places"]}
    for route in data["routes"]:
        a, b = positions[route["from"]], positions[route["to"]]
        route["points"] = [a, project(route["points"][1]), b]
    data["land_mask"] = "res://assets/map/supplied/world-land-mask.png"
    data["background"] = "res://assets/map/supplied/world-terrain.png"
    (ROOT / "data/world_map.json").write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    manifest = {"image_size": [1920, 1080], "crop": [0, 0, 1920, 1080],
                "source_sheets": SHEETS,
                "note": "图集未标注州名或城市编号，不能按图集排列顺序推定归属。城市和州的语义沿用 world_map.json。"}
    (target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
