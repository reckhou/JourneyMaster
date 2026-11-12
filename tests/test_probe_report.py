"""End to end, offline: run the probe under Lua with stub game functions, write its table as an SV file, report on it."""
import sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from lupa.lua51 import LuaRuntime
import probe_report

STUBS = """
time, date = os.time, os.date
inInstance, instType = false, 'none'
IsInInstance = function() return inInstance, instType end
C_ChatInfo = { InChatMessagingLockdown = function() return inInstance end }
GetRealZoneText = function() return 'Elwynn Forest' end
GetSubZoneText = function() return 'Goldshire' end
GetTitleText = function() return 'A Fine Quest' end
GetQuestText = function() return 'Bring me three boars.' end
UnitName = function(u) return u == 'questnpc' and 'Marshal Dughan' or nil end
UnitGUID = function() return 'Player-1-AAA' end
issecretvalue = function(v) return v == 'hidden' end
LoggingChat = function() return true end
GetBuildInfo = function() return '1.60.1', '70532', 'x', 16001 end
"""

def serialise(v):
    if isinstance(v, dict):
        return "{" + ",".join(f"[{serialise(k)}]={serialise(x)}" for k, x in v.items()) + "}"
    if isinstance(v, list):
        return "{" + ",".join(serialise(x) for x in v) + "}"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return repr(v)

def run_session():
    lua = LuaRuntime()
    lua.execute(STUBS)
    lua.execute(Path("src/JourneyProbe/JourneyProbe.lua").read_text(encoding="utf-8"))
    lua.execute("""
        local P = JourneyProbe
        P.OnLogin()
        P.OnEvent(nil, 'PLAYER_ENTERING_WORLD', true, false)
        P.chatSet = { CHAT_MSG_SAY = 'chat', CHAT_MSG_MONSTER_YELL = 'chat' }
        P.OnEvent(nil, 'CHAT_MSG_SAY', 'hi', 'Alice', '', '', '', '', 0, 0, '', 0, 1, 'Player-1-B')
        P.OnEvent(nil, 'CHAT_MSG_MONSTER_YELL', 'None may challenge us', 'Edwin', '', '', '', '', 0, 0, '', 0, 1, 'Creature-0-1')
        P.OnEvent(nil, 'QUEST_DETAIL')
        P.OnEvent(nil, 'PLAYER_DEAD')
        inInstance, instType = true, 'party'
        P.OnEvent(nil, 'PLAYER_ENTERING_WORLD', false, false)
        P.OnEvent(nil, 'CHAT_MSG_MONSTER_YELL', 'hidden', 'hidden', '', '', '', '', 0, 0, '', 0, 1, 'hidden')
        P.OnEvent(nil, 'BOSS_KILL', 639, 'Edwin VanCleef', 1, 5)
    """)
    return lua.globals().JourneyProbeDB

def main():
    db = run_session()
    py = probe_report.to_py(db)
    with tempfile.TemporaryDirectory() as tmp:
        sv = Path(tmp) / "JourneyProbe.lua"
        sv.write_text("JourneyProbeDB = " + serialise(py), encoding="utf-8")
        loaded = probe_report.load_db(sv)
        text = probe_report.report(loaded, sv, None)
    assert "OBSERVED: yes, text and giver readable" in text, text
    assert "NOT YET OBSERVED" in text            # check 1 has only one login, check 5 has no filler
    assert "OBSERVED: partly" not in text.split("## 2.")[0]
    assert "BOSS_KILL" in text and "Edwin VanCleef" in text
    assert "Marshal Dughan" in text
    assert "secret" in text                      # lockdown yell counted as secret
    print("probe report test passed")

if __name__ == "__main__":
    main()
