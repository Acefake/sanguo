"""Regression checks for troop roles, commander policy, movement and siege."""
import concurrent.futures
import json
from validate_battle_extensions import ROOT, run

TESTS = ["terrain_battle_validation", "formation_validation", "tactical_battlefield_validation",
         "corps_validation", "siege_corps_validation", "commander_policy_validation",
         "policy_scoring_validation", "war_orders_validation",
         "model_gate_validation", "orders_dissent_validation", "battle_feedback_validation"]

if __name__ == "__main__":
    import sys
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(lambda test: run(test,sys.argv[1]),TESTS))
    results.append(run("decision_scheduler_validation",sys.argv[1]))
    (ROOT/"docs/validation/mixed-battle-regression-2026-10-06.json").write_text(
        json.dumps(results,ensure_ascii=False,indent=2),encoding="utf-8")
    for row in results:
        print(("PASS " if row["passed"] else "FAIL ")+row["test"],flush=True)
        if not row["passed"]: print(row["output"][-2500:],flush=True)
    print("MIXED_BATTLE_REGRESSION",sum(row["passed"] for row in results),"/",len(results))
    sys.exit(0 if all(row["passed"] for row in results) else 1)
