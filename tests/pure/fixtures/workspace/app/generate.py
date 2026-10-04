import sys
from pathlib import Path
n=int(Path(sys.argv[1]).read_text())
Path(sys.argv[2]).write_text(f"fn generated() -> Int {{ {n} }}\n")
