"""Encode the actual GPU capture sequences into the current battle preview."""
import argparse
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', type=Path, required=True)
    args = parser.parse_args()
    validation = ROOT / 'docs/validation'
    city = validation / 'city-volley-rework-2026-10-06'
    troops = validation / 'reference-troops-2026-10-06'
    sequences = [(city/'city', city/'城防多向齐射.mp4',70),
                 (city/'city-close', city/'原生箭矢近景.mp4',70),
                 (city/'contact', city/'部队交战弧光.mp4',70),
                 (troops, troops/'步兵骑兵与立绘.mp4',80)]
    for folder, movie, frames in sequences:
        assert all((folder/f'{index:02d}.png').exists() for index in range(frames)), folder
        subprocess.run([str(args.ffmpeg), '-hide_banner', '-loglevel','error','-y','-framerate','20',
                        '-i', str(folder/'%02d.png'), '-frames:v',str(frames), '-c:v','libx264',
                        '-preset','fast','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(movie)],check=True)
    playlist = city/'preview.ffconcat'
    playlist.write_text('ffconcat version 1.0\n' + ''.join("file '" + movie.as_posix().replace("'", "'\\''") + "'\n" for _,movie,_ in sequences),encoding='utf-8')
    combined = validation/'战斗重构预览-2026-10-06.mp4'
    subprocess.run([str(args.ffmpeg),'-hide_banner','-loglevel','error','-y','-f','concat','-safe','0',
                    '-i',str(playlist),'-c','copy','-movflags','+faststart',str(combined)],check=True)
    print('BATTLE_REWORK_PREVIEW', combined, '14.5 seconds')


if __name__ == '__main__':
    main()
