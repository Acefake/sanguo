"""Build a small model/material lookup from the existing native object dump."""
from pathlib import Path
import argparse
import json


def stream_array(path):
    decoder = json.JSONDecoder()
    with path.open(encoding='utf8') as file:
        text, position = file.read(1024 * 1024), 1
        while True:
            while position < len(text) and text[position] in ' \t\n\r,': position += 1
            if position < len(text) and text[position] == ']': return
            try:
                item, position = decoder.raw_decode(text, position)
            except json.JSONDecodeError:
                chunk = file.read(1024 * 1024)
                if not chunk: raise
                text = text[position:] + chunk
                position = 0
                continue
            yield item
            if position > 1024 * 1024:
                text = text[position:] + file.read(1024 * 1024)
                position = 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--objects', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    keys = {'KTGLModelDataResourceHash', 'TextureBindTableCSVFileResourceHash', 'KTGLTexContextResourceHash',
            'AnimationDataResourceHash', 'KTGLAnimationDataResourceHash', 'KTGLSkeletonDataResourceHash'}
    rows = []
    count = 0
    for item in stream_array(args.objects):
        count += 1
        if keys.intersection(item.get('props', {})): rows.append(item)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(rows, ensure_ascii=False), encoding='utf8')
    print('NATIVE_LINK_INDEX_OK', count, 'objects;', len(rows), 'model/material references', flush=True)


if __name__ == '__main__': main()
