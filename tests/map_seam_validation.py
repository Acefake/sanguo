"""Check assembled alpha masks cover their shared footprint exactly once."""
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
data = json.loads((ROOT / "data/world_map.json").read_text(encoding="utf-8"))
labels = np.load(ROOT / "assets/map/supplied/block-labels.npy")
expected = np.zeros((1080, 1920), np.uint8)
expected[:labels.shape[0], 100:100+labels.shape[1]] = labels
coverage = np.zeros(expected.shape, np.uint8)
assembled = np.zeros(expected.shape, np.uint8)
for index, block in enumerate(data["territory_blocks"]):
    x, y, w, h = map(int, block["rect"])
    alpha = np.array(Image.open(ROOT / block["texture"].removeprefix("res://")))[:, :, 3]
    assert alpha.shape == (h, w), f"Texture scaled independently: {block['id']}"
    footprint = alpha == 255
    assert np.all((alpha == 0) | footprint), f"Soft transparent gutters: {block['id']}"
    coverage[y:y+h, x:x+w] += footprint
    assembled[y:y+h, x:x+w][footprint] = index + 1
assert coverage.max() == 1, "Adjacent blocks overlap"
assert np.array_equal(assembled, expected), "Missing or shifted shared seam pixels"
assert set(np.unique(assembled)) == set(range(52)), "A supplied block was lost"
seams = Image.open(ROOT / data["shared_boundaries"].removeprefix("res://"))
assert seams.size == (1920, 1080), "Shared boundary layer uses a different canvas"
print("拼接检查通过：51块原尺寸纹理，无重叠、无丢失像素、共享边界对齐。")
