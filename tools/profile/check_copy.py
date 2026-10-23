"""核对 step_profile.gd 里 ProfiledCampaign.step() 是否仍是 campaign_state.gd 里 step() 的逐行副本。

    python3 tools/profile/check_copy.py

去掉副本里的计时行（_lap、phases/inclusive/calls/_depth/_mark 初始化、decision_contexts_n）和多一级缩进后，
必须与原版逐行相同；不同就打印差异并以退出码 1 结束。运行期还有每日状态哈希比对兜底（见 step_profile.gd）。
"""
import difflib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def body(lines, start, indent):
    out = []
    for line in lines[start + 1:]:
        if line.strip() and not line.startswith(indent + '\t'):
            break
        out.append(line)
    while out and not out[-1].strip():
        out.pop()
    return out


original = (ROOT / 'scripts/war/campaign/campaign_state.gd').read_text(encoding='utf-8').splitlines()
copy = (ROOT / 'tools/profile/step_profile.gd').read_text(encoding='utf-8').splitlines()
o = body(original, original.index('func step(adapter: Node = null) -> void:'), '')
c = body(copy, copy.index('\tfunc step(adapter: Node = null) -> void:'), '\t')
timing = re.compile(r'^\s*(_lap\(|phases\[|phases = |inclusive = |calls = |_depth = |_mark = )')
c = [l[1:] for l in c if not timing.match(l)]
if c != o:
    sys.stdout.writelines(difflib.unified_diff([l + '\n' for l in o], [l + '\n' for l in c], 'campaign_state.gd step()', 'ProfiledCampaign.step()'))
    sys.exit(1)
print('STEP_COPY_OK (%d lines)' % len(o))
