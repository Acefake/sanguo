"""Build explicit city scene assignments from the locally verified source table."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
PROFILES = [
    (101, "北方", "north"), (102, "中原", "central"),
    (103, "江南", "south"), (104, "西蜀", "shu"), (105, "南蛮", "nanman"),
]
LOCATIONS = {
    "north": {"government": [695, 177], "farm": [300, 231], "market": [400, 568], "barracks": [825, 391], "workshop": [451, 365], "tavern": [746, 548]},
    "central": {"government": [658, 177], "market": [345, 565], "farm": [302, 233], "barracks": [1060, 409], "workshop": [395, 394], "tavern": [758, 418]},
    "south": {"government": [674, 178], "farm": [351, 288], "market": [407, 520], "barracks": [762, 388], "workshop": [460, 376], "tavern": [752, 587]},
    "shu": {"government": [706, 164], "farm": [295, 222], "market": [744, 380], "barracks": [791, 523], "workshop": [462, 351], "tavern": [1060, 445]},
    "nanman": {"government": [674, 156], "farm": [338, 266], "market": [421, 353], "barracks": [780, 373], "workshop": [356, 434], "tavern": [689, 589]},
}


def build_catalog(root=ROOT):
    world = json.loads((root / "data/world_map.json").read_text(encoding="utf-8"))
    reference = json.loads((root / "data/city_scene_reference.json").read_text(encoding="utf-8"))
    assignments = json.loads((root / "data/city_scene_extensions.json").read_text(encoding="utf-8"))
    originals = {city["name"]: city for city in reference["cities"]}
    scene_profiles = {scene: profile for scene, _, profile in PROFILES}
    cities = {}
    for city in world["places"]:
        if city["type"] != "city":
            continue
        city_id = city["id"]
        rule = assignments["aliases"].get(city_id)
        if rule is not None:
            if city["name"] != rule["name"]:
                raise ValueError(f"City alias name changed: {city_id}")
            original = originals[rule["source_city"]]
            mapping = "original_city_alias"
            reason = rule["reason"]
        elif city["name"] in originals:
            original = originals[city["name"]]
            mapping = "original_city_table"
            reason = "已核对原始城市表→州表→场景类型字段。"
        else:
            # Broad map regions merge original states (雍州/司隶, 益州/南中,
            # 徐州/扬北). An unknown city must be configured explicitly.
            rule = assignments["extensions"].get(city_id)
            if rule is None:
                raise ValueError(f"Missing explicit city scene assignment: {city_id} ({city['name']})")
            if city["name"] != rule["name"]:
                raise ValueError(f"City extension name changed: {city_id}")
            original = originals[rule["source_city"]]
            if rule["state"] != original["state"]:
                raise ValueError(f"Reference city/state mismatch: {city_id}")
            mapping = "configured_extension"
            reason = rule["reason"]
        cities[city_id] = {
            "name": city["name"], "profile": scene_profiles[original["scene_id"]],
            "scene_id": original["scene_id"], "mapping": mapping,
            "source_scene_id": original["scene_id"],
            "source_city": original["name"], "source_city_id": original["city_id"],
            "source_state": original["state"], "source_state_id": original["state_id"],
            "reason": reason,
        }
        override = assignments.get("overrides", {}).get(city_id)
        if override is not None:
            if override["name"] != city["name"] or override["profile"] not in LOCATIONS:
                raise ValueError(f"Invalid city appearance override: {city_id}")
            cities[city_id].update(
                profile=override["profile"],
                scene_id=next(scene for scene, _, profile in PROFILES if profile == override["profile"]),
                reference_mapping=mapping, mapping="visual_override", reason=override["reason"],
            )
    configured = set(assignments["aliases"]) | set(assignments["extensions"]) | set(assignments.get("overrides", {}))
    if configured - set(cities):
        raise ValueError(f"Assignments for cities absent from the map: {configured - set(cities)}")
    catalog_path = root / "data/city_scenes.json"
    previous = json.loads(catalog_path.read_text(encoding="utf-8")) if catalog_path.exists() else {}
    profiles = {}
    for scene_id, name, profile in PROFILES:
        folder = "res://assets/city/luoyang" if profile == "central" else f"res://assets/city/regional/{profile}"
        profiles[profile] = {
            "name": name, "scene_id": scene_id, "scene": folder + "/scene.json",
            "art": folder + "/preview-perspective.png",
            "locations": previous.get("profiles", {}).get(profile, {}).get("locations", LOCATIONS[profile]),
        }
    catalog_path.write_text(json.dumps({"schema_version": 2, "reference": "res://data/city_scene_reference.json", "profiles": profiles, "cities": cities}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    labels = {profile: name for _, name, profile in PROFILES}
    region_names = {region["id"]: region["name"] for region in world["regions"]}
    lines = [
        "# 城池与场景逐城核对表", "",
        "原始 51 城的对应已用解码后的城市表、州表逐条校验。当前地图有 70 城；长安按用户要求单独覆盖为都城布局，其他 42 城直接对应原城市、1 城使用名称别名、26 城采用明确配置的参照城。原数据用于追溯，不限制本项目的城市美术配置。", "",
        "场景按城市 ID 指定，不跟随势力变更，也不按大地图州名兜底。城市外观覆盖优先于原版分类；原版五类城景允许同类城市共享布局。", "",
        "## 修正前后游戏实拍", "",
        "长安：此前照搬原版泛北方分类，误呈现为西凉边城；现在明确覆盖为都城式宫城、石城墙与灰瓦坊市布局。", "",
        "![长安修正前](../assets/city/comparisons/before-changan.png)", "",
        "![长安修正后](../assets/city/comparisons/changan.png)", "",
        "酒泉：原来误用中原，现在参照同凉州的武威使用北方布局。", "",
        "![酒泉修正前](../assets/city/comparisons/before-jiuquan.png)", "",
        "![酒泉修正后](../assets/city/comparisons/jiuquan.png)", "",
        "合浦：原来误用南蛮，现在参照同交州的交趾使用江南布局。", "",
        "![合浦修正前](../assets/city/comparisons/before-hepu.png)", "",
        "![合浦修正后](../assets/city/comparisons/hepu.png)", "",
        "边界对比：[长安](../assets/city/comparisons/changan.png) / [洛阳](../assets/city/comparisons/luoyang.png)，[广陵](../assets/city/comparisons/guangling.png) / [下邳](../assets/city/comparisons/xiapi.png)，[成都](../assets/city/comparisons/chengdu.png) / [建宁](../assets/city/comparisons/jianning.png)。建宁缺失贴图的地台暂用纯色，仍未完整还原。", "",
        "## 70 城配置", "",
        "| 本项目城市 | 大地图区域 | 实际场景 | 原场景编号 | 原配置州 | 参照原城市 | 对应方式 |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for place in world["places"]:
        if place["type"] != "city":
            continue
        city = cities[place["id"]]
        kind = {"original_city_table": "原城市表", "original_city_alias": "名称别名", "configured_extension": "扩展城配置", "visual_override": "城市外观覆盖"}[city["mapping"]]
        lines.append(f"| {city['name']} | {region_names[place['region_id']]} | {labels[city['profile']]} · {city['scene_id']} | {city['source_scene_id']} | {city['source_state']} | {city['source_city']} · {city['source_city_id']} | {kind} |")
    (root / "docs/city-scene-comparison.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("Mapped", len(cities), "cities using explicit source city references")


if __name__ == "__main__":
    build_catalog()
