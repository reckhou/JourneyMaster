"""Offline end to end: build the size probe, load it under Lua 5.1 with stub game functions, check what it reports."""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from lupa.lua51 import LuaRuntime
import size_probe

STUBS = """
local clock = 0
debugprofilestop = function() clock = clock + 2.5 return clock end
GetBuildInfo = function() return '1.60.1', '70532', 'x', 16001 end
"""
LOADER = "function(src, name, ns) local f = assert(loadstring(src, '@' .. name)); return f('JourneySizeProbe', ns) end"
SMALL = [("016K", 16_000), ("040K", 40_000)]


def run_addon(folder, files):
    """Loads the named files in order, as the game does, all sharing one add-on table. Returns that table."""
    runtime = LuaRuntime()
    runtime.execute(STUBS)
    ns = runtime.eval("{}")
    load = runtime.eval(LOADER)
    for name in files:
        load((folder / name).read_text(encoding="ascii"), name, ns)
    return ns


def test_levels_load_intact_and_report():
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp) / "JourneySizeProbe"
        files = size_probe.build(folder, SMALL)
        order = [l for l in (folder / "JourneySizeProbe.toc").read_text().splitlines() if l.endswith(".lua")]
        assert order == ["Start.lua", "Manifest.lua"] + files + ["Report.lua"]
        db = size_probe.to_py(run_addon(folder, order).Run())
        assert [l["name"] for l in db["levels"]] == ["016K", "040K"]
        for level in db["levels"]:
            assert level["loaded"] and level["lenOk"] and level["sumOk"], level
            assert level["parseMs"] > 0
        assert "Largest level that loaded intact: 040K" in size_probe.render(db)


def test_a_changed_byte_is_caught():
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp) / "JourneySizeProbe"
        size_probe.build(folder, SMALL)
        path = folder / "Data_040K.lua"
        path.write_text(path.read_text(encoding="ascii").replace("\\065", "\\066", 1), encoding="ascii")
        ns = run_addon(folder, ["Start.lua", "Manifest.lua", "Data_016K.lua", "Data_040K.lua", "Report.lua"])
        bad = size_probe.to_py(ns.Run())["levels"][1]
        assert bad["lenOk"] and not bad["sumOk"]


def test_a_missing_file_reads_as_not_loaded():
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp) / "JourneySizeProbe"
        size_probe.build(folder, SMALL)
        db = size_probe.to_py(run_addon(folder, ["Start.lua", "Manifest.lua", "Data_016K.lua", "Report.lua"]).Run())
        assert db["levels"][0]["loaded"] and not db["levels"][1]["loaded"]
        assert "Largest level that loaded intact: 016K" in size_probe.render(db)


def test_text_has_multibyte_characters_and_the_end_marker():
    for name, size in size_probe.LEVELS[:3]:
        data = size_probe.make_text(name, size).encode("utf-8")
        assert size - 200 < len(data) <= size + 200
        assert data.decode("utf-8").endswith(f"[END MARKER {name}: the whole text arrived.]")
        assert len(data) > len(data.decode("utf-8"))


def test_file_is_about_four_times_the_text():
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp) / "JourneySizeProbe"
        size_probe.build(folder, [("016K", 16_000)])
        size = (folder / "Data_016K.lua").stat().st_size
        assert 4 * 16_000 - 400 < size < 4 * 16_000 + 400


FRAME_STUBS = """
local function widget()
    local w = {}
    return setmetatable(w, { __index = function(t, k)
        if k == "GetStringHeight" then return function() return 1234 end end
        if k == "SetText" then return function(self, s) self.text = s end end
        if k == "GetText" then return function(self) return self.text end end
        return function() return widget() end
    end })
end
UIParent = widget()
UISpecialFrames = {}
SlashCmdList = {}
CreateFrame = function() return widget() end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
"""


def test_the_window_test_draws_a_level_and_records_it():
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp) / "JourneySizeProbe"
        size_probe.build(folder, SMALL)
        runtime = LuaRuntime()
        runtime.execute(STUBS + FRAME_STUBS)
        ns = runtime.eval("{}")
        load = runtime.eval(LOADER)
        for name in ["Start.lua", "Manifest.lua", "Data_016K.lua", "Data_040K.lua", "Report.lua"]:
            load((folder / name).read_text(encoding="ascii"), name, ns)
        ns.Run()
        record = size_probe.to_py(ns.ShowTest("040K"))
        assert record["ok"] and record["gotOk"] and record["height"] == 1234
        db = size_probe.to_py(ns.db)
        assert db["display"][0]["name"] == "040K"
        assert "| yes | 1234 |" in size_probe.render(db)
        assert ns.ShowTest("nope") is None


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("size probe tests passed")


if __name__ == "__main__":
    main()
