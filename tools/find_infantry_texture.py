"""Find full-resolution native textures with the infantry's original UV layout.

Decode original BC1 data, compare against the recovered low-resolution binding,
and retain source IDs. A similarity score is a candidate, not a binding proof.
"""
from pathlib import Path
import json, re, struct, zlib
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(r'C:\Users\10228\.codex\visualizations\2026\10\01\01a0f78f-1022-73e2-b695-c363e0e2e1ff\rtk14-assets')
GAME = Path(r'\\S-dxp4800plus\资料\游戏\pc游戏\ROMANCE OF THE THREE KINGDOMS XIV\ROMANCE OF THE THREE KINGDOMS XIV (2)')
OUT = ROOT/'tools/army-source-cache/texture-search'

def decode(raw):
    table = struct.unpack_from('<I',raw,12)[0]
    offset = table + struct.unpack_from('<I',raw,table)[0]
    formats = {0x59:1,0x5B:3,0x5F:7}
    if raw[offset+1] not in formats: return None
    size = raw[offset+2]; w,h = 1 << (size & 15), 1 << (size >> 4)
    if w < 128 or h < 128 or w > 2048 or h > 2048: return None
    extra = struct.unpack_from('<I',raw,offset+8)[0]
    return Image.frombytes('RGBA',(w,h),raw[offset+8+extra:],'bcn',formats[raw[offset+1]])

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    rows = [r for r in json.loads((SOURCE/'all-index.json').read_text(encoding='utf8')) if r['package']=='MaterialEditor' and r['ext']=='g1t' and 10000 < r['size'] < 6000000]
    target = np.asarray(Image.open(ROOT/'assets/armies/rtk14/textures/24b4dfb4.png').convert('RGB'),float)
    target = (target-target.mean())/target.std()
    ranks, handles, unresolved = [], {}, []
    for i,row in enumerate(rows):
        p = OUT/(row['id']+'.g1t')
        if p.exists(): raw = p.read_bytes()
        else:
            match = re.fullmatch(r'([a-fA-F0-9]+)@([a-fA-F0-9]+)(?:#([a-fA-F0-9]+))?(?:&([a-fA-F0-9]+))?',row['address'])
            suffix = (str(int(match[3],16)) if match[3] else '') + ('_'+str(int(match[4],16)) if match[4] else '')
            name = 'MaterialEditor.rdb.bin'+suffix
            if name not in handles: handles[name] = (GAME/'0002'/name).open('rb')
            f = handles[name]; f.seek(int(match[1],16)); entry = f.read(int(match[2],16))
            total,compressed = struct.unpack_from('<qq',entry,8); packed = entry[total-compressed:total]
            blocks,offset = [],0
            try:
                while row['flags'] & 0x100000 and offset < len(packed):
                    length = struct.unpack_from('<I',packed,offset)[0];offset += 4
                    if not length: break
                    blocks.append(zlib.decompress(packed[offset:offset+length])); offset += length
            except zlib.error:
                unresolved.append(row['id']);continue
            raw = b''.join(blocks) if row['flags'] & 0x100000 else packed
            p.write_bytes(raw)
        im = decode(raw)
        if im:
            a = np.asarray(im.convert('RGB').resize((32,32)),float)
            if a.std() > 15:
                ranks.append((float(np.mean((target-(a-a.mean())/a.std())**2)),row['id'],im.size))
        if i % 100 == 0: print('TEXTURE_SCAN',i,len(rows),flush=True)
    for f in handles.values(): f.close()
    ranks.sort()
    (OUT/'scan-status.json').write_text(json.dumps({'resources':len(rows),'unresolved':unresolved,'ranked':len(ranks)},indent=2),encoding='utf8')
    (OUT/'rank.json').write_text(json.dumps(ranks[:50],indent=2),encoding='utf8')
    canvas = Image.new('RGB',(1000,600),'#666'); draw = ImageDraw.Draw(canvas)
    for i,(err,id,size) in enumerate(ranks[:15]):
        im = decode((OUT/(id+'.g1t')).read_bytes());im.save(OUT/(id+'.png'));im.thumbnail((190,160))
        x,y=i%5*200,i//5*200;canvas.paste(im,(x,y));draw.text((x,y+165),f'{id} {size}\n{err:.4f}',fill='white')
    canvas.save(ROOT/'docs/validation/full-infantry-texture-candidates.jpg')
    print('NATIVE_TEXTURE_CANDIDATES',ranks[:5],flush=True)

if __name__ == '__main__': main()
