"""Size probe for JourneyMaster's JournalSnapshot.lua: can the game load a much bigger snapshot?

The app writes every text as a Lua string with each UTF-8 byte as a three-digit escape (\\ddd), so a file is about four
times as large as the text in it. This script builds a throwaway add-on, JourneySizeProbe, whose data files hold texts
of growing size in that same format, so the game's limits show before JournalSnapshot.lua is allowed to grow.

Usage (from the repository root):
    python scripts/size_probe.py deploy [--levels 016K,040K] [--addons PATH]   # build the add-on in the game folder
    python scripts/size_probe.py report [--sv PATH] [--out FILE]               # read the result after /reload or logout
    python scripts/size_probe.py remove [--addons PATH]                        # delete the add-on again

In the game: run /console scriptErrors 1 first, so a file the game cannot read shows its error. Log in, read the chat
lines, then /jmsize show <name> for each level in turn, smallest first (a large text may freeze the game for a while).
Then /reload and run the report.

Abbreviations: SV = SavedVariables. KB = 1,024 bytes. Lupa = Lua 5.1 in Python (development only), which reads the SV file.
"""
import argparse
import shutil
import sys
from pathlib import Path

ADDON = "JourneySizeProbe"
DEFAULT_ROOT = Path(r"E:\World of Warcraft\_forever_")
SOURCE_DIR = Path(__file__).resolve().parent.parent / "src" / ADDON

# Level name -> bytes of text. 016K is today's limit for a session summary and 040K today's limit for the overview
# (Get-SnapshotText in src/App/JourneyMasterApp.psm1). The app refuses a snapshot file over 4 MiB, so 1M of text
# (a file of about 4 MB) is the largest the app could write today; 2M goes beyond it to find the game's own limit.
LEVELS = [("016K", 16_000), ("040K", 40_000), ("100K", 100_000), ("250K", 250_000),
          ("500K", 500_000), ("1M", 1_000_000), ("2M", 2_000_000)]

TOC = """## Interface: 16001
## Title: JourneySizeProbe
## Notes: Throwaway probe for JourneyMaster. Holds texts of growing size to find the largest the game reads. Delete it after the check.
## Author: Shane Hou
## Category: Utility
## Version: 0.1.0
## SavedVariables: JourneySizeProbeDB

"""

# Sentences with accents, dashes and curly quotes, so the text has multi-byte UTF-8 characters, as real summaries do.
SENTENCES = [
    "The road wound down through Goldshire, and \u201cKeep walking,\u201d the hero told herself \u2014 the night was young.",
    "At the edge of the Stonetalon Mountains, a caf\u00e9 of sorts stood empty; nobody had lit the lamps.",
    "She counted forty-three coins, then forty-two, and wondered whether the d\u00e9j\u00e0 vu was the cold or the ale.",
    "A murloc fled into the reeds. The hero let it go, and the river kept its own counsel.",
    "Level {n} came quietly, between one breath and the next, and the hills seemed a little closer for it.",
    "The dungeon door groaned open on a smell of wet stone, old iron and something far worse.",
    "Behind her the lanterns of the camp shrank to sparks, and the wind carried the sound of a distant bell.",
    "He wrote nothing down; the story would keep, he decided, as stories do for those who walk long enough.",
]


