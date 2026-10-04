"""Dump DXBC reflection and assembly from an extracted native G1S.

Uses the Windows Direct3D compiler already installed on the host; no changes
are made to the game or its executable. This is a recovery aid, not a runtime.
"""
from pathlib import Path
import argparse
import ctypes
import hashlib
import json
import struct


def disassemble(data):
    library = ctypes.WinDLL('d3dcompiler_47.dll')
    function = library.D3DDisassemble
    function.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint,
                         ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    function.restype = ctypes.c_long
    blob = ctypes.c_void_p()
    source = ctypes.create_string_buffer(data)
    result = function(source, len(data), 0, None, ctypes.byref(blob))
    if result < 0:
        raise RuntimeError(f'D3DDisassemble failed: {result:#x}')
    table = ctypes.cast(blob, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    pointer = ctypes.WINFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p)(table[3])(blob)
    size = ctypes.WINFUNCTYPE(ctypes.c_size_t, ctypes.c_void_p)(table[4])(blob)
    text = ctypes.string_at(pointer, size).rstrip(b'\0').decode('utf-8')
    ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)(table[2])(blob)
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('file', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    data = args.file.read_bytes()
    index, at = [], 0
    while (at := data.find(b'DXBC', at)) >= 0:
        size = struct.unpack_from('<I', data, at + 24)[0]
        if size < 32 or at + size > len(data):
            at += 4
            continue
        binary = data[at:at + size]
        text = disassemble(binary)
        name = f'{args.file.stem}-{len(index):03d}.asm'
        (args.output / name).write_text(text, encoding='utf-8')
        index.append({'file': name, 'offset': at, 'size': size,
                      'sha256': hashlib.sha256(binary).hexdigest()})
        at += size
    (args.output / (args.file.stem + '-index.json')).write_text(json.dumps(index, indent=2))
    print(f'{args.file.name}: {len(index)} native shader stages disassembled')


if __name__ == '__main__':
    main()
