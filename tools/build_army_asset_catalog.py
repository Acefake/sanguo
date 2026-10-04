"""Create a browsable catalog of verified army geometry and runtime integration."""
from pathlib import Path
import html
import json

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'assets/armies/rtk14/manifest.json').read_text(encoding='utf8'))
audit = json.loads((root / 'docs/validation/army-assets/rtk14-character-audit.json').read_text(encoding='utf8'))
models = {row.get('id', row.get('model', '')): row for row in (audit if isinstance(audit,list) else audit.get('models', []))}
portraits = json.loads((root / 'data/officer_portraits.json').read_text(encoding='utf8'))
rows, cards = [], []
for model, entry in manifest.items():
    assert (root / entry['path'].removeprefix('res://')).exists(), model
    preview = 'validation/army-assets/' + model + '-textured.png'
    assert (root / 'docs' / preview).exists(), model
    triangles = models.get(model,{}).get('triangles', '?')
    note = '静态原模型；原作动画未绑定'
    if entry['unresolved_textures']: note += '；旗面贴图未找到'
    if entry['role'] == 'horse_high': note += '；高面数，编队接入前需简化'
    if entry['role'] == 'elephant': note += '；姿态待校正'
    rows.append(f"| {entry['label']} | `{model}` | {triangles} | {note} |")
    cards.append(f'<article><img src="{preview}" alt="{html.escape(entry["label"])}"><h3>{html.escape(entry["label"])}</h3><p>{model} · {triangles} 三角面</p><p>{note}</p><a href="../{entry["path"].removeprefix("res://")}">GLB 模型</a></article>')
portrait_cards = []
for name, entry in portraits.items():
    path = entry['thumbnail'].removeprefix('res://')
    assert (root / path).exists(), name
    portrait_cards.append(f'<figure><img src="../{path}" alt="{name}"><figcaption>{name}</figcaption></figure>')
