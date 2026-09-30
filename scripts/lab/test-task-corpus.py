import hashlib
import json
import subprocess
import sys
from pathlib import Path


repository = Path(__file__).resolve().parents[2]
root = Path(subprocess.check_output(
    [sys.executable, str(repository / "scripts/lab/prepare-task-corpus.py"), "--product", "perry"],
    text=True,
).strip())
results = json.loads((root / "results.json").read_text())
trials = results["trials"]
assert len(trials) == 90
assert len({trial["task_id"] for trial in trials}) == 30
assert all(trial["status"] == "not_run" for trial in trials)
for trial in trials:
    for name, expected in results["input_sha256"].items():
        assert hashlib.sha256((root / trial["input"] / name).read_bytes()).hexdigest() == expected
name = "finder/inbox/draft-a.txt"
first = root / trials[0]["input"] / name
second = root / trials[1]["input"] / name
original = second.read_bytes()
first.write_text("Changed during isolation test.\n")
assert second.read_bytes() == original
assert (repository / "scripts/fixtures/dependable" / name).read_bytes() == original
print(f"90 trials verified; editing one leaves the others and source intact. Test output: {root}")
