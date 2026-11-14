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
-- A stand-in for the game's widgets. Like the real game (seen on 14 November 2026), a font string keeps at most
-- 29,997 bytes of the text it is given. SCROLL_RANGE and CHILD_KEPT are what the tests want the scroll area to report.
SCROLL_RANGE, CHILD_KEPT = 1e9, nil
local function widget()
    local w = {}
    return setmetatable(w, { __index = function(t, k)
        if k == "GetStringHeight" then return function() return 100 end end
        if k == "SetText" then return function(self, s) rawset(self, "text", #s > 29997 and s:sub(1, 29997) or s) end end
        if k == "GetText" then return function(self) return rawget(self, "text") end end
        if k == "SetHeight" then return function(self, h) rawset(self, "h", CHILD_KEPT or h) end end
        if k == "GetHeight" then return function(self) return rawget(self, "h") or 400 end end
        if k == "GetVerticalScrollRange" then return function() return SCROLL_RANGE end end
        return function() return widget() end
    end })
end
UIParent = widget()
UISpecialFrames = {}
SlashCmdList = {}
CreateFrame = function() return widget() end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
"""


def loaded_with_frames(names=("016K", "040K")):
    folder = Path(tempfile.mkdtemp()) / "JourneySizeProbe"
    size_probe.build(folder, [l for l in SMALL if l[0] in names])
    runtime = LuaRuntime()
    runtime.execute(STUBS + FRAME_STUBS)
    ns = runtime.eval("{}")
    load = runtime.eval(LOADER)
    for name in ["Start.lua", "Manifest.lua"] + [f"Data_{n}.lua" for n in names] + ["Report.lua"]:
        load((folder / name).read_text(encoding="ascii"), name, ns)
    ns.Run()
    return runtime, ns


def test_one_font_string_test_records_a_cut():
    runtime, ns = loaded_with_frames()
    small = size_probe.to_py(ns.ShowTest("016K"))
    big = size_probe.to_py(ns.ShowTest("040K"))
    assert small["ok"] and small["gotOk"]
    assert big["ok"] and not big["gotOk"] and big["gotLen"] == 29997
    text = size_probe.render(size_probe.to_py(ns.db))
    assert "| whole |" in text and "CUT to 29,997 bytes" in text
    assert "Largest level kept whole in one font string: 016K" in text
    assert ns.ShowTest("nope") is None


def test_paragraph_test_records_height_and_reach():
    runtime, ns = loaded_with_frames()
    r = size_probe.to_py(ns.BlocksTest("040K"))
    assert r["ok"] and r["changed"] == 0 and r["paragraphs"] > 20 and r["lastHasMarker"]
    assert r["reach"] is True and r["childHeight"] == r["height"] + 10
    text = size_probe.render(size_probe.to_py(ns.db))
    assert "whole, end reachable" in text
    assert "Largest level kept whole as stacked paragraphs, with the end reachable: 040K" in text


def test_paragraph_test_notices_a_clamped_height():
    runtime, ns = loaded_with_frames()
    runtime.globals().SCROLL_RANGE = 500   # the area scrolls far less than the stacked height
    runtime.globals().CHILD_KEPT = 4000    # and the game kept only part of the height
    r = size_probe.to_py(ns.BlocksTest("040K"))
    assert r["reach"] is False and r["childHeight"] == 4000
    text = size_probe.render(size_probe.to_py(ns.db))
    assert "END NOT REACHABLE" in text
    assert "with the end reachable: none." in text


def main():
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("size probe tests passed")


if __name__ == "__main__":
    main()
