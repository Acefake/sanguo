from pathlib import Path
import cv2, numpy as np, re
source = Path(r'\\S-dxp4800plus\资料\游戏\pc游戏\【PC】三国志8 REMAKEV1.0.8\SAN8R_解包资源\武将立绘\缩略图_补全')
cv2.setNumThreads(1)
sift = cv2.SIFT_create(nfeatures=250)
matcher = cv2.BFMatcher()
references = {}
for file in Path('C:/Users/10228/Downloads').glob('*.jpg'):
    if file.name not in ['コウチュウ.jpg','リョウカ.jpg','ギエン.jpg']: continue
    image = cv2.imdecode(np.fromfile(file,dtype=np.uint8),0)
    image = cv2.resize(image,(200,280))
    references[file.name] = sift.detectAndCompute(image,None)[1]
scores = {name:[] for name in references}
for file in source.glob('*.jpg'):
    image = cv2.imdecode(np.fromfile(file,dtype=np.uint8),0)
    image = cv2.resize(image,(200,280))
    _, descriptors = sift.detectAndCompute(image,None)
    if descriptors is None: continue
    for name, target in references.items():
        matches = matcher.knnMatch(descriptors,target,k=2)
        score = sum(a.distance < .65*b.distance for a,b in matches if len([a,b])==2)
        scores[name].append((score,file.name))
for name, rows in scores.items(): print(name,sorted(rows,reverse=True)[:5],flush=True)
