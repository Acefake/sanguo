"""Build the current browseable native model, motion and torso portrait index."""
from pathlib import Path
from html import escape
import json

ROOT = Path(__file__).resolve().parents[2]


def main():
    models = json.loads((ROOT/'assets/armies/rtk14/manifest.json').read_text(encoding='utf-8'))
    officers = json.loads((ROOT/'data/officer_portraits.json').read_text(encoding='utf-8'))
    cards = []
    status = {'d3c18f06': '已接入固定步兵阵列与原生动作',
              'cdf4bc12': '已接入固定骑兵阵列与原生战马动作，骑手坐姿已修正',
              '682039a2': '已接入投石车原生摆臂动作与原始贴图',
              'c0d5fa9c': '已接入冲车原生撞槌动作与原始贴图',
              'e5dc4fba': '静态箭楼；已识别倒塌动作，不作为攻城攻击播放',
              'f893127a': '已接入城防和野战射击，原生颜色与法线贴图',
              '9eea5b67': '已接入军旗几何，旗面颜色和文字由项目绘制'}
    for identifier, row in models.items():
        label = escape(row['label'].replace('·', ' '))
        photo = f'validation/army-assets/{identifier}-textured.png'
        if identifier=='f893127a': photo='validation/city-volley-rework-2026-10-06/city-close/15.png'
        image = f'<img loading="lazy" src="{photo}" alt="{label}">' if (ROOT/'docs'/photo).exists() else ''
        model_path = '../' + row['path'].removeprefix('res://')
        details = escape(status.get(identifier,'原始候选，尚未接入当前部队动作'))
        cards.append(f'<article class="asset" data-search="{label} {identifier}">{image}<h3>{label}</h3><p>{identifier}</p><p>{details}</p><a href="{model_path}">原生模型</a></article>')
    faces = []
    for name, row in officers.items():
        portrait = '../' + row['unit_portrait'].removeprefix('res://')
        faces.append(f'<figure class="asset portrait" data-search="{escape(name)}"><img loading="lazy" src="{portrait}" alt="{escape(name)}"><figcaption>{escape(name)}</figcaption></figure>')
    page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>军队模型 动画与立绘</title><style>
*{box-sizing:border-box}body{margin:0;background:#eae4d5;color:#342b23;font:16px/1.65 "Microsoft YaHei",sans-serif}main{max-width:1180px;margin:auto;padding:38px 24px 70px}h1{font-size:30px;margin:0 0 10px}h2{margin-top:36px;font-size:22px}h3{font-size:17px;margin:12px 0 6px}a{color:#80531d}p{margin:8px 0}.note{color:#6b6051}video{display:block;width:100%;max-height:680px;background:#141715;border-radius:8px;margin:22px 0}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px}article,figure{margin:0;border:1px solid #c8bea9;border-radius:6px;background:#faf7ef;padding:16px}article img{width:100%;height:180px;object-fit:contain;background:#d7d4ca;border-radius:4px}.faces{display:grid;grid-template-columns:repeat(auto-fit,minmax(115px,1fr));gap:12px}.portrait{text-align:center}.portrait img{width:100%;height:130px;object-fit:contain}figcaption{margin-top:8px}input{width:100%;border:1px solid #b8aa8d;background:#fffdf7;border-radius:5px;padding:12px;font:inherit;margin:16px 0 0}[hidden]{display:none!important}.links{display:flex;flex-wrap:wrap;gap:18px}
</style><main><h1>军队模型 动画与立绘</h1><p>固定64人步兵阵列与36骑骑兵阵列，透明半身主帅立绘，两格射程的原生箭矢。</p>
<p class="note">2026年10月7日更新。以下视频来自实际地图渲染的动作验证场景，依次展示骑手、按参考图重构的蓝衣弓兵，以及原生投石车和冲车动作。动作由验证脚本触发。</p>
<video controls preload="metadata" poster="validation/hex-combat-readability-2026-10-07/arrows-38-08.png" src="validation/格内射击与兵器朝向预览-2026-10-07.mp4"></video>
<p><a href="格内射击与兵器朝向修正-2026-10-07.md">格内落点 目标高亮 阵型边界与兵器朝向说明</a></p>
<video controls preload="metadata" poster="validation/troop-siege-revision-2026-10-07/city-wall-contact.png" src="validation/兵种特性与贴城攻击预览-2026-10-07.mp4"></video>
<p><a href="兵种特性与交战修正-2026-10-07.md">兵种特性 接战距离与城墙占格说明</a></p>
<p><a href="骑兵弓兵与攻城兵器修正-2026-10-07.md">骑兵 弓兵与攻城兵器修正说明</a></p>
<div class="links"><a href="战斗模型与动画重构-2026-10-06.md">重构与验证说明</a><a href="军队3D素材清单.md">素材清单</a><a href="../assets/armies/rtk14/models/infantry-poses.glb">步兵动作资源</a><a href="../assets/armies/rtk14/models/cavalry-poses.glb">骑兵动作资源</a></div>
<input id="search" aria-label="检索模型或武将" placeholder="输入兵种、模型编号或武将姓名"><h2>模型与使用状态</h2><section class="grid">'''
    page += ''.join(cards) + '</section><h2>透明半身部队立绘</h2><section class="faces">' + ''.join(faces)
    page += '''</section><h2>恢复范围</h2><p>步兵、战马、投石车和冲车原生动作已解码，箭矢原始材质已配对。骑手坐姿、旗面文字、蓝衣弓兵外观和拉弦动作由项目制作；参考图中的原版独立弓兵模型尚未确认，步兵衣甲细节和原作特效参数尚未完整恢复。</p><p>立绘使用用户指定目录中已核对的18个姓名映射，未核对的主帅使用旗帜标识。</p><script>document.getElementById('search').addEventListener('input',event=>{const query=event.target.value.trim().toLowerCase();document.querySelectorAll('.asset').forEach(card=>card.hidden=!card.dataset.search.toLowerCase().includes(query))})</script></main></html>'''
    (ROOT/'docs/军队3D素材浏览.html').write_text(page,encoding='utf-8')
    print('ARMY_GALLERY_UPDATED', len(models), 'native models;', len(officers), 'verified torso portraits')


if __name__=='__main__': main()
