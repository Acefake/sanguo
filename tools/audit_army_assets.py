"""Inspect existing exported models and render shape candidates without guessing names."""
from pathlib import Path
import argparse
import json
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
DTYPES = {5120: 'i1', 5121: 'u1', 5122: '<i2', 5123: '<u2', 5125: '<u4', 5126: '<f4'}
COMPONENTS = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def read_accessor(document, buffers, index):
    accessor = document['accessors'][index]
    view = document['bufferViews'][accessor['bufferView']]
    dtype = np.dtype(DTYPES[accessor['componentType']])
    width = COMPONENTS[accessor['type']]
    return np.ndarray((accessor['count'], width), dtype=dtype,
                      buffer=buffers[view['buffer']],
                      offset=view.get('byteOffset', 0) + accessor.get('byteOffset', 0),
                      strides=(view.get('byteStride', dtype.itemsize * width), dtype.itemsize))


def model_triangles(path):
    document = json.loads(path.read_text(encoding='utf8'))
    buffers = [(path.parent / entry['uri']).read_bytes() for entry in document['buffers']]
    triangles = []
    for mesh in document['meshes']:
        for primitive in mesh['primitives']:
            if primitive.get('mode', 4) != 4:
                continue
            vertices = read_accessor(document, buffers, primitive['attributes']['POSITION'])
            indices = read_accessor(document, buffers, primitive['indices']).reshape(-1, 3)
            triangles.append(vertices[indices])
    return np.concatenate(triangles)


def render_shape(path, size=(260, 230)):
    return render_triangles(model_triangles(path), size)


def render_triangles(triangles, size=(260, 230)):
    # Oblique orthographic camera. Render original geometry, without invented textures.
    camera_x = np.array([.866, 0., -.5])
    camera_y = np.array([.171, .94, .296])
    camera_z = np.cross(camera_x, camera_y)
    projected = triangles @ np.column_stack([camera_x, camera_y, camera_z])
    bounds = projected[:, :, :2].reshape(-1, 2)
    lo, hi = bounds.min(0), bounds.max(0)
    scale = min((size[0] - 32) / max(hi[0] - lo[0], 1e-4), (size[1] - 24) / max(hi[1] - lo[1], 1e-4))
    points = (projected[:, :, :2] - (lo + hi) / 2) * scale
    points[:, :, 0] += size[0] / 2
    points[:, :, 1] = size[1] / 2 - points[:, :, 1]
    normals = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    normals /= np.maximum(np.linalg.norm(normals, axis=1)[:, None], 1e-7)
    shade = .4 + .6 * np.abs(normals @ np.array([.3, .8, .52]))
    image = Image.new('RGB', size, '#20292d')
    draw = ImageDraw.Draw(image)
    for index in np.argsort(projected[:, :, 2].mean(1)):
        color = tuple(int(component * shade[index]) for component in (174, 196, 203))
        draw.polygon([tuple(point) for point in points[index]], fill=color)
    return image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True, type=Path, help='Existing 3D资源 folder containing 转换记录.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/validation/army-assets')
    parser.add_argument('--preview', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    for record in json.loads((args.source / '转换记录.json').read_text(encoding='utf8')):
        if 'gltf' not in record:
            continue
        path = args.source / record['gltf']
        document = json.loads(path.read_text(encoding='utf8'))
        accessors = [document['accessors'][primitive['attributes']['POSITION']]
                     for mesh in document['meshes'] for primitive in mesh['primitives']]
        if not all('min' in accessor and 'max' in accessor for accessor in accessors):
            continue
        lo = np.array([accessor['min'] for accessor in accessors]).min(0)
        hi = np.array([accessor['max'] for accessor in accessors]).max(0)
        extent = hi - lo
        row = {**record, 'hash': path.stem.split('_')[0], 'package': path.parent.name,
               'bounds_min': lo.tolist(), 'bounds_max': hi.tolist(), 'extent': extent.round(3).tolist(),
               'max_joints': max([len(skin['joints']) for skin in document.get('skins', [])] + [0]),
               'animations': len(document.get('animations', [])), 'classification': 'unverified'}
        rows.append(row)
    # Size only selects candidates for visual inspection; it is not a semantic classification.
    candidates = [row for row in rows if 80 < row['extent'][1] < 360 and 20 < row['extent'][0] < 400
                  and 15 < row['extent'][2] < 400 and 120 <= row['vertices'] < 15000]
    candidates.sort(key=lambda row: (row['package'], abs(row['extent'][1] - 180)))
    (args.output / 'model-audit.json').write_text(json.dumps({'models': rows, 'candidates': candidates}, ensure_ascii=False, indent=2), encoding='utf8')
    print('AUDIT', len(rows), 'models;', len(candidates), 'shape candidates', flush=True)
    print('PACKAGES', json.dumps({package: sum(row['package'] == package for row in candidates) for package in sorted({r['package'] for r in candidates})}), flush=True)
    if args.preview:
        font = ImageFont.truetype('C:/Windows/Fonts/simkai.ttf', 18)
        for start in range(0, len(candidates), 30):
            page = Image.new('RGB', (1560, 1350), '#101a1f')
            draw = ImageDraw.Draw(page)
            for index, row in enumerate(candidates[start:start + 30]):
                x, y = index % 6 * 260, index // 6 * 270
                page.paste(render_shape(args.source / row['gltf']), (x, y))
                draw.text((x + 8, y + 232), f"{start + index:03d} {row['package']}/{row['hash']}", font=font, fill='#e0ece8')
                draw.text((x + 8, y + 252), f"{row['vertices']} 顶点 | {row['max_joints']} 骨骼", font=font, fill='#a1b8af')
            target = args.output / f'candidates-{start // 30 + 1:02d}.jpg'
            page.save(target, quality=92)
            print('PREVIEW', target.name, flush=True)


if __name__ == '__main__':
    main()