description = '''已在 3D 地图接入步兵编队、主帅圆形头像、兵力与士气、右侧详情及军令。出征在 3D 城池的“出阵”菜单执行，也可从工具栏选择目标；“前往在外军队”可以定位部队。点击主帅头像后可“立即撤退”，随后按日沿路撤往友城，归营时回收兵力与粮草。

军令包含敌军接近时攻击/无视、自主撤退许可、追击许可、攻取后撤退/待命。军令约束智能体的可选行动；主动撤退优先持续执行，溃败仍可保命撤离。敌军仅显示已发现的侦察估计，不能操作。

地图编队使用 525 面步兵，每支军队最多 108 个可视士兵，通过 MultiMesh 合批；画面人数是编队示意，兵力数字来自真实战役。远景隐藏模型、保留头像；原始骨骼权重烘焙为持械站姿、8 帧行军与 12 帧挥击循环。实际接战和攻城事件触发战斗动作。原作 G1A 战斗动作尚未绑定，这些是项目制作的动作。

点击“进行十日”每次固定推进十天，3D地图支持 1×、2×、4×速度。默认每个游戏日播放 2 秒行军过程，位置逐帧移动；按钮或空格立即暂停并继续，十日执行结束后显示军报，重要军情不提前截断执行。逻辑仍按日结算，路线仍来自城市道路图。详见《旬制时间推进首版》。

72 个战役节点已接入 3D 位置：40 个按城池名称匹配原有 3D 城池，32 个通过邻近锚点估算。通路沿节点位置插值并贴地，尚未实现沿原作道路网格寻路。另有 6 个 3D 城池不在现有战役路网中，出阵时会提示选择其他目标。马匹、象、船只和攻城器械已备好，当前编队统一使用步兵外观。
'''
markdown = '# 军队 3D 素材与接入说明\n\n' + description + '\n## 已核实素材\n\n'
markdown += '原始来源：《三国志14》`0002/CharacterEditor` 模型包及其原生材质引用。保留资源哈希；分类经过实际渲染，未猜测武将身份。共 12 个原模型、49 张匹配贴图，以及 1 个项目动作派生 GLB。主帅使用项目已有的 18 套经核对头像，覆盖当前全部 18 名武将。\n\n'
markdown += '| 模型 | 原始哈希 | 三角面 | 状态 |\n| --- | --- | ---: | --- |\n' + '\n'.join(rows)
markdown += '\n\n[浏览全部素材和头像](军队3D素材浏览.html) · [3D 地图实机画面](validation/army-assets/army-world-3d.png) · [项目持械站姿](validation/army-assets/infantry-poses-textured.png)\n\n'
markdown += '## 验证\n\n`tests/capture_army_world_3d.gd`：实际地图渲染、头像点击、出发城映射、敌军情报隔离、军令约束、忙碌保护、主动撤退折返与持续归营、兵力守恒、归营后移除模型。\n\n`tests/war_orders_validation.gd`：军令权限/类型/存档恢复、溃败保命、攻取后待命及改令归营。原有战争与月度性能测试也用于回归检查。所有验证使用临时剧本或临时存档，未覆盖玩家存档。\n\n'
markdown += '## 可复用文件\n\n- `assets/armies/rtk14/manifest.json`：原始模型、材质引用及未绑定资源。\n- `assets/armies/rtk14/models/infantry-poses.glb`：保留原始骨骼权重制作的项目站姿与行军帧。\n- `tools/import_rtk14_army_assets.py`：按原生材质关系重新提取贴图与转换 GLB。\n- `tools/pose_army_infantry.py`：从 Noesis 导出的 SMD 烘焙项目动作。\n- `tools/build_war_3d_positions.py`：生成原城池匹配及明确标注的估算坐标。\n'
(root / 'docs/军队3D素材清单.md').write_text(markdown,encoding='utf8')
page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>军队 3D 素材</title><style>
body{margin:0;background:#18231d;color:#e8e4d0;font:16px/1.6 system-ui,sans-serif}main{max-width:1250px;margin:auto;padding:30px}h1,h2{color:#e0ce93}a{color:#f4d98b}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(270px,1fr));gap:16px}article{background:#24322a;padding:14px;border:1px solid #536146;border-radius:8px}article img{width:100%;height:190px;object-fit:contain}h3{margin:8px 0}p{margin:8px 0;color:#bbc7b7}.hero{width:100%;border-radius:10px}.faces{display:flex;flex-wrap:wrap;gap:16px}figure{margin:0;text-align:center}figure img{width:80px;height:80px;border-radius:50%;object-fit:cover;border:2px solid #96aa73}small{color:#bbc7b7}</style><main>
<h1>军队 3D 素材与实机接入</h1><p>12 个原始模型 · 49 张匹配贴图 · 18 套主帅头像</p>
<img class="hero" src="validation/army-assets/army-world-3d.png" alt="3D地图实机截图"><p>点击主帅头像查看军队详情与军令，直接在 3D 地图出征和撤退。</p>
<h2>地图正在使用：项目持械站姿与行军循环</h2><article><img src="validation/army-assets/infantry-poses-textured.png" alt="项目站姿"><p>原步兵的 23 根骨骼与权重；525 面/帧；持械站姿 + 8 帧项目制作的行军循环。原作战斗动画尚未绑定。</p></article>
<h2>核实后的原始模型</h2><div class="grid">''' + ''.join(cards) + '</div><h2>主帅头像</h2><div class="faces">' + ''.join(portrait_cards) + '</div><h2>接入边界</h2><p>马匹、象、船与器械为已核实候选，当前地图编队统一使用步兵。军旗旗面贴图尚未找到。32 个战役节点使用估算坐标，未还原原作道路寻路。</p><a href="军队3D素材清单.md">素材清单与验证说明</a></main></html>'
(root / 'docs/军队3D素材浏览.html').write_text(page,encoding='utf8')
print('ARMY_CATALOG_OK',len(manifest),'models;',len(portraits),'portrait sets')
