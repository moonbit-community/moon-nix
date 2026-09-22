"""Exercise extraction, deterministic relocation, and fail-closed planning."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary, toolchain, examples = sys.argv[1:]
examples = Path(examples)


def export(root, dependencies=(), target="wasm-gc", main="example/hello/main"):
    return subprocess.run([binary, str(root), main, target, toolchain,
                           *map(str, dependencies)], capture_output=True, text=True)


original = export(examples / "hello", [examples / "support"])
assert original.returncode == 0, original.stderr
plan = json.loads(original.stdout)
expected = json.loads((examples / "wasm-plan.json").read_text())
# Wasm plans are portable between the supported hosts.
expected["platform"] = plan["platform"]
assert plan == expected
assert len(plan["actions"]) == 4
assert "/nix/store/" not in original.stdout
assert str(examples) not in original.stdout
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    shutil.copytree(examples / "hello", root / "hello with spaces")
    shutil.copytree(examples / "support", root / "support")
    relocated = export(root / "hello with spaces", [root / "support"])
    assert relocated.returncode == 0, relocated.stderr
    assert json.loads(relocated.stdout) == plan
    missing = export(root / "hello with spaces")
    assert missing.returncode != 0
    assert not missing.stdout
    unsupported = export(root / "hello with spaces", target="unknown")
    assert unsupported.returncode != 0
    project = root / "prebuild"
    project.mkdir()
    (project / "moon.mod.json").write_text(json.dumps({"name": "example/prebuild"}))
    (project / "moon.pkg.json").write_text(json.dumps({
        "is-main": True,
        "pre-build": [{"input": [], "output": ["generated.mbt"],
                       "command": "touch SHOULD_NOT_EXIST"}],
    }))
    (project / "main.mbt").write_text('fn main { println("test") }\n')
    rejected = export(project, main="example/prebuild")
    assert rejected.returncode != 0
    assert "prebuild is not supported" in rejected.stderr
    assert not (project / "SHOULD_NOT_EXIST").exists()
print("generator checks passed")
