"""Register RRPreview using all 46 source city footprints; keep 3D coordinates."""
from pathlib import Path
import json
import numpy as np
from PIL import Image

root = Path(__file__).resolve().parents[1]
image = Image.open(root / 'assets/rtk14/world_2d.png').convert('RGB')
cities = json.loads((root / 'assets/rtk14/cities_map.json').read_text(encoding='utf8'))
samples, identities = [], []
for city in cities:
    left, top = int(city['x'] * 4 - 150), int(city['z'] * 4 - 150)
    crop = np.asarray(image.crop((left, top, left + 300, top + 300))).astype(np.int16)
    mask = np.max(np.abs(crop - np.array([33, 50, 0])), axis=2) < 4
    ys, xs = np.where(mask)
    if len(xs) < 300:
        raise RuntimeError(f"Missing source city footprint: {city['id']}")
    cells = np.asarray(city['cells'])
    samples.append([(cells % 220).mean(), (cells // 220 + .5 * (cells % 2)).mean(),
                    float(xs.mean() + left), float(ys.mean() + top)])
    identities.append(city['id'])
samples = np.asarray(samples)
sx, ox = np.linalg.lstsq(np.c_[samples[:, 0], np.ones(len(samples))], samples[:, 2], rcond=None)[0]
sy, oy = np.linalg.lstsq(np.c_[samples[:, 1], np.ones(len(samples))], samples[:, 3], rcond=None)[0]
errors = np.hypot(sx * samples[:, 0] + ox - samples[:, 2], sy * samples[:, 1] + oy - samples[:, 3])
assert len(samples) == 46 and errors.max() < 5
report = {'texture_parameters': [float(sx), float(sy), float(ox), float(oy)],
          'parameter_order': ['column_spacing_px', 'row_spacing_px', 'origin_x_px', 'origin_y_px'],
          'source_crop_px': [1488, 512, 6192, 7168], 'matched_cities': len(samples),
          'median_centroid_residual_px': float(np.median(errors)), 'max_centroid_residual_px': float(errors.max()),
          'city_residuals_px': dict(zip(identities, errors.tolist())),
          'basis': 'all 46 original city-cell footprints and RRPreview terrain-16 color centroids',
          'status': 'texture registration estimate; original runtime constants unconfirmed'}
output = json.dumps(report, ensure_ascii=False, indent=2)
(root / 'assets/rtk14/world_2d_registration.json').write_text(output, encoding='utf8')
(root / 'tests/rtk14-hex-texture-registration.json').write_text(output, encoding='utf8')
print('TEXTURE_REGISTRATION_OK cities=46 max_residual_px=', round(float(errors.max()), 3))
