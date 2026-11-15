#!/usr/bin/env python3
"""Export JourneyMaster's summarised sessions, and each character's overview, to PDF (Portable Document Format).

What is exported, per character (a folder under data\\journeys\\):
  - every session that has a summary and is not deleted: sessions\\<date>-<n>.md, with its pictures;
  - the overview, ONCE per character: overview.md, with its pictures.
Sessions that were deleted in the game are not exported: the app moves their files to deleted\\session-<n>\\, and
the app's state file lists them too. A session with no summary yet has no file in sessions\\, so it is not exported.

Output: "<out>\\<Character Name>\\<date>-<n> - <title>.pdf" and "<out>\\<Character Name>\\Overview.pdf". The default
<out> is "J:\\My Drive\\JourneyMaster\\Sessions". If that folder already holds a folder that starts with the
character's name followed by a space (for example "Baldrake Cavendell" for "Baldrake"), that folder is used.

Each PDF is made from a temporary HTML page (HyperText Markup Language) that Microsoft Edge or Chrome prints, so
nothing needs installing. A PDF newer than its Markdown file and pictures is skipped unless --force is given. A
renamed session gets a new file name; the old PDF of that session is removed.

Usage (or run scripts\\export_pdf.bat, which passes its options on):
  python -I scripts/export_pdf.py [--out <folder>] [--character <name>] [--name "<name>=<folder>"] [--force] [--list]
"""
import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DATA = ROOT / "data"
DEFAULT_OUT = r"J:\My Drive\JourneyMaster\Sessions"
BROWSERS = (
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
)
SESSION_FILE = re.compile(r"^(\d{4}-\d{2}-\d{2})-(\d+)\.md$")
IMAGE_LINE = re.compile(r"^!\[(.*?)\]\((.+?)\)\s*$")

STYLE = """
@page { size: A4; margin: 15mm; }
body { font-family: Georgia, "Times New Roman", serif; font-size: 11.5pt; color: #222; line-height: 1.5; }
h1 { font-size: 22pt; margin: 0 0 2mm; line-height: 1.2; }
h2 { font-size: 15pt; margin: 8mm 0 2mm; border-bottom: 1px solid #bbb; padding-bottom: 1mm; break-after: avoid; }
p { margin: 0 0 3.5mm; }
.meta { color: #666; font-style: italic; margin-bottom: 6mm; }
figure { margin: 4mm 0 6mm; break-inside: avoid; }
figure img { width: 100%; display: block; border: 1px solid #ccc; }
figcaption { color: #666; font-size: 9pt; margin-top: 1mm; font-family: "Segoe UI", Arial, sans-serif; }
"""


class Job:
    """One PDF to make: a Markdown file, where its PDF goes and the prefix that identifies it."""

    def __init__(self, source, pdf, kind, title, prefix):
        self.source = source
        self.pdf = pdf
        self.kind = kind  # "session" or "overview"
        self.title = title
        self.prefix = prefix  # session files start with it, so an older file name can be replaced


def read_text(path):
    return Path(path).read_text(encoding="utf-8-sig")


def safe_name(text):
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", text).strip(" .")
    return cleaned or "Untitled"


def first_title(markdown, fallback):
    for line in markdown.splitlines():
        match = re.match(r"^#\s+(.*\S)", line)
        if match:
            return match.group(1)
    return fallback


