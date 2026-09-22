"""Execute one exported MoonBit action inside its Nix derivation."""
import json
import os
from pathlib import Path
import subprocess
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    config = json.load(stream)
action = config["action"]
substitutions = config["substitutions"]
substitutions["@build@"] = os.environ["out"]
# Replace complete dependency artifacts before the generic output directory.
keys = sorted(substitutions, key=len, reverse=True)


def resolve(value):
    # One pass: replacement strings must not be rewritten by another token.
    import re
    pattern = "|".join(re.escape(key) for key in keys)
    result = re.sub(pattern, lambda match: substitutions[match.group()], value)
    if "@src" in result or "@toolchain@" in result or "@build@" in result:
        raise ValueError(f"unresolved plan path: {result}")
    return result


for output in action["outputs"]:
    Path(resolve(output)).parent.mkdir(parents=True, exist_ok=True)
listing = {"packages": [dict(entry, artifact=resolve(entry["artifact"]))
                        for entry in config["packages"]]}
Path(os.environ["out"]).mkdir(parents=True, exist_ok=True)
Path(os.environ["out"], "all_pkgs.json").write_text(json.dumps(listing))
command = action["command"]
argv = [resolve(argument) for argument in command["argv"]]
cwd = resolve(command["cwd"]) if command.get("cwd") else None
if command["kind"] == "exec":
    subprocess.run(argv, cwd=cwd, check=True)
elif command["kind"] == "exec-to":
    with open(resolve(command["stdout"]), "wb") as stream:
        subprocess.run(argv, stdout=stream, check=True)
else:
    raise ValueError(f"unsupported command kind: {command['kind']}")
for output in action["outputs"]:
    if not Path(resolve(output)).is_file():
        raise RuntimeError(f"action did not produce declared output: {output}")
