"""Run the offline Lua 5.1 harnesses in tests/ (Lupa is a development-only dependency)."""
from pathlib import Path
import sys
from lupa.lua51 import LuaRuntime

paths = sys.argv[1:] or [str(p) for p in sorted(Path("tests").glob("*_harness.lua"))]
for path in paths:
    print("RUN", path, flush=True)
    runtime = LuaRuntime()
    runtime.globals().print = lambda *parts: print(*parts, flush=True)
    runtime.execute(Path(path).read_text(encoding="utf-8-sig"))
print(f"All {len(paths)} Lua 5.1 harnesses passed")
