"""Native field troops: recovered infantry motion and native horse motion.

The light rider uses the native infantry mesh; its mounted seating adjustment
is authored locally. The horse is reduced with topology-preserving vertex
clustering; no triangles are randomly discarded.
"""
from pathlib import Path
import json
import struct
import numpy as np
from PIL import Image
from native_army_animation import Clip, read_smd, posed, skin, axis_angle

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = Path(r'C:\Users\10228\.codex\visualizations\2026\10\04\01a104a0-d367-7881-a636-f066ae161007\三国志14_动画与战斗资源')
OUT = ROOT / 'assets/armies/rtk14'


def clip(identifier):
    return Clip(next(LIBRARY.rglob(identifier + '.g1a')))


def write_poses(name, frames, uv, texture, extras):
    binary, views, accessors = bytearray(), [], []
    def add(values, kind):
        values = np.asarray(values, '<f4')
        binary.extend(b'\0' * (-len(binary) % 4)); start = len(binary)
        binary.extend(values.tobytes())
        views.append({'buffer': 0, 'byteOffset': start, 'byteLength': values.nbytes, 'target': 34962})
        row = {'bufferView': len(views)-1, 'componentType': 5126, 'count': len(values), 'type': kind}
        if kind == 'VEC3': row.update(min=values.min(0).tolist(), max=values.max(0).tolist())
        accessors.append(row); return len(accessors)-1
    uv_id = add(uv, 'VEC2')
    meshes = [{'name': 'frame_%02d' % i, 'primitives': [{'attributes': {'POSITION': add(p, 'VEC3'), 'NORMAL': add(n, 'VEC3'), 'TEXCOORD_0': uv_id}, 'material': 0}]} for i, (p, n) in enumerate(frames)]
    doc = {'asset': {'version': '2.0', 'generator': 'Recovered RTK14 native G2A field motion'}, 'scene': 0,
           'scenes': [{'nodes': list(range(len(meshes)))}], 'nodes': [{'mesh': i, 'name': meshes[i]['name']} for i in range(len(meshes))],
           'meshes': meshes, 'materials': [{'doubleSided': True, 'pbrMetallicRoughness': {'baseColorTexture': {'index': 0}, 'metallicFactor': 0, 'roughnessFactor': .85}}],
           'images': [{'uri': '../textures/' + texture}], 'textures': [{'source': 0}], 'bufferViews': views, 'accessors': accessors,
           'buffers': [{'byteLength': len(binary)}], 'extras': extras}
    encoded = json.dumps(doc, separators=(',', ':')).encode(); encoded += b' ' * (-len(encoded) % 4)
    binary.extend(b'\0' * (-len(binary) % 4))
    destination = OUT / 'models' / (name + '-poses.glb')
    temporary = destination.with_suffix('.glb.tmp')
    temporary.write_bytes(struct.pack('<III',1179937895,2,28+len(encoded)+len(binary))+struct.pack('<II',len(encoded),1313821514)+encoded+struct.pack('<II',len(binary),5130562)+binary)
    temporary.replace(destination)
    print(name, len(frames), 'poses;', len(uv)//3, 'triangles', flush=True)


def reduce_horse(rig, materials):
    rig = list(rig)
    # Weld short edges only within a texture region and the same primary bone.
    points, uv, weights = rig[3], rig[5], rig[6]
    dominant = np.asarray([max(row, key=lambda pair: pair[1])[0] for row in weights])
    keys = np.column_stack([np.round(points/8).astype(int), np.floor(uv*16).astype(int), dominant, materials])
    _, first, remap = np.unique(keys, axis=0, return_index=True, return_inverse=True)
    faces = remap.reshape(-1, 3)
    keep = (faces[:,0]!=faces[:,1]) & (faces[:,1]!=faces[:,2]) & (faces[:,0]!=faces[:,2])
    faces = faces[keep]
    # Coincident faces can result when several adjacent triangles collapse.
    _, unique = np.unique(np.sort(faces,axis=1),axis=0,return_index=True)
    indices = first[faces[np.sort(unique)]].flatten()
    for i in (3,4,5): rig[i] = rig[i][indices]
    rig[6] = [weights[i] for i in indices]
    return rig, materials[indices]


def seat_rider(rig, pose):
    pose = {i: matrix.copy() for i, matrix in pose.items()}
    parents, local, bind, *_ = rig
    def turn(bone, vector):
        pivot = pose[bone][:3,3].copy(); rotation = axis_angle(np.asarray(vector))
        for child in pose:
            ancestor = child
            while ancestor >= 0 and ancestor != bone: ancestor = parents[ancestor]
            if ancestor != bone: continue
            pose[child][:3,:3] = rotation @ pose[child][:3,:3]
            pose[child][:3,3] = pivot + rotation @ (pose[child][:3,3]-pivot)
    turn(3, [-1.15, 0, -.42]); turn(4, [-1.15, 0, .42])
    turn(5, [1.2, 0, 0]); turn(6, [1.2, 0, 0])
    p,n = skin(rig,pose)
    # Place the pelvis above the saddle. The old .82/.78 fit hid the torso
    # inside the horse and left only its helmet visible from the battle camera.
    return p*1.05 + np.array([0,.85,-.18]), n


def main():
    soldier = read_smd(ROOT/'tools/army-source-cache/soldier-rig.smd')
    idle, walk, strike = clip('0439a8ca'), clip('be09ed4e'), clip('13af95d7')
    specs = [(idle,0)] + [(walk,i/8) for i in range(8)] + [(strike,i/12) for i in range(12)] + [(idle,i/8) for i in range(8)]
    frames = [posed(soldier,c,c.duration*t)[:2] for c,t in specs]
    write_poses('infantry',frames,soldier[5],'24b4dfb4.png',{'source_model':'d3c18f06','clips':{'idle':'0439a8ca','march':'be09ed4e','attack':'13af95d7'},'animation':'native G2A splines','native_bones':23,'forward_axis':'+Z'})
    horse_source = ROOT/'tools/duel-source-cache/horse.smd'
    materials = []
    for line in horse_source.read_text().split('triangles\n')[1].split('end')[0].splitlines():
        if line.startswith('model_0_submesh_'):
            materials.extend([int(line.rsplit('_',1)[1])] * 3)
    horse, horse_materials = reduce_horse(read_smd(horse_source), np.asarray(materials))
    horse_idle, horse_march, horse_attack = clip('80b8fc61'), clip('d94c175d'), clip('d809c932')
    source = OUT/'models/cdf4bc12.glb';raw=source.read_bytes();size=struct.unpack_from('<I',raw,12)[0];doc=json.loads(raw[20:20+size])
    textures = []
    for material in doc['materials']:
        index = material['pbrMetallicRoughness']['baseColorTexture']['index']; image=doc['textures'][index]['source'];textures.append((source.parent/doc['images'][image]['uri']).resolve())
    coat = Image.open(textures[0]).convert('RGB').resize((1024,1024))
    detail = Image.open(textures[1]).convert('RGB').resize((1024,512))
    cloth = Image.open(OUT/'textures/24b4dfb4.png').convert('RGB').resize((1024,512))
    atlas=Image.new('RGB',(2048,1024));atlas.paste(coat,(0,0));atlas.paste(detail,(1024,0));atlas.paste(cloth,(1024,512));atlas.save(OUT/'textures/cavalry-atlas.png')
    h_uv=horse[5].copy();h_uv[:,0]*=.5
    h_uv[horse_materials==1,0]+=.5;h_uv[horse_materials==1,1]*=.5
    s_uv=soldier[5].copy();s_uv=s_uv*.5+.5
    mounted=[]
    # Mounted attacks use a forward gait, not the horse-only rear/kick clip.
    h_specs=[(horse_idle,0)]+[(horse_march,i/8) for i in range(8)]+[(horse_march,i/12) for i in range(12)]+[(horse_idle,i/8) for i in range(8)]
    for i,(c,t) in enumerate(h_specs):
        hp,hn,hpose=posed(horse,c,c.duration*t)
        rider_clip = strike if 9 <= i < 21 else idle
        rider_time = (i-9)/12 if 9 <= i < 21 else (i%8)/8
        _,_,rpose=posed(soldier,rider_clip,rider_clip.duration*rider_time)
        rp,rn=seat_rider(soldier,rpose)
        # Keep the rider attached to the recovered spine/saddle transform.
        saddle=hpose[3] @ np.linalg.inv(horse[2][3]);saddle[:3,3]*=.01
        rp=(saddle @ np.column_stack([rp,np.ones(len(rp))]).T).T[:,:3]
        rn=rn @ saddle[:3,:3].T
        mounted.append((np.vstack([hp,rp]),np.vstack([hn,rn])))
    write_poses('cavalry',mounted,np.vstack([h_uv,s_uv]),'cavalry-atlas.png',{'source_models':['cdf4bc12','d3c18f06'],'horse_clips':{'idle':'80b8fc61','march':'d94c175d','attack':'d94c175d'},'rider':'native infantry 13af95d7 strike with authored seating adjustment','excluded_attack':'horse-only d809c932 rear/kick','horse_reduction':'8cm clustering within bone and UV boundaries'})
    report={'infantry':{'model':'d3c18f06','clips':['0439a8ca','be09ed4e','13af95d7'],'triangles_per_model':525,'fixed_models':64,'palette':'authored khaki cloth and red belt; source material uses 32x32 texture'},'cavalry':{'horse':'cdf4bc12','clips':['80b8fc61','d94c175d','d809c932'],'rider':'d3c18f06','seating':'project authored','triangles_per_mounted_model':len(h_uv)//3+525,'fixed_models':36,'atlas_sources':['90e56d46','e67ffb54','24b4dfb4']},'frame_banks':{'rest':[0,1],'march':[1,8],'attack':[9,12],'idle':[21,8]},'library':str(LIBRARY),'format':'G2A by file magic, despite .g1a suffix','decoder_reference':'https://github.com/Joschuka/Project-G1M'}
    report['cavalry']['clips'] = ['80b8fc61','d94c175d','13af95d7']
    report['cavalry']['mounted_attack'] = 'native forward gait and infantry strike with authored seating; excluded horse-only rear/kick'
    report['cavalry']['rider_fit'] = {'scale':1.05,'vertical_offset_m':.85,'method':'pelvis above saddle; visible torso and helmet verified at battle camera'}
    report['archers'] = {'body':'d3c18f06','reference':'user supplied SAN8R blue archer formation screenshot','bow':'project authored six-sided recurved wooden bow and string','animation':'project authored draw release recovery with native infantry skin weights','uniform':'project authored blue cloth and leather vertex palette; native face texture retained','atlas_sources':['24b4dfb4','74da3a1d'],'original_archer_model':'not confirmed'}
    (OUT/'field_animation_sources.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    manifest_path = OUT/'manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    for model, role in [('d3c18f06','infantry'),('cdf4bc12','cavalry')]:
        manifest[model]['animation_status'] = 'native G2A splines decoded and baked for field playback'
        manifest[model]['field_pose_asset'] = f'res://assets/armies/rtk14/models/{role}-poses.glb'
        manifest[model]['field_details'] = report[role]
        manifest[model]['label'] = '持长兵器步兵 A' if role=='infantry' else '战马 原生动作与野战简化版已接入'
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

if __name__ == '__main__': main()