def make_text(name, size):
    """Deterministic prose of about `size` bytes of UTF-8, ending with a marker line that shows the end arrived."""
    end = f"\n\n[END MARKER {name}: the whole text arrived.]"
    limit = size - len(end.encode("utf-8"))
    parts, used, i = [], 0, 0
    while used < limit:
        sentence = SENTENCES[(i * 3 + i // 8) % len(SENTENCES)].format(n=i % 60 + 1)
        piece = sentence + ("\n\n" if i % 6 == 5 else " ")
        parts.append(piece)
        used += len(piece.encode("utf-8"))
        i += 1
    return "".join(parts).rstrip() + end


def checksum(data):
    """The same position-weighted checksum as ns.Checksum in src/JourneySizeProbe/Report.lua."""
    return sum(b * (i % 251 + 1) for i, b in enumerate(data)) % 65521


_ESC = [f"\\{i:03d}" for i in range(256)]


def lua_string(data):
    """A Lua string literal with every byte as a three-digit decimal escape, as the app's ConvertTo-LuaString writes it."""
    return '"' + "".join(map(_ESC.__getitem__, data)) + '"'


def build(target, levels):
    """Writes the add-on into `target`: the two fixed files, a manifest, one data file per level and the TOC."""
    target.mkdir(parents=True, exist_ok=True)
    for name in ("Start.lua", "Report.lua"):
        shutil.copyfile(SOURCE_DIR / name, target / name)
    files, manifest = [], []
    for name, size in levels:
        data = make_text(name, size).encode("utf-8")
        source = f'local _, ns = ...\nns.Stamp("{name}")\nns.text["{name}"] = {lua_string(data)}\n'.encode("ascii")
        (target / f"Data_{name}.lua").write_bytes(source)
        files.append(f"Data_{name}.lua")
        manifest.append(f'    {{ name = "{name}", textBytes = {len(data)}, sourceBytes = {len(source)}, sum = {checksum(data)} }},')
    (target / "Manifest.lua").write_text(
        'local _, ns = ...\nns.Stamp("manifest")\nns.expected = {\n' + "\n".join(manifest) + "\n}\n", encoding="ascii")
    toc_files = ["Start.lua", "Manifest.lua"] + files + ["Report.lua"]
    (target / f"{ADDON}.toc").write_text(TOC + "\n".join(toc_files) + "\n", encoding="ascii")
    return files


def parse_levels(text):
    known = dict(LEVELS)
    if not text:
        return LEVELS
    wanted = [t.strip() for t in text.split(",") if t.strip()]
    bad = [w for w in wanted if w not in known]
    if bad:
        sys.exit(f"Unknown level(s) {', '.join(bad)}. Known: {', '.join(known)}")
    return [(w, known[w]) for w in wanted]


# ---------------------------------------------------------------------------------------------------------------------
# The report

def to_py(value):
    """Lua table to dict/list: a table with keys 1..n becomes a list, anything else a dict."""
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    items = {k: to_py(v) for k, v in value.items()}
    if items and all(isinstance(k, int) for k in items) and set(items) == set(range(1, len(items) + 1)):
        return [items[i] for i in range(1, len(items) + 1)]
    return items


def load_db(sv_path):
    from lupa.lua51 import LuaRuntime
    runtime = LuaRuntime()
    runtime.execute(Path(sv_path).read_text(encoding="utf-8-sig"))
    return to_py(runtime.globals().JourneySizeProbeDB)


def find_sv():
    hits = sorted(DEFAULT_ROOT.glob(f"WTF/Account/*/SavedVariables/{ADDON}.lua"))
    return hits[0] if hits else None


def render(db):
    levels = db.get("levels") or []
    display = {d.get("name"): d for d in (db.get("display") or []) if isinstance(d, dict)}
    build_info = db.get("build") or {}
    memory = db.get("addonMemKB") or db.get("memEndKB") or 0
    lines = ["# JourneySizeProbe results", "",
             f"Game build {build_info.get('version')} ({build_info.get('build')}). "
             f"All files read in {db.get('totalLoadMs') or 0:.0f} ms; the add-on holds {memory:,.0f} KB of memory.",
             "", "| Level | Text bytes | File bytes | Loaded | Intact | Read in (ms) | Drawn in a window | Height (px) | SetText (ms) |",
             "|---|---|---|---|---|---|---|---|---|"]
    best_loaded = best_drawn = None
    for r in levels:
        loaded = bool(r.get("loaded"))
        intact = loaded and bool(r.get("lenOk")) and bool(r.get("sumOk"))
        d = display.get(r.get("name"))
        if intact:
            best_loaded = r["name"]
        drawn = "not tried"
        if d:
            drawn = "yes" if d.get("ok") and d.get("gotOk") else ("changed" if d.get("ok") else f"FAILED: {d.get('err')}")
            if drawn == "yes":
                best_drawn = r["name"]
        lines.append("| {} | {:,} | {:,} | {} | {} | {} | {} | {} | {} |".format(
            r.get("name"), r.get("expectedBytes") or 0, r.get("sourceBytes") or 0,
            "yes" if loaded else "NO", ("yes" if intact else "NO") if loaded else "-",
            f"{r['parseMs']:.0f}" if r.get("parseMs") is not None else "?", drawn,
            f"{d['height']:.0f}" if d and d.get("height") else "-",
            f"{d['setTextMs']:.0f}" if d and d.get("setTextMs") is not None else "-"))
    lines += ["", f"Largest level that loaded intact: {best_loaded or 'none'}.",
              f"Largest level drawn whole in a window: {best_drawn or 'none tried'}.",
              "", "A level that did not load, or arrived changed, marks the game's limit. Its error, if any, shows with /console scriptErrors 1.",
              "The window test also needs a look: scroll to the end and check the END MARKER line is there."]
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("deploy")
    d.add_argument("--levels")
    d.add_argument("--addons", default=str(DEFAULT_ROOT / "Interface" / "AddOns"))
    r = sub.add_parser("remove")
    r.add_argument("--addons", default=str(DEFAULT_ROOT / "Interface" / "AddOns"))
    rp = sub.add_parser("report")
    rp.add_argument("--sv")
    rp.add_argument("--out")
    args = ap.parse_args(argv)
    if args.cmd == "deploy":
        target = Path(args.addons) / ADDON
        files = build(target, parse_levels(args.levels))
        total = sum((target / f).stat().st_size for f in files)
        print(f"Built {target} with {len(files)} data files, {total:,} bytes of data. Start the game, or /reload.")
    elif args.cmd == "remove":
        target = Path(args.addons) / ADDON
        if target.exists():
            shutil.rmtree(target)
            print(f"Removed {target}")
        else:
            print(f"Nothing to remove at {target}")
    else:
        sv = Path(args.sv) if args.sv else find_sv()
        if not sv or not sv.exists():
            sys.exit(f"No {ADDON}.lua found under {DEFAULT_ROOT}\\WTF. Log in once, then /reload or log out, or pass --sv.")
        text = render(load_db(sv))
        if args.out:
            Path(args.out).write_text(text, encoding="utf-8")
            print(f"Wrote {args.out}")
        else:
            print(text)


if __name__ == "__main__":
    main()
