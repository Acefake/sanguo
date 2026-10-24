"""Extract the supplied SAN8R paper and brush ribbons for the map duel card."""
import hashlib
import json
import shutil
from pathlib import Path

from PIL import Image

PROJECT = Path(__file__).resolve().parents[2]
reference = json.loads((PROJECT / "assets/war/inspector/sources.json").read_text(encoding="utf-8"))
source_root = Path(reference[0]["source"]).parents[3] / "UI_按钮边框面板"
source = source_root / "0x35c27e14_8e889a5f_8eb0_005.png"
atlas = Image.open(source).convert("RGBA")
destination = PROJECT / "assets/duel/ui"
sources = json.loads((destination / "sources.json").read_text(encoding="utf-8"))
regions = {
    "paper-banner.png": (0, 518, 888, 623),
    "name-blue.png": (1028, 391, 1752, 504),
    "name-rust.png": (1028, 514, 1752, 624),
}
for name, box in regions.items():
    atlas.crop(box).save(destination / name)
    sources[name] = {
        "source": str(source),
        "rect": list(box),
        "processing": "crop only; preserve original alpha",
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
    }
brush = Path(sources["versus.png"]).parent / "07_base_info__c70598d7_00.png"
shutil.copyfile(brush, destination / "quote-brush.png")
sources["quote-brush.png"] = str(brush)
(destination / "sources.json").write_text(json.dumps(sources, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("Imported SAN8R paper banner and blue/rust brush ribbons")
