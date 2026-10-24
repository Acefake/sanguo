"""Recover native world maps and all 19 terrain array slices from G1T.

Offsets are relative to the pointer table. Array payload is mip-major:
all 19 base slices precede the 512px mip, not 19 complete mip chains.
The single DDS exported by Noesis contains only slice zero.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import numpy as np
from PIL import Image, ImageFilter


def entries(data):
    table, count = struct.unpack_from('<II', data, 12)
    return [table + value for value in struct.unpack_from('<' + 'I' * count, data, table)]


def bc3(data, offset, size):
    assert data[offset + 1] == 0x5b, 'Expected native BC3 data'
    start = offset + 20
    return Image.frombytes('RGBA', (size, size), data[start:start + size * size],
                           'bcn', (3, 'DXT5'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'assets/rtk14')
    args = parser.parse_args()
    out = args.output / 'terrain'
    out.mkdir(parents=True, exist_ok=True)
    world = (args.source / 'field-textures/239167e0.g1t').read_bytes()
    world_offsets = entries(world)
    assert len(world_offsets) == 5
    height = np.frombuffer(world, '<f4', count=2049 ** 2, offset=world_offsets[0] + 28)
    assert np.array_equal(height, np.fromfile(args.output / 'heightmap.r32', '<f4')), \
        'World material and active height map must belong to the same source variant'
    control_start = world_offsets[1] + 28
    control = Image.frombytes('RGBA', (2049, 2049),
                              world[control_start:control_start + 2049 ** 2 * 4])
    control.save(out / 'source_control.png')
    # Retain the older single-channel inspection image as a diagnostic.
    # Rendering now uses all control channels in the lossless RGBA source PNG.
    control.getchannel('B').save(out / 'source_layer_index.png')
    rock = Image.fromarray((np.asarray(control.getchannel('B')) == 6).astype('uint8') * 255)
    rock.filter(ImageFilter.GaussianBlur(2.0)).save(out / 'rock_grading_mask.png')
    for slot, name in [(2, 'source_albedo'), (3, 'source_normal'), (4, 'source_parameters')]:
        bc3(world, world_offsets[slot], 4096).save(out / f'{name}.png')
    array = (args.source / 'field-textures/57ee6cea.g1t').read_bytes()
    offsets = entries(array)
    assert len(offsets) == 3
    slices = 19
    chain_bytes = sum(max(4, 1024 >> level) ** 2 for level in range(9))
    assert offsets[1] - offsets[0] == 20 + slices * chain_bytes
    for slot, role in enumerate(['albedo', 'normal', 'parameters']):
        assert array[offsets[slot] + 1] == 0x5b
        for layer in range(slices):
            start = offsets[slot] + 20 + layer * 1024 ** 2
            im = Image.frombytes('RGBA', (1024, 1024), array[start:start + 1024 ** 2],
                                 'bcn', (3, 'DXT5'))
            im.save(out / f'layer_{layer:02d}_{role}.png')
        if role in ['albedo', 'normal', 'parameters']:
            # Retain the original BC3 blocks for a small, mipmapped GPU array.
            # Godot expects the 2px and 1px tail too; replicate the final 4px block.
            chains = []
            for layer in range(slices):
                mip_start = offsets[slot] + 20
                chain = bytearray()
                for level in range(9):
                    mip_bytes = (1024 >> level) ** 2
                    start = mip_start + layer * mip_bytes
                    chain.extend(array[start:start + mip_bytes])
                    mip_start += slices * mip_bytes
                chain.extend(chain[-16:] * 2)
                assert len(chain) == chain_bytes + 32
                chains.append(chain)
            (out / f'layers_{role}.bc3').write_bytes(b''.join(chains))
    manifest = {
        'world_source': 'field-textures/239167e0.g1t',
        'world_sha256': hashlib.sha256(world).hexdigest(),
        'world_resolution': [4096, 4096], 'height_variant_verified': True,
        'world_roles': {'2': 'albedo/occlusion', '3': 'normal/height', '4': 'reflectance/linear roughness'},
        'array_source': 'field-textures/57ee6cea.g1t',
        'array_sha256': hashlib.sha256(array).hexdigest(),
        'array_resolution': [1024, 1024], 'array_slices': slices,
        'array_layout': 'mip-major: 19 contiguous slices at each mip size',
        'godot_layer_bytes': chain_bytes + 32,
        'palette_configuration': 'native_materials.json, recovered through original LandscapeComposition references',
        'mapping_status': 'Run recover_rtk14_landscape.py to resolve the complete palette by material hashes',
        'runtime': 'Native full-map maps and three 19-slice arrays, height-based pair blending',
        'unresolved': 'Complete original renderer environment, displacement and runtime flag configuration',
    }
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf8')
    print('SOURCE_TERRAIN_OK 4096x4096 native albedo/normal; 19 native slices x 3 roles')


if __name__ == '__main__':
    main()
