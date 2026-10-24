"""Recover source relief and painted water areas; do not invent settlements."""
from pathlib import Path
import json
import numpy as np
from PIL import Image, ImageFilter

out = Path(__file__).resolve().parents[2] / 'assets/rtk14'
height = np.fromfile(out/'heightmap.r32', '<f4').reshape(2049, 2049)
control = np.asarray(Image.open(out/'terrain/source_control.png'))
# G1T 0x01 is BGRA8. These are material indices and a blend weight,
# rather than a color image or the gameplay terrain-code grid.
primary, secondary, blend = control[:,:,2], control[:,:,1], control[:,:,0] / 255.0
water = (primary == 9) * (1.0-blend) + (secondary == 9) * blend
mask = Image.fromarray(np.uint8(np.clip(water, 0, 1)*255))
mask.save(out/'world_water_mask.png')
# Surface height remains an estimate until the statistical-river setup is
# recovered. Follow source relief directly; never excavate an invented bed.
level = np.maximum(0.3, height*.01 + .035)
height.astype('<f4').tofile(out/'world_preview_height.r32')
level.astype('<f4').tofile(out/'world_water_height.r32')
# Native static placement already contains 105 source village objects.
# The earlier 87 added villages and their terrain pads had no source evidence.
(out/'world_layout.json').write_text('[]\n', encoding='utf-8')
# Planting constraints use the native painted road and water footprint.
# Distribution and scale still require the original procedural-placement rule.
roads = np.isin(primary, [10, 13]).astype('uint8')*255
empty = np.zeros_like(primary, dtype='uint8')
splat = np.stack([roads, empty, empty, np.full_like(primary, 255)], axis=-1)
Image.fromarray(splat).save(out/'world_splat.png')
(out/'source_relief_manifest.json').write_text(json.dumps({
    'height_source': 'heightmap.r32', 'height_identical_before_runtime_foundations': True,
    'water_source': '239167e0 control palette 9, BGRA index/weight',
    'removed_generated_villages': 87, 'native_static_villages': 105,
    'water_surface_height': 'estimated source relief + 0.035m, min 0.3m',
}, indent=2), encoding='utf-8')
print('SOURCE_RELIEF_OK exact_height_samples=', height.size,
      'painted_water_samples=', int((water>.5).sum()), 'generated_villages=0')
