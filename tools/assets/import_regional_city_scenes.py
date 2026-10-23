"""Stage the five city layouts with original geometry, placement and color bindings."""
from pathlib import Path
import json
import struct
import shutil
import sys
import argparse

# City assignments can be rebuilt offline without staging 3D source assets.
if __name__ == "__main__" and "--catalog-only" in sys.argv:
    from build_city_scene_catalog import build_catalog
    build_catalog()
    raise SystemExit(0)

import zlib
import lz4.block
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
scope = {"__file__": str(ROOT / "tools/assets/import_luoyang_scene.py")}
exec((ROOT / "tools/assets/import_luoyang_scene.py").read_text(encoding="utf-8").split("season_spec=")[0], scope)
SOURCE, PRIOR = scope["SOURCE"], scope["PRIOR"]
parse, hx = scope["parse"], scope["hx"]
sys.path.insert(0, str(PRIOR))
from g1t_decode import textures as decode_textures
sys.path.insert(0, str(PRIOR / "tools/gust_stuff"))
from g1m_export_meshes import parseG1MG

RAW = PRIOR / "3D资源/原始资源"
RAW_MODELS = {p.name.split("_")[0]: p for p in RAW.glob("*/*.g1m")}
RAW_BINDINGS = {p.name.split("_")[0]: p for p in RAW.glob("*/*.bin")}
INVENTORY = {r["hash"]: r for r in json.loads((PRIOR / "inventory.json").read_text(encoding="utf-8"))}
for extra in PRIOR.glob("0x*_inventory.json"):
    INVENTORY.update({r["hash"]: r for r in json.loads(extra.read_text(encoding="utf-8"))})
PROFILES = [(101, "北方", "north"), (102, "中原", "central"), (103, "江南", "south"), (104, "西蜀", "shu"), (105, "南蛮", "nanman")]

def recover_inventory(texture):
    audit = json.loads((PRIOR / "rdb_inventory_audit.json").read_text(encoding="utf-8"))
    reference = next(r for r in audit if r["hash"] == texture)
    location = bytes.fromhex(reference["location"])
    assert len(location) == 13
    base = SOURCE.parent / "SAN8R v1.0.8/0002"
    index = (base / "root.rdx").read_bytes()
    packages = {struct.unpack_from("<H", index, i)[0]: struct.unpack_from("<I", index, i + 4)[0] for i in range(0, len(index), 8)}
    package = base / (f"0x{packages[int.from_bytes(location[-3:-1], 'little')]:08x}.fdata")
    if not package.exists():
        package = ROOT / "tools/city-source-cache/SAN8R v1.0.8/0002" / package.name
    offset = int.from_bytes(location[2:6], "little")
    with package.open("rb") as handle:
        handle.seek(offset)
        header = handle.read(48)
    assert header[:8] == b"IDRK0000", (texture, package, offset)
    size, compressed, uncompressed, _, resource, kind, flags = struct.unpack_from("<QQQIIII", header, 8)
    assert hx(resource) == texture
    row = {"package": str(package), "offset": offset, "size": size, "compressed": compressed, "uncompressed": uncompressed, "hash": texture, "type": hx(kind), "flags": hx(flags)}
    INVENTORY[texture] = row
    return row

def read_color(texture, out):
    target = out / (texture + ".png")
    if target.exists():
        with Image.open(target) as im:
            im.verify()
        return
    row = INVENTORY.get(texture) or recover_inventory(texture)
    package = Path(row["package"])
    if not package.exists():
        parts = [p for p in row["package"].split("\\") if p]
        package = SOURCE.parent / "SAN8R v1.0.8" / parts[-2] / parts[-1]
    with package.open("rb") as handle:
        handle.seek(row["offset"] + row["size"] - row["compressed"])
        packed = handle.read(row["compressed"])
    if row["compressed"] == row["uncompressed"] and int(row["flags"], 16) & 0xF00000 not in (0x400000, 0x500000):
        data = packed
    else:
        data = bytearray()
        offset = 0
        while len(data) < row["uncompressed"]:
            length = struct.unpack_from("<H", packed, offset)[0]
            offset += 10
            block = packed[offset:offset + length]
            offset += length
            data.extend(lz4.block.decompress(block, uncompressed_size=65536) if int(row["flags"], 16) & 0x100000 else zlib.decompress(block))
    assert len(data) == row["uncompressed"], texture
    for index, _, image in decode_textures(data):
        if index == 0:
            image.save(target)
            return
    raise ValueError(texture)

