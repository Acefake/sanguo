"""Run independent battle validations and retain real exit/error evidence."""
import argparse
import concurrent.futures
import json
import re
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TESTS = [
    "terrain_battle_validation", "formation_validation", "duel_validation",
    "battle_feedback_validation", "tactical_battlefield_validation",
    "encirclement_validation", "corps_validation", "siege_corps_validation",
    "battle_discipline_validation", "decision_scheduler_validation",
    "global_battle_grid_validation", "officer_battle_validation",
    "officer_command_validation", "officer_edges_validation",
    "xiaopei_battle_validation", "war_validation", "war_orders_validation",
    "orders_dissent_validation", "strategic_ai_validation",
    "battle_balance_validation", "combat_effects_validation",
    "dispatch_view_validation", "war_turn_time_validation",
]

def run(test, godot):
    start = time.monotonic()
    try:
        result = subprocess.run(
            [godot, "--headless", "--path", str(ROOT), "--script", f"tests/{test}.gd"],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
            errors="replace", timeout=60,
        )
        output = result.stdout + result.stderr
        passed = result.returncode == 0 and not re.search(r"SCRIPT ERROR:|^ERROR:|_FAILED", output, re.M)
        row = dict(test=test, passed=passed, exit_code=result.returncode, output=output)
    except subprocess.TimeoutExpired as exc:
        row = dict(test=test, passed=False, exit_code=None, output="Own test process timed out: " + str(exc))
    row["elapsed_ms"] = round((time.monotonic() - start) * 1000)
    return row

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", required=True)
    args = parser.parse_args()
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(lambda test: run(test, args.godot), TESTS))
    for row in results:
        print(("PASS " if row["passed"] else "FAIL ") + row["test"])
        if not row["passed"]:
            print(row["output"][-5000:])
    destination = ROOT / "docs/validation/battle-extension-tests.json"
    destination.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"BATTLE_EXTENSION_SUITE {sum(row['passed'] for row in results)}/{len(results)}")
    return 0 if all(row["passed"] for row in results) else 1

if __name__ == "__main__":
    raise SystemExit(main())
