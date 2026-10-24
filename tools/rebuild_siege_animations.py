"""Bake native siege G2A actions matched by skeleton/rest translations.

Keep native per-surface materials and UVs. March samples wheel tracks only;
attack samples the complete recovered action. Destruction clips are excluded.
"""
import copy,json,struct
from pathlib import Path
import numpy as np
from native_army_animation import read_smd,posed,skin
from rebuild_field_troops import ROOT,OUT,clip

SPECS = {
 # 3c2b56a0 tips over the chassis and scatters parts: destruction, not firing.
 'tower':('e5dc4fba','siege-watchtower','d1492973',None,[]),
 'catapult':('682039a2','siege-tower','ce531a4d','fa7ff620',[4,5]),
 'ram':('c0d5fa9c','siege-ram','e94a7726','157752f9',[4,5]),
}

def build(kind,spec):
 model,name,idle_id,action_id,wheels = spec
 rig=read_smd(ROOT/f'tools/army-source-cache/{name}-rig.smd')
 idle,action=clip(idle_id),clip(action_id or idle_id)
 rest=posed(rig,idle,0)[2]
 frames=[skin(rig,rest)]
 for i in range(8):
  wheel_pose=posed(rig,action,action.duration*i/8)[2]
  # These bones have no descendants; retain chassis and firing mechanism at rest.
  march={b:matrix.copy() for b,matrix in rest.items()}
  for b in wheels:
   march[b]=wheel_pose[b].copy()
   march[b][:3,3]=rest[b][:3,3]
  frames.append(skin(rig,march))
 for i in range(12):
  attack_pose=posed(rig,action,action.duration*i/12)[2]
  # The map formation handles world travel. Remove the native chassis root
  # displacement to prevent the mechanism snapping back at the cycle boundary.
  travel=attack_pose[2][:3,3]-rest[2][:3,3]
  for b in attack_pose:
   ancestor=b
   while ancestor >= 0 and ancestor != 2: ancestor=rig[0][ancestor]
   if ancestor==2:attack_pose[b][:3,3]-=travel
  frames.append(skin(rig,attack_pose))
 frames += [skin(rig,rest)]*8
 raw=(OUT/f'models/{model}.glb').read_bytes();doc=json.loads(raw[20:20+struct.unpack_from('<I',raw,12)[0]])
 tags=[]
 for line in (ROOT/f'tools/army-source-cache/{name}-rig.smd').read_text().split('triangles\n')[1].split('end')[0].splitlines():
  if line.startswith('model_0_submesh_'):tags += [int(line.rsplit('_',1)[1])]*3
 tags=np.asarray(tags); binary=bytearray();views=[];accessors=[]
 def add(a,type,component=5126):
  a=np.asarray(a,'<f4' if component==5126 else '<u4');binary.extend(b'\0'*(-len(binary)%4));start=len(binary);binary.extend(a.tobytes())
  views.append({'buffer':0,'byteOffset':start,'byteLength':a.nbytes})
  row={'bufferView':len(views)-1,'componentType':component,'count':len(a),'type':type}
  if type=='VEC3':row.update(min=a.min(0).tolist(),max=a.max(0).tolist())
  accessors.append(row);return len(accessors)-1
 uv=add(rig[5],'VEC2');ranges=[add(np.flatnonzero(tags==i),'SCALAR',5125) for i in range(len(doc['meshes'][0]['primitives']))]
 meshes=[]
 for i,(p,n) in enumerate(frames):
  attrs={'POSITION':add(p,'VEC3'),'NORMAL':add(n,'VEC3'),'TEXCOORD_0':uv}
  meshes.append({'name':f'frame_{i:02d}','primitives':[{'attributes':attrs,'indices':index,'material':doc['meshes'][0]['primitives'][s]['material']} for s,index in enumerate(ranges)]})
 result={k:copy.deepcopy(doc[k]) for k in ['materials','images','textures','samplers'] if k in doc}
 result.update(asset={'version':'2.0','generator':'Native siege G2A spline recovery'},scene=0,scenes=[{'nodes':list(range(29))}],nodes=[{'mesh':i,'name':f'frame_{i:02d}'} for i in range(29)],meshes=meshes,bufferViews=views,accessors=accessors,buffers=[{'byteLength':len(binary)}],extras={'source_model':model,'idle':idle_id,'action':action_id,'march':'native wheel tracks only','bones':len(rig[0])})
 encoded=json.dumps(result,separators=(',',':')).encode();encoded+=b' '*(-len(encoded)%4);binary.extend(b'\0'*(-len(binary)%4))
 (OUT/f'models/siege-{kind}-poses.glb').write_bytes(struct.pack('<III',1179937895,2,28+len(encoded)+len(binary))+struct.pack('<II',len(encoded),1313821514)+encoded+struct.pack('<II',len(binary),5130562)+binary)
 delta=max(float(np.linalg.norm(p-frames[0][0],axis=1).max()) for p,n in frames[9:21])
 print('NATIVE_SIEGE_POSES',kind,len(rig[0]),'bones',len(tags)//3,'triangles','motion',round(delta,3),flush=True)
 return {'model':model,'idle':idle_id,'action':action_id,'bones':len(rig[0]),'attack_displacement':delta,'binding_evidence':'compatible track indices and rest translations; visually validate mechanism','march':'native wheel tracks, chassis held at rest'}

if __name__=='__main__':
 report={k:build(k,v) for k,v in SPECS.items()}
 (OUT/'siege_animation_sources.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
