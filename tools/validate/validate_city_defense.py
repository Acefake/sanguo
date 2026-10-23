"""Run city-defense regressions without unrelated campaign autoloads.

Usage: python tools/validate/validate_city_defense.py [godot executable]
"""
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    engine = sys.argv[1] if len(sys.argv) > 1 else "godot"
    cases = {
        "city_defense_separation_validation": "CITY_DEFENSE_SEPARATION_OK",
        "city_defense_edge_validation": "CITY_DEFENSE_EDGES_OK",
    }
    with tempfile.TemporaryDirectory(prefix="sanguo-city-defense-") as directory:
        project = Path(directory)
        (project / "project.godot").write_text("config_version=5\n")
        for folder in ("scripts", "data", "assets", "tests"):
            (project / folder).symlink_to(root / folder, target_is_directory=True)
        for case, marker in cases.items():
            result = subprocess.run(
                [engine, "--headless", "--path", str(project), "--script",
                 f"res://tests/war/battle/{case}.gd"],
                capture_output=True, text=True, timeout=30,
            )
            output = result.stdout + result.stderr
            print(output, end="")
            if result.returncode or marker not in output or "ERROR:" in output:
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
