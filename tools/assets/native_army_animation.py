"""Decode native RTK14 G2A splines (the extracted library names them .g1a).

Format references: Joschuka/Project-G1M and Joschuka/fmt_g1m.
No skeleton retargeting or invented motion is applied here.
"""
from pathlib import Path
import math
import struct
import numpy as np


def signed32(value):
    return struct.unpack('<i', struct.pack('<I', value & 0xffffffff))[0]


def spline(rows, ratio):
    result = np.zeros(3)
    # The packed polynomial stores constant, linear, quadratic, cubic rows.
    for row, power in zip(rows, (0, 1, 2, 3)):
        factor = struct.unpack('<f', struct.pack('<I', ((row >> 37) & 0x7800000) + 0x32000000))[0]
        values = [signed32((row >> 28) & 0xfffff000), signed32((row >> 8) & 0xfffff000), signed32(row << 12)]
        result += np.asarray(values) * factor * ratio ** power
    return result


def axis_angle(vector):
    angle = np.linalg.norm(vector)
    if angle < 1e-9:
        return np.eye(3)
    x, y, z = vector / angle
    skew = np.array([[0, -z, y], [z, 0, -x], [-y, x, 0]])
    return np.eye(3) + math.sin(angle) * skew + (1 - math.cos(angle)) * (skew @ skew)


class Clip:
    def __init__(self, path):
        data = Path(path).read_bytes()
        assert data[:4] == b'_A2G', 'Expected native G2A'
        version = data[4:8]
        self.fps, packed, timing_size = struct.unpack_from('<fII', data, 12)
        self.frames = packed & 0x3ffff
        info_size = packed >> 18
        checkpoint = 32 if version == b'0500' else 28
        self.tracks = {}
        last, overflow = 0, 0
        for index in range(info_size // 4):
            info, = struct.unpack_from('<I', data, checkpoint + index * 4)
            channels = info & 15
            bits = 8 if version == b'0500' else 10
            bone = (info >> 4) & ((1 << bits) - 1)
            if bone < last: overflow += 1
            last = bone
            bone += overflow * (1 << bits)
            offset = (checkpoint + info_size + (info >> (4 + bits))) // 4 * 4
            tracks = {}
            for _ in range(channels):
                opcode, count, first = struct.unpack_from('<HHi', data, offset)
                offset += 8
                times = np.asarray(struct.unpack_from('<' + 'H' * count, data, offset), float)
                offset = (offset + count * 2 + 3) // 4 * 4
                coefficients = [struct.unpack_from('<4Q', data, checkpoint + info_size + timing_size + (first + i) * 32) for i in range(count)]
                assert opcode in (0, 1, 2) and count > 0
                tracks[opcode] = (times, coefficients)
            self.tracks[bone] = tracks
        self.duration = (self.frames - 1) / self.fps

    def local(self, bone, time, rest):
        matrix = rest.copy()
        tracks = self.tracks.get(bone, {})
        for opcode, (times, coefficients) in tracks.items():
            frame = max(0, min(time * self.fps, times[-1]))
            index = min(max(int(np.searchsorted(times, frame, side='right')) - 1, 0), len(times) - 1)
            ratio = (frame - times[index]) / max(times[index + 1] - times[index], 1) if index + 1 < len(times) else 0
            value = spline(coefficients[index], ratio)
            if opcode == 0: matrix[:3, :3] = axis_angle(value)
            elif opcode == 1: matrix[:3, 3] = value
            elif opcode == 2: matrix[:3, :3] = matrix[:3, :3] @ np.diag(value)
        return matrix


def read_smd(path):
    text = Path(path).read_text()
    bones = [row.split() for row in text.split('nodes\n')[1].split('end')[0].splitlines() if row.strip()]
    parents = {int(row[0]): int(row[-1]) for row in bones}
    local, bind = {}, {}
    for row in text.split('skeleton\n')[1].split('end')[0].splitlines():
        fields = row.split()
        if not fields or fields[0] == 'time': continue
        bone = int(fields[0]); x, y, z, rx, ry, rz = map(float, fields[1:])
        matrix = np.eye(4)
        matrix[:3, 3] = [x, y, z]
        matrix[:3, :3] = axis_angle(np.array([0, 0, rz])) @ axis_angle(np.array([0, ry, 0])) @ axis_angle(np.array([rx, 0, 0]))
        local[bone] = matrix
        bind[bone] = bind[parents[bone]] @ matrix if parents[bone] >= 0 else matrix
    vertices, normals, uv, weights = [], [], [], []
    for row in text.split('triangles\n')[1].split('end')[0].splitlines():
        fields = row.split()
        if len(fields) < 10: continue
        vertices.append(list(map(float, fields[1:4])))
        normals.append(list(map(float, fields[4:7])))
        uv.append(list(map(float, fields[7:9])))
        weights.append([(int(fields[10 + i*2]), float(fields[11 + i*2])) for i in range(int(fields[9]))])
    return parents, local, bind, np.asarray(vertices), np.asarray(normals), np.asarray(uv), weights


def posed(rig, clip, time):
    parents, local, bind, vertices, normals, uv, weights = rig
    global_pose = {}
    for bone in local:
        matrix = clip.local(bone, time, local[bone])
        global_pose[bone] = global_pose[parents[bone]] @ matrix if parents[bone] >= 0 else matrix
    moved, directions = skin(rig, global_pose)
    return moved, directions, global_pose


def skin(rig, global_pose):
    parents, local, bind, vertices, normals, uv, weights = rig
    transforms = np.asarray([global_pose[bone] @ np.linalg.inv(bind[bone]) for bone in local])
    width = max(len(row) for row in weights)
    joints = np.zeros((len(vertices), width), int)
    values = np.zeros((len(vertices), width))
    for i, row in enumerate(weights):
        for j, (bone, weight) in enumerate(row): joints[i, j], values[i, j] = bone, weight
    matrices = np.einsum('vwij,vw->vij', transforms[joints], values)
    moved = np.einsum('vij,vj->vi', matrices, np.column_stack([vertices, np.ones(len(vertices))]))[:, :3] * .01
    directions = np.einsum('vij,vj->vi', matrices[:, :3, :3], normals)
    directions /= np.maximum(np.linalg.norm(directions, axis=1)[:, None], 1e-9)
    return moved, directions
