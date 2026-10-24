"""Reassemble supplied atlas territories and bind them to the campaign cities.

Contours come from the supplied atlas / assembled boundary sheet, never Voronoi.
Requires Pillow, numpy and opencv-python-headless for the offline asset pipeline.
"""
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "assets/map/supplied"

# Rows follow the assembled outline from north to south. These are explicit
# geography bindings; packed-sheet order is used only for texture provenance.
CONTROLLERS = [
    "xiangping", "liaoxi", "beiping", "yunzhong", "ji", "jiuquan", "yuyang", "zhangye",
    "zhongshan", "beihai", "yanmen", "nanpi", "pingyuan", "linzi", "wuwei", "dingxiang",
    "jinyang", "ye", "jinan", "tianshui", "shangdang", "jincheng", "puyang", "changan",
    "xiapi", "hedong", "hongnong", "chenliu", "xiaopei", "wudu", "henei", "luoyang",
    "guangling", "chengdu", "xuchang", "runan", "shouchun", "hanzhong", "zitong", "xiangyang",
    "jianye", "wu", "yuzhang", "jiangling", "yongchang", "jiangxia", "jiangzhou", "changsha",
    "jianning", "guiyang", "jiaozhi",
]


def assignment(cost):
    """Hungarian rectangular assignment; rows <= columns."""
    n, m = cost.shape
    u, v = np.zeros(n + 1), np.zeros(m + 1)
    p, way = np.zeros(m + 1, int), np.zeros(m + 1, int)
    for i in range(1, n + 1):
        p[0], j0 = i, 0
        minimum, used = np.full(m + 1, np.inf), np.zeros(m + 1, bool)
        while True:
            used[j0], i0 = True, p[j0]
            delta, j1 = np.inf, 0
            for j in range(1, m + 1):
                if not used[j]:
                    value = cost[i0 - 1, j - 1] - u[i0] - v[j]
                    if value < minimum[j]:
                        minimum[j], way[j] = value, j0
                    if minimum[j] < delta:
                        delta, j1 = minimum[j], j
            for j in range(m + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minimum[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while True:
            j1 = way[j0]
            p[j0], j0 = p[j1], j1
            if j0 == 0:
                break
    result = np.zeros(n, int)
    for j in range(1, m + 1):
        if p[j]:
            result[p[j] - 1] = j - 1
    return result


def describe(contour):
    x, y, w, h = cv2.boundingRect(contour)
    normal = contour.astype(np.float32).copy()
    normal[:, 0, 0] = (normal[:, 0, 0] - x) * 127 / max(1, w - 1)
    normal[:, 0, 1] = (normal[:, 0, 1] - y) * 127 / max(1, h - 1)
    silhouette = np.zeros((128, 128), np.uint8)
    cv2.fillPoly(silhouette, [normal.astype(np.int32)], 1)
    return {"contour": contour, "rect": (x, y, w, h), "mask": silhouette,
            "aspect": w / h, "area": cv2.contourArea(contour)}


def cost(a, b):
    overlap = np.count_nonzero(a["mask"] & b["mask"])
    union = np.count_nonzero(a["mask"] | b["mask"])
    return 1 - overlap / max(1, union) + abs(np.log(a["aspect"] / b["aspect"])) * 0.35


def components(image, threshold=60, minimum=250):
    contours, _ = cv2.findContours((image.max(2) > threshold).astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    return [describe(c) for c in contours if cv2.contourArea(c) > minimum]


def main():
    atlas = np.array(Image.open(SOURCE / "region-edge-b.png").convert("RGB"))[:, :, ::-1].copy()
    pieces = components(atlas)
    composite = np.array(Image.open(SOURCE / "composite.png").convert("RGB"))[:, :, ::-1].copy()
    pixels = composite[:1055, 1920:3430]
    lines = cv2.morphologyEx((pixels.max(2) > 60).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    count, labels, stats, centers = cv2.connectedComponentsWithStats(1 - lines)
    cells = []
    for i in range(1, count):
        if 800 < stats[i, 4] < 500_000:
            mask = (labels == i).astype(np.uint8)
            contour = max(cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)[0], key=cv2.contourArea)
            info = describe(contour)
            info["center"] = centers[i]
            info["label_id"] = i
            cells.append(info)
    if len(pieces) != 51 or len(cells) != 51:
        raise ValueError(f"Expected 51 atlas pieces and cells, got {len(pieces)} / {len(cells)}")
    matched = assignment(np.array([[cost(c, p) for p in pieces] for c in cells]))
    chunk_mask = np.zeros(composite.shape[:2], np.uint8)
    chunk_mask[1080:1640, :1920] = composite[1080:1640, :1920].max(2) > 25
    chunk_mask[:1080, 3420:] = composite[:1080, 3420:].max(2) > 25
    chunk_mask[1080:1640, 3200:] = composite[1080:1640, 3200:].max(2) > 25
    contours = cv2.findContours(chunk_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)[0]
    chunks = [describe(c) for c in contours if cv2.contourArea(c) > 500]
    if len(chunks) != 51:
        raise ValueError(f"Expected 51 textured pieces, got {len(chunks)}")
    chunk_match = assignment(np.array([[cost(c, p) for p in chunks] for c in cells]))

    # The source line sheet has thick double strokes. Flood-fill gives interior
    # contours on BOTH sides of that stroke, leaving an artificial gutter.
    # Propagate only through those line pixels to make one shared label seam.
    seeds = np.ones(labels.shape, np.uint8)
    exterior = int(np.argmax(stats[1:, cv2.CC_STAT_AREA])) + 1
    seeds[labels == exterior] = 0
    for cell in cells:
        seeds[labels == cell["label_id"]] = 0
    _, nearest = cv2.distanceTransformWithLabels(seeds, cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_CCOMP)
    lookup = np.zeros(int(nearest.max()) + 1, np.uint8)
    for index, cell in enumerate(cells):
        py, px = np.argwhere(labels == cell["label_id"])[0]
        lookup[int(nearest[py, px])] = index + 1
    shared_labels = lookup[nearest]
    for index, cell in enumerate(cells):
        footprint = (shared_labels == index + 1).astype(np.uint8)
        cell["footprint"] = footprint
        cell["assembled_contour"] = max(cv2.findContours(footprint, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)[0], key=cv2.contourArea)

    # Draw each shared edge once, independently of the tinted block textures.
    edge = np.zeros(shared_labels.shape, np.uint8)
    edge[:, :-1] |= ((shared_labels[:, :-1] != shared_labels[:, 1:]) & ((shared_labels[:, :-1] > 0) | (shared_labels[:, 1:] > 0))).astype(np.uint8)
    edge[:-1, :] |= ((shared_labels[:-1, :] != shared_labels[1:, :]) & ((shared_labels[:-1, :] > 0) | (shared_labels[1:, :] > 0))).astype(np.uint8)
    dark = cv2.dilate(edge, np.ones((3, 3), np.uint8))
    line_rgba = np.zeros((*edge.shape, 4), np.uint8)
    line_rgba[dark > 0] = (29, 32, 25, 225)
    line_rgba[edge > 0] = (237, 232, 203, 235)
    seam_layer = Image.new("RGBA", (1920, 1080))
    seam_layer.paste(Image.fromarray(line_rgba), (100, 0))
    seam_layer.save(SOURCE / "world-shared-boundaries.png")
    np.save(SOURCE / "block-labels.npy", shared_labels)

    # The relief map and boundary sheet are versions of the same art layout.
    # Registration uses matching coastline landmarks, not campaign coordinates.
    scale = np.array([1.0, 1.0])
    offset = np.array([100.0, 0.0])
    data = json.loads((SOURCE / "layout-baseline.json").read_text(encoding="utf-8"))
    cities = [p for p in data["places"] if p["type"] == "city"]
    city_index = {p["id"]: i for i, p in enumerate(cities)}
    city_match = np.array([city_index[pid] for pid in CONTROLLERS])
    previous_pos = {p["id"]: np.array([p["x"] - 100, p["y"] - 45], float) for p in cities}
    blocks, city_blocks = [], {}
    output = SOURCE / "blocks"
    output.mkdir(exist_ok=True)
    debug = Image.fromarray(cv2.cvtColor(composite[:1080, :1920], cv2.COLOR_BGR2RGB)).convert("RGBA")
    draw = ImageDraw.Draw(debug)
    font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", 22)
    for index, cell in enumerate(cells):
        controller = cities[int(city_match[index])]
        tile = pieces[int(matched[index])]
        chunk = chunks[int(chunk_match[index])]
        x, y, w, h = chunk["rect"]
        texture = composite[y:y+h, x:x+w]
        # Extend atlas RGB past its silhouette before sampling. Black packing
        # pixels must not become a second dark fringe inside the colored region.
        valid = texture.max(2) > 25
        _, nearest_rgb = cv2.distanceTransformWithLabels((~valid).astype(np.uint8), cv2.DIST_L2, 5, labelType=cv2.DIST_LABEL_PIXEL)
        rgb_lookup = np.zeros((int(nearest_rgb.max()) + 1, 3), np.uint8)
        rgb_lookup[1:] = texture[valid]
        texture = rgb_lookup[nearest_rgb]
        cx, cy, cw, ch = cv2.boundingRect(cell["assembled_contour"])
        texture = cv2.resize(texture, (cw, ch), interpolation=cv2.INTER_LINEAR)
        texture_mask = cell["footprint"][cy:cy+ch, cx:cx+cw] * 255
        texture_name = f"block-{index+1:02}.png"
        rgba = cv2.cvtColor(texture, cv2.COLOR_BGR2RGBA)
        rgba[:, :, 3] = texture_mask
        Image.fromarray(rgba).save(output / texture_name)
        poly = cv2.approxPolyDP(cell["assembled_contour"], 0.45, True)[:, 0, :]
        poly = (poly * scale + offset).round(2)
        sx, sy, sw, sh = cx, cy, cw, ch
        rect = [float(sx*scale[0]+offset[0]), float(sy*scale[1]+offset[1]), float(sw*scale[0]), float(sh*scale[1])]
        block = {"id": f"territory-{index+1:02}", "city_id": controller["id"], "place_ids": [controller["id"]],
                 "polygon": poly.tolist(), "rect": rect, "texture": f"res://assets/map/supplied/blocks/{texture_name}",
                 "atlas_sheet": "res://assets/map/supplied/region-edge-b.png", "atlas_rect": list(tile["rect"]),
                 "texture_sheet": "res://assets/map/supplied/composite.png", "texture_rect": list(chunk["rect"]),
                 "shape_error": round(cost(cell, tile), 4), "texture_shape_error": round(cost(cell, chunk), 4)}
        blocks.append(block)
        city_blocks[controller["id"]] = index
        center = cell["center"] * scale + offset
        draw.line([tuple(p) for p in poly] + [tuple(poly[0])], fill=(255, 240, 190), width=2)
        draw.text(tuple(center), f"{index+1} {controller['name']}", font=font, fill="white", stroke_width=2, stroke_fill="black")
    for city in cities:
        if city["id"] not in city_blocks:
            pos = previous_pos[city["id"]]
            candidates = [i for i, b in enumerate(blocks) if cities[int(city_match[i])]["region_id"] == city["region_id"]]
            if not candidates:
                candidates = list(range(51))
            index = min(candidates, key=lambda i: np.linalg.norm(cells[i]["center"] * scale + offset - pos))
            blocks[index]["place_ids"].append(city["id"])
            city_blocks[city["id"]] = index
    positions = {}
    for city in cities:
        index = city_blocks[city["id"]]
        block = blocks[index]
        contour = np.array(block["polygon"], np.float32)
        x, y, w, h = block["rect"]
        center = cells[index]["center"] * scale + offset
        # Maximum-inscribed-circle center stays comfortably within concave pieces.
        mask = np.zeros((1080, 1920), np.uint8)
        cv2.fillPoly(mask, [contour.astype(int)], 1)
        distance = cv2.distanceTransform(mask, cv2.DIST_L2, 5)
        score = distance - np.sqrt((np.indices(mask.shape)[1] - center[0])**2 + (np.indices(mask.shape)[0] - center[1])**2) * 0.15
        if city["id"] != block["city_id"]:
            angle = block["place_ids"].index(city["id"]) * 2.4
            target = center + np.array([np.cos(angle), np.sin(angle)]) * 45
            score = distance - np.sqrt((np.indices(mask.shape)[1] - target[0])**2 + (np.indices(mask.shape)[0] - target[1])**2) * 0.8
        score[distance < 8] = -np.inf
        py, px = np.unravel_index(score.argmax(), score.shape)
        city.update(x=int(px), y=int(py), territory_id=block["id"], territory_city_id=block["city_id"])
        positions[city["id"]] = [int(px), int(py)]
    for place in data["places"]:
        if place["type"] == "pass":
            anchor = positions["luoyang"]
            place["x"], place["y"] = anchor[0] + (-40 if place["id"] == "west_pass" else 40), anchor[1] + 12
            positions[place["id"]] = [place["x"], place["y"]]
    for region in data["regions"]:
        region_blocks = [b for b in blocks if cities[city_index[b["city_id"]]]["region_id"] == region["id"]]
        region["polygons"] = [b["polygon"] for b in region_blocks]
        points = np.array([point for b in region_blocks for point in b["polygon"]], np.float32)
        if len(points):
            region["polygon"] = cv2.convexHull(points).reshape(-1, 2).tolist()
            region["label"] = np.mean(points, axis=0).round().astype(int).tolist()
    # Assemble the city road network at the actual territory positions.
    primary = [b["city_id"] for b in blocks]
    connected, remaining, road_pairs = {primary[0]}, set(primary[1:]), set()
    while remaining:
        _, a, b = min((np.linalg.norm(np.array(positions[a])-positions[b]), a, b) for a in connected for b in remaining)
        road_pairs.add(tuple(sorted((a, b))))
        connected.add(b)
        remaining.remove(b)
    candidates = sorted((np.linalg.norm(np.array(positions[a])-positions[b]), a, b)
                        for i, a in enumerate(primary) for b in primary[i+1:] if tuple(sorted((a, b))) not in road_pairs)
    added = 0
    for distance, a, b in candidates:
        if distance > 250 or added >= 15:
            break
        road_pairs.add(tuple(sorted((a, b))))
        added += 1
    for city in cities:
        if city["id"] == city["territory_city_id"]:
            continue
        controller = city["territory_city_id"]
        road_pairs.add(tuple(sorted((city["id"], controller))))
        neighbor = min((p for p in primary if p != controller), key=lambda p: np.linalg.norm(np.array(positions[city["id"]])-positions[p]))
        road_pairs.add(tuple(sorted((city["id"], neighbor))))
    road_pairs.update([tuple(sorted(pair)) for pair in [("hongnong", "west_pass"), ("west_pass", "luoyang"), ("luoyang", "east_pass"), ("east_pass", "chenliu")]])
    data["routes"] = [{"id": f"b{i+1:03}", "from": a, "to": b, "cost": max(1, round(np.linalg.norm(np.array(positions[a])-positions[b]) / 80))}
                      for i, (a, b) in enumerate(sorted(road_pairs))]
    for route in data["routes"]:
        a, b = np.array(positions[route["from"]]), np.array(positions[route["to"]])
        direction = b-a
        perpendicular = np.array([-direction[1], direction[0]], float) / max(1, np.linalg.norm(direction))
        midpoint = (a+b) / 2 + perpendicular * min(18, np.linalg.norm(direction) * 0.12)
        route["points"] = [a.tolist(), midpoint.round().astype(int).tolist(), b.tolist()]
    display_routes, seen = [], set()
    place_lookup = {p["id"]: p for p in data["places"]}
    for route in data["routes"]:
        a = place_lookup[route["from"]].get("territory_city_id", route["from"])
        b = place_lookup[route["to"]].get("territory_city_id", route["to"])
        key = tuple(sorted((a, b)))
        if a == b or key in seen:
            continue
        seen.add(key)
        pa, pb = np.array(positions[a]), np.array(positions[b])
        midpoint = (pa+pb) / 2
        delta = pb-pa
        midpoint = midpoint + np.array([-delta[1], delta[0]]) / max(1, np.linalg.norm(delta)) * 14
        display_routes.append({"from": a, "to": b, "points": [pa.tolist(), midpoint.round().astype(int).tolist(), pb.tolist()]})
    data["display_routes"] = display_routes
    data["territory_blocks"] = blocks
    data["background"] = "res://assets/map/supplied/world-relief.png"
    data["territory_layout"] = "supplied-atlas"
    data["show_faction_labels"] = False
    data["shared_boundaries"] = "res://assets/map/supplied/world-shared-boundaries.png"
    data.pop("land_mask", None)
    (ROOT / "data/world_map.json").write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    Image.fromarray(cv2.cvtColor(composite[:1080, :1920], cv2.COLOR_BGR2RGB)).save(SOURCE / "world-relief.png")
    debug.save(SOURCE / "block-layout-preview.png")
    print(f"Reassembled {len(blocks)} supplied blocks, {len(cities)} cities")
    print("Largest shape errors:", sorted([(b["id"], b["shape_error"], b["city_id"]) for b in blocks], key=lambda x:x[1], reverse=True)[:8])
    scenario_path = ROOT / "data/scenario_world_demo.json"
    scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
    colors = {"cao_cao": "#263ddb", "yuan_shao": "#e5bb28", "sun_jian": "#bf143e",
              "liu_biao": "#5ca9b5", "liu_yan": "#382681", "shi_xie": "#795176",
              "ma_teng": "#94621d", "han_sui": "#ae7926", "dong_zhuo": "#a5ad65",
              "liu_bei": "#579f61", "lu_bu": "#962a87", "yuan_shu": "#d38622",
              "liu_yu": "#dfc246", "gongsun_zan": "#e0b72c", "gongsun_du": "#bba4cb",
              "zhang_lu": "#55448a", "liu_yao": "#b74257", "tao_qian": "#b9567c",
              "kong_rong": "#b89b55", "zhang_yang": "#527ab5", "zhang_yan": "#456aa5"}
    for faction_id, color in colors.items():
        scenario["factions"][faction_id]["color"] = color
    scenario_path.write_text(json.dumps(scenario, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