def material_maps(model):
    raw = RAW_MODELS[model].read_bytes()
    offset, _, count = struct.unpack_from("<III", raw, 12)
    for _ in range(count):
        size = struct.unpack_from("<I", raw, offset + 8)[0]
        if raw[offset:offset + 4] in (b"GM1G", b"G1MG"):
            metadata = parseG1MG(raw[offset:offset + size], "<")
            section = next(s for s in metadata["sections"] if s["type"] == "MATERIALS")
            return [next(t for t in m["textures"] if t["type"] == 1) for m in section["data"]]
        offset += size
    raise ValueError(model)

def stage(stage_id, label, profile):
    folder = SOURCE / "城市全景_已核对" / f"{stage_id}_{label}"
    config = folder / "配置"
    out = ROOT / "assets/city/regional" / profile
    out.mkdir(parents=True, exist_ok=True)
    (out / "models").mkdir(exist_ok=True)
    texture_folder = out / "models/textures"
    texture_folder.mkdir(exist_ok=True)
    (out / "models/.gdignore").touch()
    spec = json.loads((config / "节点及季节.json").read_text(encoding="utf-8-sig"))
    nodes = {n["id"]: n for h in spec["季节配置"]["春"] for n in parse((config / (h + ".bin")).read_bytes())}
    alternate_nodes = [{n["id"]: n for h in hashes for n in parse((config / (h + ".bin")).read_bytes())} for season, hashes in spec["季节配置"].items() if season != "春"]
    definitions = {hx(n["properties"]["KTGLModelDataResourceHash"][0]): n for n in nodes.values() if "KTGLModelDataResourceHash" in n["properties"]}
    models = json.loads((config / "模型对应清单.json").read_text(encoding="utf-8-sig"))
    report = []
    substitutions = []
    omitted_models = []
    for model_info in models:
        model = model_info["模型资源"]
        if model not in definitions:
            continue
        origin = SOURCE / "3D资源/可导入模型_glTF" / model_info["已转换文件"]
        document = json.loads(origin.read_text(encoding="utf-8"))
        document.pop("skins", None)
        for node in document["nodes"]:
            node.pop("skin", None)
        for mesh in document["meshes"]:
            for primitive in mesh["primitives"]:
                primitive["attributes"] = {k: v for k, v in primitive["attributes"].items() if not k.startswith(("JOINTS_", "WEIGHTS_"))}
        for index, buffer in enumerate(document["buffers"]):
            filename = f"{model}-{index}.bin"
            target = out / "models" / filename
            if not target.exists():
                shutil.copy2(origin.parent / buffer["uri"], target)
            buffer["uri"] = filename
        state_id = hx(definitions[model]["properties"]["TexturesRenderStateObjectHash"][0])
        binding = hx(nodes[state_id]["properties"]["TextureBindTableCSVFileResourceHash"][0])
        raw = RAW_BINDINGS[binding].read_bytes()
        slots = {}
        texture_nodes = {}
        for offset in range(0, len(raw), 8):
            slot, node_id = struct.unpack_from("<II", raw, offset)
            slots[slot] = hx(nodes[hx(node_id)]["properties"]["KTGLTexContextResourceHash"][0])
            texture_nodes[slot] = hx(node_id)
        mappings = material_maps(model)
        assert len(mappings) == len(document["materials"]), model
        document["images"], document["textures"] = [], []
        for index, material in enumerate(document["materials"]):
            color_slot = mappings[index]["id"]
            texture = slots[color_slot]
            try:
                read_color(texture, texture_folder)
            except (KeyError, OSError, ValueError, StopIteration, AssertionError, lz4.block.LZ4BlockError) as error:
                print("Unavailable color:", model, index, texture, flush=True)
                requested = texture
                for alternative in alternate_nodes:
                    candidate = hx(alternative[texture_nodes[color_slot]]["properties"]["KTGLTexContextResourceHash"][0])
                    if candidate == requested:
                        continue
                    try:
                        read_color(candidate, texture_folder)
                        texture = candidate
                        substitutions.append({"model": model, "material": index, "requested": requested, "texture": texture, "reason": str(error)})
                        break
                    except (KeyError, OSError, ValueError, StopIteration, AssertionError, lz4.block.LZ4BlockError):
                        continue
                else:
                    if profile == "nanman" and model in ("0109f022", "c73f4e43", "ae69d5bf", "749f33e0", "3ad49201", "b04a1f62"):
                        omitted_models.append(model)
                        substitutions.append({"model": model, "material": index, "requested": requested, "omitted": True, "reason": "Corrupt original ornament/backdrop color atlas; omit the geometry instead of displaying a wrong texture"})
                        break
                    if profile != "nanman" or requested not in ("006ac8bc", "d0f4eedf", "714dd67a", "aa905753"):
                        raise
                    texture = None
                    # glTF factors are linear; the old values became near-white
                    # under the city's ambient and directional lighting.
                    fallback_color = [0.18, 0.15, 0.10, 1]
                    substitutions.append({"model": model, "material": index, "requested": requested, "texture": None, "fallback_color": fallback_color, "reason": "Original archive color texture corrupt; flat color for rear soil or tree trunk only"})
            if texture is not None:
                texture_index = len(document["textures"])
                document["images"].append({"uri": "textures/" + texture + ".png"})
                document["textures"].append({"source": len(document["images"]) - 1, "sampler": 0})
                material["pbrMetallicRoughness"] = {"baseColorTexture": {"index": texture_index, "texCoord": mappings[index]["layer"]}, "metallicFactor": 0, "roughnessFactor": 1}
            else:
                material["pbrMetallicRoughness"] = {"baseColorFactor": fallback_color, "metallicFactor": 0, "roughnessFactor": 1}
            material.update(doubleSided=True, alphaMode="MASK", alphaCutoff=0.4)
            report.append({"model": model, "material": index, "binding": binding, "color_slot": color_slot, "texture": texture})
        if model in omitted_models:
            continue
        document["samplers"] = [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}]
        (out / "models" / (model + ".gltf")).write_text(json.dumps(document), encoding="utf-8")
    placements = []
    all_nodes = {n["id"]: n for f in config.glob("*.bin") for n in parse(f.read_bytes())}
    for node in all_nodes.values():
        properties = node["properties"]
        if node["parent"]:
            properties = {**all_nodes.get(node["parent"], {}).get("properties", {}), **properties}
        display = properties.get("DisplaysetObjectNameHash", [])
        if not display or hx(display[0]) not in nodes:
            continue
        model_ref = nodes[hx(display[0])]["properties"].get("KTGLModelDataResourceHash", [])
        if not model_ref or hx(model_ref[0]) not in definitions or hx(model_ref[0]) in omitted_models:
            continue
        if not node["parent"] and any(n["parent"] == node["id"] for n in all_nodes.values()):
            continue
        placements.append({"model": hx(model_ref[0]), "position": properties.get("WorldPosition", [0, 0, 0]), "rotation": properties.get("WorldQuaternion", [0, 0, 0, 1]), "scale": properties.get("WorldScale", [1, 1, 1])})
    data = {"scene_id": stage_id, "profile": profile, "season": "spring", "texture_substitutions": substitutions, "model_directory": f"res://assets/city/regional/{profile}/models", "placements": placements, "camera": {"target": [0, 0, -3], "distance": 36, "yaw": 9, "pitch": 24, "fov": 44}}
    (out / "scene.json").write_text(json.dumps(data, indent=2), encoding="utf-8")
    (out / "material-bindings.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(profile, len(definitions), "models", len(report), "materials", len(placements), "placements", flush=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog-only", action="store_true")
    parser.add_argument("--profile", choices=[p[2] for p in PROFILES])
    args = parser.parse_args()
    for stage_id, label, profile in PROFILES:
        if not args.catalog_only and profile != "central" and (args.profile is None or args.profile == profile):
            stage(stage_id, label, profile)
    from build_city_scene_catalog import build_catalog
    build_catalog(ROOT)
