"""Turn JourneyProbe's SavedVariables file into the Phase 0 results.

Usage (from the repository root, after a /reload or logout in game):
    python scripts/probe_report.py                      # finds the file under E:\\World of Warcraft\\_forever_
    python scripts/probe_report.py --sv path\\JourneyProbe.lua --chatlog path\\WoWChatLog.txt --out docs/investigations/phase0-probe-results.md

Each check is reported as OBSERVED (with the evidence), PARTLY OBSERVED, or NOT YET OBSERVED (with what to do in game).
Abbreviations: SV = SavedVariables. NPC = non-player character. CLEU = COMBAT_LOG_EVENT_UNFILTERED.
Lupa (Lua 5.1 in Python) reads the SV file, so the parser is the game's own file format.
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(r"E:\World of Warcraft\_forever_")


def load_db(sv_path):
    from lupa.lua51 import LuaRuntime
    runtime = LuaRuntime()
    runtime.execute(Path(sv_path).read_text(encoding="utf-8-sig"))
    return to_py(runtime.globals().JourneyProbeDB)


def to_py(value):
    """Lua table to dict/list: a table with keys 1..n becomes a list, anything else a dict."""
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    items = {k: to_py(v) for k, v in value.items()}
    if items and all(isinstance(k, int) for k in items) and set(items) == set(range(1, len(items) + 1)):
        return [items[i] for i in range(1, len(items) + 1)]
    return items


def entries(db, ev):
    return [e for e in (db.get("log") or []) if isinstance(e, dict) and e.get("ev") == ev]


def fmt_stamp(epoch, year=None):
    d = datetime.datetime.fromtimestamp(epoch)
    return f"{d.month}/{d.day} {d:%H:%M:%S}"


# ---------------------------------------------------------------------------------------------------------------------
# One function per check; each returns (status, lines)

def check1(db):
    logins = entries(db, "login")
    zones = [e for e in (db.get("log") or []) if isinstance(e, dict) and e.get("ev") == "zone"]
    lines = [f"Add-on loads counted: {db.get('loads', 0)}; login entries: {len(logins)}."]
    log = db.get("log") or []
    proven = False
    for i, e in enumerate(log):
        if isinstance(e, dict) and e.get("ev") == "login" and (e.get("previousLoads") or 0) >= 1:
            nxt = next((z for z in log[i + 1:] if isinstance(z, dict) and z.get("game") == "PLAYER_ENTERING_WORLD"), None)
            if nxt and nxt.get("isLogin"):
                proven = True
                lines.append(f"At {e.get('d')} (a full login, not a reload) the add-on found its earlier data: previousLoads = {e['previousLoads']}.")
                break
    if proven:
        return "OBSERVED: yes, SV is read back at login", lines
    if len(logins) >= 2:
        lines.append("The data survived a reload but no full logout and login has been seen yet.")
        return "PARTLY OBSERVED: reload only", lines
    return "NOT YET OBSERVED", lines + ["Log out fully, log in again, and run this report again."]


def check2(db):
    quests = [e for e in entries(db, "quest") if e.get("quest") == "QUEST_DETAIL"]
    lines = [f"QUEST_DETAIL entries: {len(quests)}. Other quest-window entries: {len(entries(db, 'quest')) - len(quests)}."]
    api = db.get("api") or {}
    lines.append("Getter functions present: " + ", ".join(f"{n}={api.get(n)}" for n in
                 ("GetTitleText", "GetGreetingText", "GetQuestText", "GetProgressText", "GetObjectiveText", "GetRewardText")))
    if not quests:
        return "NOT YET OBSERVED", lines + ["Open a quest from an NPC (do not accept it yet, or accept it; either fires QUEST_DETAIL)."]
    got_text = giver = 0
    for q in quests:
        qt = q.get("GetQuestText") or {}
        if qt.get("ok") and qt.get("len"):
            got_text += 1
        if q.get("questnpc"):
            giver += 1
    first = quests[0]
    lines.append(f"GetQuestText returned text in {got_text} of {len(quests)}; UnitName(\"questnpc\") returned a name in {giver}.")
    lines.append(f"First: title {first.get('title')!r}, giver {first.get('questnpc')!r}, text starts {((first.get('GetQuestText') or {}).get('sample'))!r}.")
    for kind in ("QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_GREETING", "GOSSIP_SHOW"):
        n = len([e for e in entries(db, "quest") if e.get("quest") == kind])
        lines.append(f"{kind}: {n} entries seen.")
    ok = got_text == len(quests) and giver == len(quests)
    return ("OBSERVED: yes, text and giver readable" if ok else "OBSERVED: partly, see counts"), lines


def check3(db):
    deaths, bosses = entries(db, "death"), entries(db, "boss")
    deathtext = {k: v for k, v in (db.get("counts") or {}).items() if k.startswith("CHAT_MSG_COMBAT_")}
    reg = (db.get("registered") or {}).get("COMBAT_LOG_EVENT_UNFILTERED")
    lines = [
        f"PLAYER_DEAD entries: {len(deaths)}; with a killer candidate from the combat log: {len([d for d in deaths if d.get('lastHit')])}.",
        f"BOSS_KILL / ENCOUNTER entries: {len(bosses)} ({', '.join(sorted({b.get('game') for b in bosses})) or 'none'}).",
        f"COMBAT_LOG_EVENT_UNFILTERED registered: {reg}; times it fired for the add-on: {db.get('cleuFired', 0)}.",
        f"Death and kill text lines counted: {sum(deathtext.values())} ({len(deathtext)} counters).",
    ]
    for d in deaths[:3]:
        lines.append(f"Death at {d.get('d')} in {d.get('zone')}: lastHit {d.get('lastHit')}, recap events {d.get('recapCount')}.")
    for b in bosses[:5]:
        lines.append(f"{b.get('d')} {b.get('game')} {b.get('name')!r} (success {b.get('success')}).")
    if not deaths and not bosses:
        return "NOT YET OBSERVED", lines + ["Die once (even to fall damage) and kill a dungeon boss."]
    if deaths and bosses:
        return "OBSERVED", lines
    return "PARTLY OBSERVED", lines + ["Still missing: " + ("a boss kill" if deaths else "a death") + "."]


def chat_table(db, kinds):
    rows = {}
    for key, n in (db.get("counts") or {}).items():
        parts = key.split("|")
        if len(parts) == 4 and parts[0].startswith(kinds):
            rows[tuple(parts)] = n
    return rows


def check4(db):
    rows = chat_table(db, ("CHAT_MSG_MONSTER", "CHAT_MSG_RAID_BOSS"))
    lines = []
    open_ok = sum(n for (ev, inst, lock, st), n in rows.items() if inst == "none" and st == "text")
    inst_ok = sum(n for (ev, inst, lock, st), n in rows.items() if inst != "none" and st == "text")
    inst_secret = sum(n for (ev, inst, lock, st), n in rows.items() if inst != "none" and st == "secret")
    lines.append(f"NPC speech readable in the open world: {open_ok} lines. In instances: {inst_ok} readable, {inst_secret} secret.")
    for (ev, inst, lock, st), n in sorted(rows.items()):
        lines.append(f"  {ev} in {inst} ({lock}), {st}: {n}")
    samples = [e for e in entries(db, "chat") if str(e.get("chat", "")).startswith(("CHAT_MSG_MONSTER", "CHAT_MSG_RAID_BOSS")) and e.get("text")]
    for s in samples[:3]:
        lines.append(f"  e.g. {s.get('chat')}: {s.get('who')!r} -> {s.get('text')!r}, guid kind {s.get('guidKind')}, who2 {s.get('who2')!r}")
    if open_ok and (inst_ok or inst_secret):
        return "OBSERVED" if inst_secret and not inst_ok else "OBSERVED: but instances were NOT all unreadable, see counts", lines
    if open_ok:
        return "PARTLY OBSERVED: open world only", lines + ["Enter a dungeon and let an NPC speak (a boss yell)."]
    return "NOT YET OBSERVED", lines + ["Stand near NPCs that speak in the open world, then in a dungeon."]


def check6(db):
    rows = chat_table(db, ("CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE", "CHAT_MSG_PARTY",
                           "CHAT_MSG_RAID", "CHAT_MSG_INSTANCE"))
    lines = []
    seen_open = {ev for (ev, inst, lock, st), n in rows.items() if inst == "none" and st == "text"}
    seen_inst = {(ev, st) for (ev, inst, lock, st), n in rows.items() if inst != "none"}
    for (ev, inst, lock, st), n in sorted(rows.items()):
        lines.append(f"  {ev} in {inst} ({lock}), {st}: {n}")
    want = {"CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE", "CHAT_MSG_PARTY"}
    lines.insert(0, f"Readable in the open world: {', '.join(sorted(seen_open)) or 'none yet'}. Still to see there: {', '.join(sorted(want - seen_open)) or 'none'}.")
    lines.insert(1, f"Seen inside instances: {', '.join(f'{e} ({s})' for e, s in sorted(seen_inst)) or 'nothing yet'}.")
    withwho = [e for e in entries(db, "chat") if e.get("whoOk") and e.get("guidKind")]
    if withwho:
        lines.append(f"Speaker name and GUID readable in the open world (e.g. {withwho[0].get('who')!r}, {withwho[0].get('guidKind')}).")
    if want <= seen_open and seen_inst:
        return "OBSERVED", lines
    if seen_open:
        return "PARTLY OBSERVED", lines + ["Say, yell, emote and party chat in the open world, then party and raid chat in a dungeon or raid."]
    return "NOT YET OBSERVED", lines


def check5(db, sv_path):
    size = Path(sv_path).stat().st_size
    n_log, n_fill = len(db.get("log") or []), len(db.get("fill") or [])
    lines = [f"SV file size now: {size / 1024:.0f} KiB with {n_log} log entries and {n_fill} filler entries.",
             f"Bytes per entry (log only, rough): {size / max(n_log + n_fill, 1):.0f}.",
             f"Entries dropped by the 30,000 cap: {db.get('dropped', 0)}."]
    if n_fill >= 20000:
        lines.append("The pause at logout is a stopwatch figure: run `/jmp fill 50000`, then log out and time the wait. Record it here by hand.")
        return "PARTLY OBSERVED: size measured, pause needs a stopwatch", lines
    return "NOT YET OBSERVED", lines + ["Run `/jmp fill 50000`, `/reload`, and time the pause; then log out and time it again."]


def parse_chatlog_stamp(line, year):
    m = re.match(r"^(\d+)/(\d+) (\d+):(\d+):(\d+)\.\d+\s", line)
    if not m:
        return None
    mo, d, h, mi, s = map(int, m.groups())
    try:
        return datetime.datetime(year, mo, d, h, mi, s).timestamp()
    except ValueError:
        return None


def check7(db, chatlog):
    zones = [e for e in entries(db, "zone") if e.get("changed")]
    lines = [f"Changes of instance type seen: {len(zones)}."]
    for z in zones:
        lines.append(f"  {z.get('d')}: now {z.get('inst')} ({z.get('instName') or z.get('zone')}), via {z.get('game')}")
    enters = [i for i, z in enumerate(zones) if z.get("inst") not in ("none", "?")]
    left = any(z.get("inst") == "none" for z in zones[enters[0] + 1:]) if enters else False
    if not enters:
        return "NOT YET OBSERVED", lines + ["Enter and leave a dungeon."]
    if not left:
        lines.append("Entry seen, but no exit yet: leave the dungeon and `/reload`.")
    if not chatlog or not Path(chatlog).exists():
        return "PARTLY OBSERVED: no chat log to compare", lines
    year = datetime.date.today().year
    stamps = []
    with open(chatlog, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if " RPM" in line[:30]:
                continue
            ts = parse_chatlog_stamp(line, year)
            if ts:
                stamps.append((ts, line.rstrip()[:110]))
    for z in zones:
        t = z.get("t")
        nearest = min(stamps, key=lambda s: abs(s[0] - t)) if stamps else None
        if nearest:
            lines.append(f"  Nearest chat-log line to {z.get('d')}: {nearest[0] - t:+.0f} s -> {nearest[1]}")
    lines.append("The chat log is only flushed at logout or exit, so run this after logging out. Check by eye that the lines nearest an entry or exit are zone-in messages, party chat or kills of that dungeon.")
    if not left:
        return "PARTLY OBSERVED: entry only", lines
    return "OBSERVED (read the offsets above)", lines


def check8(chatlog):
    if not chatlog or not Path(chatlog).exists():
        return "NOT YET OBSERVED", ["No chat log file found."]
    first = last = None
    raid = 0
    with open(chatlog, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if first is None and re.match(r"^\d+/\d+ ", line):
                first = line[:24]
            if re.match(r"^\d+/\d+ ", line):
                last = line[:24]
            if "channel:RAID" in line or "channel:INSTANCE" in line:
                raid += 1
    size = Path(chatlog).stat().st_size
    lines = [f"File size {size / 1e6:.1f} MB; first line {first!r}; last line {last!r}.",
             "Baseline on 12 November 2026: first line 11/4 23:20, so it was not emptied by sessions between 4 and 12 November (see dungeon-run-in-chat-log.md).",
             f"Raid or instance-channel lines in the file: {raid}."]
    if raid:
        return "OBSERVED: raid chat is in the file", lines
    return "PARTLY OBSERVED: file persists across sessions; no raid yet", lines + ["Run a raid (or a group raid) with chat logging on, then re-run."]


def check10(db):
    res = db.get("minimapResult") or {}
    lines = [f"Created: {res.get('created')}; error: {res.get('err')}; shape: {res.get('shape')}; saved angle now: {db.get('minimapAngle')}."]
    if res.get("created") is None:
        return "NOT YET OBSERVED", lines
    if not res.get("created"):
        return "OBSERVED: creation FAILED", lines
    if db.get("minimapAngle") is not None and len(entries(db, "login")) >= 2:
        return "OBSERVED: created, dragged, angle survived a reload", lines
    return "PARTLY OBSERVED: created", lines + ["Drag the button, `/reload`, and check it stays put; then run the report again."]


def report(db, sv_path, chatlog):
    api = db.get("api") or {}
    lines = ["# JourneyProbe results", "",
             f"Generated: {datetime.datetime.now():%Y-%m-%d %H:%M}. Client build: " +
             next((f"{e.get('version')} ({e.get('build')}), interface {e.get('toc')}" for e in entries(db, "login")), "unknown") + ".",
             f"Source: `{sv_path}`; chat log: `{chatlog}`.", ""]
    results = [
        ("1. SV read back at login", check1(db)),
        ("2. Quest text getters and giver", check2(db)),
        ("3. Death and boss events, killer name", check3(db)),
        ("4. NPC speech in the open world and in dungeons", check4(db)),
        ("5. SV size and logout pause", check5(db, sv_path)),
        ("6. Player chat readability", check6(db)),
        ("7. Entering and leaving a dungeon against the chat log", check7(db, chatlog)),
        ("8. Chat log persistence and raids", check8(chatlog)),
        ("10. Hand-built minimap button", check10(db)),
    ]
    lines.append("| Check | Status |")
    lines.append("| --- | --- |")
    for title, (status, _) in results:
        lines.append(f"| {title} | {status} |")
    lines.append("")
    for title, (status, detail) in results:
        lines += [f"## {title}", "", f"**{status}**", ""] + detail + [""]
    lines += ["## Functions present or missing", "", ", ".join(f"`{k}`: {v}" for k, v in sorted(api.items())), ""]
    return "\n".join(lines)


def find_sv():
    hits = sorted(DEFAULT_ROOT.glob("WTF/Account/*/SavedVariables/JourneyProbe.lua"))
    return hits[0] if hits else None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sv")
    ap.add_argument("--chatlog", default=str(DEFAULT_ROOT / "Logs" / "WoWChatLog.txt"))
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    sv = Path(args.sv) if args.sv else find_sv()
    if not sv or not sv.exists():
        print("JourneyProbe.lua not found. Copy src/JourneyProbe into Interface/AddOns, play, then /reload or log out.", file=sys.stderr)
        return 1
    text = report(load_db(sv), sv, args.chatlog)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"Wrote {args.out}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
