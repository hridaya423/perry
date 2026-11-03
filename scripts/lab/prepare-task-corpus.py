import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Prepare 30 tasks with three isolated repetitions. No app actions are performed.")
    parser.add_argument("--product", choices=["perry", "heyclicky"], required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[2]
    corpus_path = repository / "scripts/fixtures/dependable-task-corpus.json"
    corpus = json.loads(corpus_path.read_text())
    tasks = corpus["tasks"]
    identifiers = [task["id"] for task in tasks]
    if len(tasks) < 30 or len(set(identifiers)) != len(tasks):
        raise ValueError("The corpus needs at least 30 uniquely identified tasks.")
    source = repository / corpus["fixture_root"]
    for task in tasks:
        fixture = (source / task["fixture"]).resolve()
        if not fixture.is_relative_to(source.resolve()) or not fixture.exists():
            raise ValueError(f"Missing or invalid fixture for {task['id']}")
    inputs = {
        str(path.relative_to(source)): digest(path)
        for path in sorted(source.rglob("*")) if path.is_file()
    }
    parent = repository / "build/dependable-trials"
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix=f"{args.product}-", dir=parent))
    trials = []
    for task in tasks:
        for repetition in range(1, corpus["repetitions_per_product"] + 1):
            trial = root / task["id"] / str(repetition)
            shutil.copytree(source, trial / "input")
            (trial / "output").mkdir()
            trials.append({
                "task_id": task["id"],
                "repetition": repetition,
                "input": str((trial / "input").relative_to(root)),
                "output": str((trial / "output").relative_to(root)),
                "status": "not_run",
                "total_time_ms": None,
                "acknowledgement_ms": None,
                "first_substantive_answer_ms": None,
                "interventions": None,
                "unapproved_effects": None,
                "false_success_claims": None,
                "duplicate_effects": None,
                "input_recovered_after_failure": None,
                "evidence": [],
                "notes": "",
            })
    results = {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "product": args.product,
        "product_version": None,
        "binary_sha256": None,
        "provider_configuration": None,
        "permissions": None,
        "account_readiness": None,
        "os_version": platform.mac_ver()[0],
        "architecture": platform.machine(),
        "source_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip(),
        "working_tree_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=repository, text=True).strip()),
        "corpus_sha256": digest(corpus_path),
        "input_sha256": inputs,
        "trials": trials,
    }
    shutil.copy2(corpus_path, root / "corpus.json")
    (root / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(root)


if __name__ == "__main__":
    main()
