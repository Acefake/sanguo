"""Campaign checks and renderer-dependent startup, retaining diagnostic evidence."""
import concurrent.futures
import json
import re
import subprocess
import time
from pathlib import Path
from validate_battle_extensions import TESTS

ROOT = Path(__file__).resolve().parents[1]
GODOT = r"C:\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
CAMPAIGN = ["city_war_loop_validation", "city_volley_validation", "campaign_operations_validation", "campaign_aftermath_validation", "campaign_route_validation", "city_validation", "map_validation", "battle_start_validation"]

def run(test):
    start = time.monotonic()
    args = [GODOT, "--path", str(ROOT), "--script", f"tests/{test}.gd"]
    # Startup instantiates real 3D models: Godot's dummy renderer rejects their
    # materials, so this check deliberately uses the actual renderer.
    if test != "battle_start_validation": args.insert(1, "--headless")
    try:
        result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=150)
        output = result.stdout + result.stderr
        row = dict(test=test, passed=result.returncode == 0 and not re.search(r"SCRIPT ERROR:|^ERROR:|_FAILED", output, re.M), exit_code=result.returncode, output=output)
    except subprocess.TimeoutExpired as exc:
        diagnostic = (exc.stdout or b"") + (exc.stderr or b"")
        if isinstance(diagnostic, bytes): diagnostic = diagnostic.decode("utf-8", errors="replace")
        row = dict(test=test, passed=False, exit_code=None, output=str(exc) + "\n" + diagnostic)
    row["elapsed_ms"] = round((time.monotonic()-start)*1000)
    print(("PASS " if row["passed"] else "FAIL ") + test, flush=True)
    if not row["passed"]: print(row["output"][-5000:], flush=True)
    return row

if __name__ == "__main__":
    # The scheduler check compares the local turn time against a delayed model
    # response. Run it without competing simulation or renderer processes.
    sensitive = [name for name in TESTS if name == "decision_scheduler_validation"]
    results = [run(name) for name in sensitive]
    parallel = [name for name in TESTS + CAMPAIGN if name not in sensitive and name != "battle_start_validation"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results.extend(pool.map(run, parallel))
    results.append(run("battle_start_validation"))
    (ROOT / "docs/validation/city-war-loop-suite-2026-10-06.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"CITY_WAR_SUITE {sum(r['passed'] for r in results)}/{len(results)}")
    raise SystemExit(0 if all(r["passed"] for r in results) else 1)
