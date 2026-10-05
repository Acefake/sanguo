"""Audit original 220x220 hex terrain codes; emit reproducible coordinates and label crops."""
from pathlib import Path
import collections,json,struct
from PIL import Image,ImageDraw
ROOT=Path(__file__).resolve().parents[1]
def main():
 data=(ROOT/'assets/rtk14/map_grid.bin').read_bytes()
 count=struct.unpack_from('<I',data)[0]
 assert count==220*220 and len(data)==4+count*16
 groups=collections.defaultdict(list)
 for cell in range(count):
  word=struct.unpack_from('<I',data,4+cell*16+4)[0]
  groups[word&255].append((cell,(word>>16)&65535))
 sx,sz,ox,oz=json.loads((ROOT/'assets/rtk14/grid_transform.json').read_text())['parameters']
 tx,ty,px,py=json.loads((ROOT/'assets/rtk14/world_2d_registration.json').read_text())['texture_parameters']
 table=json.loads((ROOT/'data/war/terrain_table.json').read_text(encoding='utf-8'))
 original=Image.open(ROOT/'assets/rtk14/world_2d.png')
 contact=Image.new('RGB',(840,95*len(groups)),(24,24,24));draw=ImageDraw.Draw(contact)
 result={'count':count,'source':'map_grid.bin second uint32 low byte','codes':{}}
 for index,(code,cells) in enumerate(sorted(groups.items())):
  active=[cell for cell,region in cells if region]
  samples=[]
  for i in range(min(5,len(active))):
   cell=active[min(len(active)-1,int((i+.5)*len(active)/5))];col=cell%220;row=cell//220;stagger=(col%2)*.5
   x=px+col*tx;y=py+(row+stagger)*ty
   samples.append({'cell':cell,'column':col,'row':row,'world':[ox+col*sx,oz+(row+stagger)*sz],'texture':[x,y]})
   crop=original.crop((int(x)-25,int(y)-25,int(x)+25,int(y)+25)).resize((88,88))
   contact.paste(crop,(260+i*92,index*95))
  category=table['codes'].get(str(code),table['default'])
  result['codes'][str(code)]={'count':len(cells),'in_region':len(active),'category':category,'mapped':str(code) in table['codes'],'samples':samples}
  draw.text((5,index*95+25),f'code {code} count {len(cells)} {category}',fill='white')
 out=ROOT/'docs/validation';out.mkdir(exist_ok=True)
 (out/'terrain-code-audit.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 contact.save(out/'terrain-code-labels.jpg')
 print('TERRAIN_AUDIT_OK',count,'cells,',len(groups),'codes')
if __name__=='__main__':main()
