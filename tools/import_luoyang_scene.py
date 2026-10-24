"""Stage the verified SAN8R Central Plains scene, preserving UVs and binding references."""
from pathlib import Path
import json, struct, shutil, zlib
import lz4.block

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(r'\\S-dxp4800plus\资料\游戏\pc游戏\【PC】三国志8 REMAKEV1.0.8\SAN8R_解包资源')
PRIOR = Path('C:/Users/10228/.codex/visualizations/2026/10/01/01a0f5f9-30e3-70d3-b60a-67028e417c8a')
OUT = ROOT / 'assets/city/luoyang'
OUT.mkdir(parents=True, exist_ok=True)
CONFIG = SOURCE / '城市全景_已核对/102_中原/配置'
names = {int(k):v for k,v in json.loads((PRIOR/'kod_names.json').read_text(encoding="utf-8")).items()}
FM = {0:('B',1),1:('B',1),2:('h',2),3:('H',2),4:('i',4),5:('I',4),6:('q',8),7:('Q',8),8:('f',4),10:('f',16),12:('f',8),13:('f',12)}

def parse(b):
    if b[:4] != b'_DOK': return []
    off,count=struct.unpack_from('<I',b,8)[0],struct.unpack_from('<I',b,16)[0]
    result=[]
    for _ in range(count):
        size,h,t=struct.unpack_from('<III',b,off+8)
        isr=b[off:off+4]==b'RDOK'
        n=struct.unpack_from('<I',b,off+(24 if isr else 20))[0]
        p=off+(28 if isr else 24); v=p+n*12; props={}
        for j in range(n):
            typ,num,ph=struct.unpack_from('<III',b,p+j*12)
            fmt,width=FM[typ]; length=num*width
            vals=list(struct.unpack_from('<'+fmt*(length//struct.calcsize(fmt)),b,v));v+=length
            props[names.get(ph,f'{ph:08x}')]=vals
        parent=struct.unpack_from('<I',b,off+20)[0] if isr else 0
        result.append({'id':f'{h:08x}','name':names.get(t,''),'parent':hx(parent) if parent else '', 'properties':props})
        off=(off+size+3)&~3
    return result

def hx(v):return f'{v:08x}'


season_spec=json.loads((CONFIG/'节点及季节.json').read_text(encoding='utf-8-sig'))
models={m['模型资源']:m for m in json.loads((CONFIG/'模型对应清单.json').read_text(encoding='utf-8-sig'))}
nodes={n['id']:n for f in CONFIG.glob('*.bin') for n in parse(f.read_bytes())}
placements=[]
for n in nodes.values():
    props=n['properties']
    if n['parent']:
        props={**nodes.get(n['parent'],{}).get('properties',{}),**props}
    display=props.get('DisplaysetObjectNameHash',[])
    if not display:continue
    model_node=nodes.get(hx(display[0]),{})
    mh=model_node.get('properties',{}).get('KTGLModelDataResourceHash',[])
    if not mh:continue
    mh=hx(mh[0])
    if mh not in models:continue
    if not n['parent'] and any(x['parent']==n['id'] for x in nodes.values()):continue
    placements.append({'model':mh,'position':props.get('WorldPosition',[0,0,0]),'rotation':props.get('WorldQuaternion',[0,0,0,1]),'scale':props.get('WorldScale',[1,1,1])})
texture_root=SOURCE/'城市全景_已核对/102_中原/贴图'
for name in ['4f623364','2a0231d0','769947b0','6c3b7ff9','03d20529']:
    shutil.copy2(texture_root/(name+'_000.png'),OUT/(name+'.png'))
(OUT/'春').mkdir(exist_ok=True)
for mh, model in models.items():
    source=SOURCE/'3D资源/可导入模型_glTF'/model['已转换文件']
    d=json.loads(source.read_text(encoding='utf-8'))
    d.pop('skins',None)
    for node in d['nodes']:node.pop('skin',None)
    for i,buffer in enumerate(d['buffers']):
        shutil.copy2(source.with_suffix('.bin'),OUT/'春'/f'{mh}-{i}.bin')
        buffer['uri']=f'{mh}-{i}.bin'
    p=OUT/'春'/(mh+'.gltf')
    tex='2a0231d0' if mh in ['f36a0238','b84591af'] else '6c3b7ff9' if mh=='b61f0af5' else '769947b0' if mh in ['68e42879','837eb960'] else '4f623364'
    
    for mesh in d.get('meshes',[]):
        for primitive in mesh['primitives']:
            for key in list(primitive['attributes']):
                if key.startswith(('JOINTS_', 'WEIGHTS_')):primitive['attributes'].pop(key)
    a=d['accessors'];bounds=[x for x in a if x.get('type')=='VEC3' and 'max' in x]
    if bounds and max(max(x['max']) for x in bounds)<1600 and min(min(x['min']) for x in bounds)>-1600:tex='03d20529'
    d['images']=[{'uri':'../'+tex+'.png'}];d['textures']=[{'source':0}]
    for m in d.get('materials',[]):
        m['pbrMetallicRoughness']={'baseColorTexture':{'index':0},'metallicFactor':0,'roughnessFactor':1}
        m['doubleSided']=True;m['alphaMode']='MASK';m['alphaCutoff']=0.4
    p.write_text(json.dumps(d),encoding='utf-8')
(OUT/'scene.json').write_text(json.dumps({'city':'luoyang','scene_id':102,'placements':placements,'material_binding':'category reconstruction; original binding packages unresolved'},ensure_ascii=False,indent=2),encoding='utf-8')
print('placements',len(placements))
if __name__ == '__main__':
    import subprocess, sys
    subprocess.run([sys.executable, str(ROOT / 'tools/repair_luoyang_materials.py')], check=True)
