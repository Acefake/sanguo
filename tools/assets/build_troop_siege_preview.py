"""Package actual Godot captures, verifying visible action before export."""
from pathlib import Path
import subprocess,json
import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[2]
FRAMES=ROOT/'docs/validation/troop-siege-revision-2026-10-07'
FFMPEG=Path(r'C:\ffmpeg-2026-04-19-git-de18feb0f0-full_build\bin\ffmpeg.exe')

def encode(args,target):
 subprocess.run([str(FFMPEG),'-y','-loglevel','error']+args+['-an','-c:v','libx264','-crf','22','-pix_fmt','yuv420p','-r','30',str(target)],check=True,creationflags=0x08000000)

if __name__=='__main__':
 report={}
 for name in ['cavalry-attack','archer-attack','siege','city-65','city-130']:
  a=np.asarray(Image.open(FRAMES/f'{name}-00.png').convert('RGB'),int)
  b=np.asarray(Image.open(FRAMES/f'{name}-05.png').convert('RGB'),int)
  report[name]=int(np.count_nonzero(np.max(np.abs(a-b),axis=2)>8))
  assert report[name]>(100 if name.startswith('city-') else 500),'No visible motion in '+name
 for distance in [65,130]:
  baseline=np.asarray(Image.open(FRAMES/f'city-{distance}-baseline.png').convert('RGB'),int)
  flight=np.asarray(Image.open(FRAMES/f'city-{distance}-06.png').convert('RGB'),int)
  # Scene differences are a capture sanity check, not isolated arrow pixel counts.
  report[f'city-{distance}-scene-difference']=int(np.count_nonzero(np.max(np.abs(flight-baseline),axis=2)>15))
  assert report[f'city-{distance}-scene-difference']>100,'Distant city capture did not change'
 for name in ['cavalry','archers']:
  encode(['-loop','1','-i',str(FRAMES/(name+'-formation.png')),'-t','2'],FRAMES/(name+'.mp4'))
 for name in ['cavalry-attack','archer-attack','siege','city-65','city-130']:
  encode(['-stream_loop','1','-framerate','6','-i',str(FRAMES/(name+'-%02d.png')),'-t','4'],FRAMES/(name+'.mp4'))
 listing=FRAMES/'video-parts.txt'
 encode(['-loop','1','-i',str(FRAMES/'city-wall-contact.png'),'-t','3'],FRAMES/'city-wall-contact.mp4')
 listing.write_text(''.join("file '%s.mp4'\n"%s for s in ['city-wall-contact','cavalry-attack','archer-attack','siege','city-65','city-130']),encoding='utf8')
 target=ROOT/'docs/validation/兵种特性与贴城攻击预览-2026-10-07.mp4'
 subprocess.run([str(FFMPEG),'-y','-loglevel','error','-f','concat','-safe','0','-i',str(listing),'-c','copy','-movflags','+faststart',str(target)],check=True,creationflags=0x08000000)
 (FRAMES/'motion-validation.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
 print('TROOP_SIEGE_GPU_MOTION_OK',report,'video',target)