def inline_markup(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    return re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", text)


def image_path(source_dir, link):
    return (Path(source_dir) / unquote(link)).resolve()


def markdown_to_html(markdown, source_dir):
    """Headings, italic and bold, paragraphs, and picture lines (![caption](relative path))."""
    out = []
    first_italic = True
    for raw in markdown.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        image = IMAGE_LINE.match(line.strip())
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if image:
            caption = html.escape(image.group(1))
            path = image_path(source_dir, image.group(2))
            if path.is_file():
                out.append("<figure><img src=\"%s\"><figcaption>%s</figcaption></figure>" % (path.as_uri(), caption))
            else:
                out.append("<figure><figcaption>(picture missing) %s</figcaption></figure>" % caption)
        elif heading:
            level = len(heading.group(1))
            out.append("<h%d>%s</h%d>" % (level, inline_markup(heading.group(2)), level))
        elif first_italic and line.startswith("*") and line.endswith("*"):
            first_italic = False
            out.append("<p class=\"meta\">%s</p>" % inline_markup(line))
        else:
            out.append("<p>%s</p>" % inline_markup(line.strip()))
    return "\n".join(out)


def build_html(job):
    markdown = read_text(job.source)
    return ("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>%s</title><style>%s</style></head><body>\n%s\n</body></html>"
            % (html.escape(job.title), STYLE, markdown_to_html(markdown, job.source.parent)))


def referenced_pictures(job):
    found = []
    for line in read_text(job.source).splitlines():
        image = IMAGE_LINE.match(line.strip())
        if image:
            path = image_path(job.source.parent, image.group(2))
            if path.is_file():
                found.append(path)
    return found


def is_current(job):
    if not job.pdf.is_file():
        return False
    stamp = job.pdf.stat().st_mtime
    return all(p.stat().st_mtime <= stamp for p in [job.source] + referenced_pictures(job))


def load_state(data_dir):
    path = Path(data_dir) / "state.json"
    if not path.is_file():
        return {}
    try:
        return json.loads(read_text(path)).get("Characters", {}) or {}
    except (ValueError, OSError):
        return {}


def display_name(folder_name, state):
    name = (state.get(folder_name) or {}).get("Name")
    return name or folder_name.split("-", 1)[0]


def output_folder(out_root, name, names=None):
    """The character's output folder: the one chosen with --name, else an existing folder named like the character
    ("Baldrake Cavendell" for "Baldrake") when exactly one fits, else a new folder named after the character."""
    out_root = Path(out_root)
    if names and name.lower() in names:
        return out_root / safe_name(names[name.lower()])
    wanted = safe_name(name)
    if out_root.is_dir():
        exact = [d for d in out_root.iterdir() if d.is_dir() and d.name.lower() == wanted.lower()]
        if exact:
            return exact[0]
        starts = sorted(d for d in out_root.iterdir() if d.is_dir() and d.name.lower().startswith(wanted.lower() + " "))
        if len(starts) == 1:
            return starts[0]
    return out_root / wanted


def collect_jobs(data_dir, out_root, only_character=None, names=None):
    """The PDFs to make: each character's undeleted summarised sessions, and its overview once."""
    journeys = Path(data_dir) / "journeys"
    state = load_state(data_dir)
    jobs = []
    if not journeys.is_dir():
        return jobs
    for char_dir in sorted(p for p in journeys.iterdir() if p.is_dir()):
        name = display_name(char_dir.name, state)
        if only_character and only_character.lower() not in (name.lower(), char_dir.name.lower()):
            continue
        target = output_folder(out_root, name, names)
        # The state file numbers sessions across the whole journey ("Sessions": number -> file), which is not the
        # number at the end of a file name (that counts sessions within one day); "Deleted" uses the journey number.
        char_state = state.get(char_dir.name) or {}
        deleted = {str(k) for k in (char_state.get("Deleted") or {})}
        deleted_files = {(v or {}).get("File") for k, v in (char_state.get("Sessions") or {}).items() if str(k) in deleted}
        sessions = char_dir / "sessions"
        files = sorted(sessions.iterdir()) if sessions.is_dir() else []
        for file in files:
            match = SESSION_FILE.match(file.name)
            if not match or file.name in deleted_files:
                continue
            stem = "%s-%s" % (match.group(1), match.group(2))
            title = first_title(read_text(file), stem)
            jobs.append(Job(file, target / ("%s - %s.pdf" % (stem, safe_name(title))), "session", title, stem + " - "))
        overview = char_dir / "overview.md"
        if overview.is_file():
            jobs.append(Job(overview, target / "Overview.pdf", "overview", "The journey of %s so far" % name, None))
    return jobs


def find_browser(chosen=None):
    if chosen:
        if Path(chosen).is_file():
            return chosen
        raise SystemExit("Browser not found: %s" % chosen)
    for candidate in BROWSERS:
        if Path(candidate).is_file():
            return candidate
    for name in ("msedge", "chrome"):
        found = shutil.which(name)
        if found:
            return found
    raise SystemExit("Neither Microsoft Edge nor Chrome was found. Pass one with --browser.")


def print_pdf(browser, html_path, pdf_path):
    pdf_path = pdf_path.resolve()  # the browser runs elsewhere, so a relative path would land in the wrong place
    pdf_path.parent.mkdir(parents=True, exist_ok=True)
    partial = pdf_path.with_name(pdf_path.name + ".partial")
    if partial.exists():
        partial.unlink()
    with tempfile.TemporaryDirectory(prefix="jm-pdf-profile-") as profile:
        command = [
            browser, "--headless=new", "--disable-gpu", "--no-first-run", "--no-pdf-header-footer",
            "--allow-file-access-from-files", "--user-data-dir=" + profile,
            "--print-to-pdf=" + str(partial), html_path.resolve().as_uri(),
        ]
        subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300, check=False)
    if not partial.is_file() or partial.stat().st_size == 0:
        raise RuntimeError("the browser produced no PDF")
    os.replace(partial, pdf_path)  # a half-written file never takes the old PDF's place


