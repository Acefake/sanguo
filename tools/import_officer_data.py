"""Normalize the fetched Notion character cards without inventing live state."""
import json, re
from pathlib import Path
root = Path(__file__).resolve().parents[1]
pages = json.loads((root/'data/officer_notion_sources.json').read_text(encoding='utf-8'))
pages += json.loads((root/'data/officer_shuhan_notion_sources.json').read_text(encoding='utf-8'))
# Notion 原文里的错字。快照保持原样，导入时统一纠正，校验测试会拒绝残留。
TYPOS = {'运筹帷幂': '运筹帷幄', '骄秽': '骄矜', '带兽': '带兵', '带养': '带兵', '臀力': '膂力', '故兔': '故吏', '急造': '急躁', '尤豫': '犹豫', '记仄': '记仇'}
def fix_typos(text):
    for wrong, right in TYPOS.items(): text = text.replace(wrong, right)
    return text
officers = []
for page in pages:
    content = page['text'].split('<content>')[1].split('</content>')[0]
    sections = dict(re.findall(r'## ([^\n]+)\n(.*?)(?=\n## |\Z)', content, re.S))
    stats = [int(re.search(name+r'[\s：:]+(\d+)', sections['五维']).group(1)) for name in ['军事','谋略','勇武','政治','魅力']]
    sub = []
    for line in sections['25项子属性'].splitlines():
        if '：' in line:
            sub.append([int(x.split('→')[-1]) for x in re.findall(r'\d+(?:→\d+)?',line)])
    clean = lambda text: fix_typos(re.sub(r'\*\*|<[^>]+>', '', text).strip())
    assert len(sub) == 5 and all(len(row) == 5 for row in sub), page['title']
    name = page['title'].split('｜')[0]
    style = page['title'].split('｜')[-1] if '｜' in page['title'] and name not in ['关凤', '周仓'] else '—'
    faction = next(f+'集团' for f in ['蜀汉', '孙吴', '袁绍'] if f in page['path'])
    person = {'id':page['url'].split('/p/')[1].split('?')[0], 'name':name, 'style_name':style, 'faction':faction, 'stats':stats, 'substats':sub, 'sections':{k:clean(v) for k,v in sections.items()}, 'source':page['url'], 'edited':page['page_last_edited_at'], 'portrait':'res://assets/officers/portrait.png'}
    if faction == '蜀汉集团':
        traits = []
        for line in person['sections'].get('特性', '').splitlines():
            if '：' not in line: continue
            label, value = line.split('：', 1)
            if label in ['生涯限制']: continue
            if label in ['效果', '机制']:
                if traits: traits[-1]['description'] += '\n'+line
                continue
            rank = ''
            if label == '独有特性':
                if value.startswith('无'): continue
                rank, label = 'legend', value
            elif label.startswith('共享'):
                rank = {'共享金色特性':'gold','共享银色特性':'silver','共享铜色特性':'bronze'}.get(label, '')
                label = value
            elif label == '负面特性':
                if value.startswith('无'): continue
                rank, label = 'negative', value
            elif label.startswith('独有·'): rank = 'legend'
            elif label.startswith('人格限制·'): rank = 'negative'
            elif label.startswith('特殊专长·'): rank = 'unranked'
            label = label.split('·')[-1]
            entry = {'name':label, 'description':label+'\n'+value, 'asset':'trait-common'}
            if rank: entry['rank'] = rank
            traits.append(entry)
        person['traits'] = traits
    officers.append(person)
portrait_manifest = root/'data/officer_portraits.json'
if portrait_manifest.exists():
    portraits = json.loads(portrait_manifest.read_text(encoding='utf-8'))
    for person in officers:
        record = portraits.get(person['name'])
        if record:
            person['portrait'] = record['portrait']
            person['thumbnail'] = record['thumbnail']
(root/'data/officers.json').write_text(json.dumps(officers,ensure_ascii=False,indent=2),encoding='utf-8')
print(f'Imported {len(officers)} Notion character cards')
