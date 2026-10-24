"""Restore per-material color slots from the original city texture binding tables."""
from pathlib import Path
import json
import struct
import shutil
import sys
from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
namespace = {"__file__": str(ROOT / "tools/assets/import_luoyang_scene.py")}
exec((ROOT / "tools/assets/import_luoyang_scene.py").read_text(encoding="utf-8").split("season_spec=")[0], namespace)
prior, source, config, out = (namespace[k] for k in ("PRIOR", "SOURCE", "CONFIG", "OUT"))
raw_root = prior / "3D资源/原始资源"
manifest = json.loads((prior / "manifest.json").read_text(encoding="utf-8"))
images = {row["hash"]: source / row["png"] for row in manifest if row["texture"] == 0}
inventory = {row["hash"]: row for row in json.loads((prior / "inventory.json").read_text(encoding="utf-8"))}
for extra in prior.glob("0x*_inventory.json"):
    inventory.update({row["hash"]: row for row in json.loads(extra.read_text(encoding="utf-8"))})
sys.path.insert(0, str(prior))
from g1t_decode import textures as decode_textures
sys.path.insert(0, str(prior / "tools/gust_stuff"))
from g1m_export_meshes import parseG1MG

def material_slots(model):
    raw = next(raw_root.glob("*/" + model + "_*.g1m")).read_bytes()
    cursor, _, count = struct.unpack_from("<III", raw, 12)
    for _ in range(count):
        size = struct.unpack_from("<I", raw, cursor + 8)[0]
        if raw[cursor:cursor + 4] in (b"GM1G", b"G1MG"):
            metadata = parseG1MG(raw[cursor:cursor + size], "<")
            materials = next(section["data"] for section in metadata["sections"] if section["type"] == "MATERIALS")
            return [next(texture for texture in material["textures"] if texture["type"] == 1) for material in materials]
        cursor += size
    raise ValueError(model)

def recover_texture(texture):
    destination = out / (texture + ".png")
    if destination.exists():
        try:
            with Image.open(destination) as existing:
                existing.verify()
            return destination
        except (OSError, SyntaxError):
            pass
    row = inventory[texture]
    parts = [p for p in row["package"].split("\\") if p]
    package = Path(row["package"])
    if not package.exists():
        package = source.parent / "SAN8R v1.0.8" / parts[-2] / parts[-1]
    with package.open("rb") as handle:
        handle.seek(row["offset"] + row["size"] - row["compressed"])
        packed = handle.read(row["compressed"])
    if row["compressed"] == row["uncompressed"]:
        data = packed
    else:
        data = bytearray()
        cursor = 0
        while len(data) < row["uncompressed"]:
            length = struct.unpack_from("<H", packed, cursor)[0]
            cursor += 10
            block = packed[cursor:cursor + length]
            cursor += length
            data.extend(namespace["lz4"].block.decompress(block, uncompressed_size=65536) if int(row["flags"], 16) & 0x100000 else namespace["zlib"].decompress(block))
    assert len(data) == row["uncompressed"]
    for index, kind, image in decode_textures(data):
        if index == 0:
            image.save(destination)
            return destination
    raise ValueError("No color texture: " + texture)
raw_files = {p.name.split("_")[0]: p for p in raw_root.glob("*/*.bin")}
spec = json.loads((config / "节点及季节.json").read_text(encoding="utf-8-sig"))
nodes = {n["id"]: n for h in spec["季节配置"]["春"] for n in namespace["parse"]((config / (h + ".bin")).read_bytes())}
hx = namespace["hx"]
report = []
for node in nodes.values():
    props = node["properties"]
    if "KTGLModelDataResourceHash" not in props:
        continue
    model = hx(props["KTGLModelDataResourceHash"][0])
    state = nodes[hx(props["TexturesRenderStateObjectHash"][0])]["properties"]
    binding = hx(state["TextureBindTableCSVFileResourceHash"][0])
    raw = raw_files[binding].read_bytes()
    slots = {}
    for offset in range(0, len(raw), 8):
        slot, texture_node = struct.unpack_from("<II", raw, offset)
        slots[slot] = hx(nodes[hx(texture_node)]["properties"]["KTGLTexContextResourceHash"][0])
    path = out / "春" / (model + ".gltf")
    document = json.loads(path.read_text(encoding="utf-8"))
    material_maps = material_slots(model)
    assert len(material_maps) == len(document["materials"])
    document["images"] = []
    document["textures"] = []
    for index, material in enumerate(document["materials"]):
        color_slot = material_maps[index]["id"]
        texture = slots[color_slot]
        origin = images.get(texture)
        if origin is None or not origin.exists():
            origin = recover_texture(texture)
        assert origin.exists(), origin
        destination = out / (texture + ".png")
        if not destination.exists():
            shutil.copy2(origin, destination)
        document["images"].append({"uri": "../" + destination.name})
        document["textures"].append({"source": index})
        material["pbrMetallicRoughness"] = {"baseColorTexture": {"index": index, "texCoord": material_maps[index]["layer"]}, "metallicFactor": 0, "roughnessFactor": 1}
        report.append({"model": model, "material": index, "binding": binding, "color_slot": color_slot, "texture": texture})
    document["samplers"] = [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}]
    for texture in document["textures"]:
        texture["sampler"] = 0
    path.write_text(json.dumps(document), encoding="utf-8")

# Placements are shared; model and texture-state definitions use only the spring set.
spec = json.loads((config / "节点及季节.json").read_text(encoding="utf-8-sig"))
spring = {n["id"]: n for h in spec["季节配置"]["春"] for n in namespace["parse"]((config / (h + ".bin")).read_bytes())}
spring_models = {hx(n["properties"]["KTGLModelDataResourceHash"][0]) for n in spring.values() if "KTGLModelDataResourceHash" in n["properties"]}
scene_path = out / "scene.json"
scene = json.loads(scene_path.read_text(encoding="utf-8"))
scene["material_binding"] = "G1MG material color sampler -> spring texture state -> original CSV slot table -> color texture"
scene["season"] = "spring"
scene["placements"] = [p for p in scene["placements"] if p["model"] in spring_models]
scene_path.write_text(json.dumps(scene, ensure_ascii=False, indent=2), encoding="utf-8")
(out / "material-bindings.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
for staged in out.glob("????????.png"):
    recover_texture(staged.stem)
print(f"Restored {len(report)} materials; {len(scene['placements'])} spring placements")