def remove_older_names(job):
    """A renamed session has a new file name; remove this session's PDF under its old name."""
    if not job.prefix:
        return
    for other in job.pdf.parent.glob(glob_escape(job.prefix) + "*.pdf"):
        if other != job.pdf:
            other.unlink()
            print("Removed the older file name: %s" % other)


def glob_escape(text):
    return re.sub(r"([\[\]*?])", r"[\1]", text)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Export JourneyMaster's summarised sessions and overviews to PDF.")
    parser.add_argument("--out", default=DEFAULT_OUT, help="folder that receives one sub-folder per character (default: %(default)s)")
    parser.add_argument("--data", default=str(DEFAULT_DATA), help="JourneyMaster's data folder (default: %(default)s)")
    parser.add_argument("--character", help="export only this character, e.g. Baldrake")
    parser.add_argument("--name", action="append", default=[], metavar="CHARACTER=FOLDER",
                        help='output folder name for a character, e.g. --name "Baldrake=Baldrake Cavendell" (repeatable)')
    parser.add_argument("--force", action="store_true", help="rebuild PDFs that are already up to date")
    parser.add_argument("--list", action="store_true", help="only list what would be exported")
    parser.add_argument("--browser", help="path to msedge.exe or chrome.exe (found automatically by default)")
    args = parser.parse_args(argv)

    if not (Path(args.data) / "journeys").is_dir():
        raise SystemExit("No journeys folder under: %s" % args.data)
    names = {}
    for pair in args.name:
        if "=" not in pair:
            raise SystemExit("--name needs CHARACTER=FOLDER, got: %s" % pair)
        key, value = pair.split("=", 1)
        names[key.strip().lower()] = value.strip()
    jobs = collect_jobs(args.data, args.out, args.character, names)
    if not jobs:
        print("Nothing to export: no summarised sessions or overviews were found.")
        return 0

    if args.list:
        for job in jobs:
            state = "up to date" if is_current(job) else ("rebuild" if job.pdf.is_file() else "new")
            print("%-8s %-45s -> %s  [%s]" % (job.kind, job.source.relative_to(Path(args.data)), job.pdf, state))
        return 0

    browser = find_browser(args.browser)
    done = skipped = failed = 0
    with tempfile.TemporaryDirectory(prefix="jm-pdf-html-") as work:
        for number, job in enumerate(jobs):
            if not args.force and is_current(job):
                skipped += 1
                print("Skipped (up to date): %s" % job.pdf)
                continue
            html_path = Path(work) / ("page-%d.html" % number)
            html_path.write_text(build_html(job), encoding="utf-8")
            try:
                print_pdf(browser, html_path, job.pdf)
                remove_older_names(job)
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                failed += 1
                print("FAILED %s: %s" % (job.source.name, error), file=sys.stderr)
                continue
            done += 1
            print("Wrote %s (%.1f MB)" % (job.pdf, job.pdf.stat().st_size / 1e6))
    print("Done: %d written, %d skipped, %d failed." % (done, skipped, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
