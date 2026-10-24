"""Preserve native half4 tangent frames omitted by the intermediate OBJ format.

Native PB2 uses normal.x * cross(T,N) * T.w + normal.y * T + normal.z * N.
The mountain shader consumes these source frames with that exact ordering.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import numpy as np


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    assets = Path(__file__).resolve().parents[1] / 'assets/rtk14'
    report = []
    for model in ['14d3de0c', '4b17a777', '5b5c506d', 'beaceb35', '84e24956', 'ce4b6bab']:
        source = (args.source / 'samples' / f'{model}.g1m').read_bytes()
        base = source.index(b'GM1G')
        at, sections = base + 48, {}
        for _ in range(struct.unpack_from('<I', source, base + 44)[0]):
            kind, size = struct.unpack_from('<II', source, at)
            sections[kind] = at
            at += size
        at = sections[0x10004]
        assert struct.unpack_from('<I', source, at + 8)[0] == 1
        _, stride, count, _ = struct.unpack_from('<4I', source, at + 12)
        assert stride == 32
        descriptors = source[sections[0x10005] + 24:sections[0x10005] + 56]
        expected = [(0, 0, 2, 0), (0, 12, 11, 3), (0, 20, 10, 5), (0, 24, 11, 6)]
        assert [struct.unpack_from('<4H', descriptors, i * 8) for i in range(4)] == expected
        start = at + 28
        positions = np.array([struct.unpack_from('<3f', source, start + i * stride) for i in range(count)])
        uvs = np.array([struct.unpack_from('<2e', source, start + i * stride + 20) for i in range(count)])
        tangents = np.array([struct.unpack_from('<4e', source, start + i * stride + 24) for i in range(count)])
        path = assets / 'models' / f'{model}.glb'
        data = path.read_bytes()
        json_length = struct.unpack_from('<I', data, 12)[0]
        doc = json.loads(data[20:20 + json_length])
        binary = bytearray(data[28 + json_length:])

        def attribute(index, width):
            accessor = doc['accessors'][index]
            view = doc['bufferViews'][accessor['bufferView']]
            offset = view.get('byteOffset', 0) + accessor.get('byteOffset', 0)
            return np.frombuffer(binary, '<f4', count=accessor['count'] * width, offset=offset).reshape(-1, width).copy()

        primitive = doc['meshes'][0]['primitives'][0]
        converted = attribute(primitive['attributes']['POSITION'], 3).astype(float) * 100
        converted_uv = attribute(primitive['attributes']['TEXCOORD_0'], 2).astype(float)
        distance = ((converted[:, None, :] - positions[None, :, :]) ** 2).sum(2)
        distance += ((converted_uv[:, None, :] - uvs[None, :, :]) ** 2).sum(2) * 1e6
        order = distance.argmin(1)
        error = float(np.abs(converted - positions[order]).max())
        assert error < .002 and np.abs(converted_uv - uvs[order]).max() < 1e-5
        native_tangents = tangents[order].astype('<f4')
        # Half-float quantization is retained, then normalized by the shader.
        assert np.abs(np.linalg.norm(native_tangents[:, :3], axis=1) - 1).max() < .002
        assert np.isin(native_tangents[:, 3], [-1, 1]).all()
        def store_attribute(name, values):
            existing = primitive['attributes'].get(name)
            if existing is not None:
                view = doc['bufferViews'][doc['accessors'][existing]['bufferView']]
                assert view['byteLength'] == values.nbytes
                offset = view['byteOffset']
                binary[offset:offset + values.nbytes] = values.tobytes()
                return
            while len(binary) % 4: binary.append(0)
            offset = len(binary)
            binary.extend(values.tobytes())
            doc['bufferViews'].append({'buffer': 0, 'byteOffset': offset,
                                      'byteLength': values.nbytes, 'target': 34962})
            doc['accessors'].append({'bufferView': len(doc['bufferViews']) - 1, 'componentType': 5126,
                                     'count': len(values), 'type': 'VEC4'})
            for part in doc['meshes'][0]['primitives']:
                part['attributes'][name] = len(doc['accessors']) - 1

        store_attribute('TANGENT', native_tangents)
        # Carry source handedness explicitly instead of assuming the engine's
        # regenerated/packed binormal has the native PB2 convention.
        colors = np.ones_like(native_tangents)
        colors[:, 3] = (native_tangents[:, 3] + 1) * .5
        store_attribute('COLOR_0', colors)
        doc['buffers'][0]['byteLength'] = len(binary)
        encoded = json.dumps(doc, separators=(',', ':')).encode()
        encoded += b' ' * (-len(encoded) % 4)
        binary += b'\0' * (-len(binary) % 4)
        size = 28 + len(encoded) + len(binary)
        path.write_bytes(struct.pack('<III', 1179937895, 2, size)
                         + struct.pack('<II', len(encoded), 1313821514) + encoded
                         + struct.pack('<II', len(binary), 5130562) + binary)
        report.append({'model': model, 'vertices': count, 'source_vertex_match_max_cm': error,
                       'handedness_storage': 'COLOR_0.a * 2 - 1',
                       'source_sha256': hashlib.sha256(source).hexdigest(),
                       'native_tangent_sha256': hashlib.sha256(native_tangents.tobytes()).hexdigest()})
    (assets / 'native-recovery/mountain-tangents.json').write_text(json.dumps(report, indent=2), encoding='utf8')
    print('NATIVE_MOUNTAIN_TANGENTS_OK', len(report), 'source vertex buffers')


if __name__ == '__main__':
    main()
