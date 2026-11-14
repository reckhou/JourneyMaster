# JourneyMaster

JourneyMaster keeps a journal of your character's journey in WoW: Forever (World of Warcraft: Forever). An add-on records what your character does while you play, without any input from you. After each play session, a small app on your PC has the AI (artificial intelligence) write a plain account of that session. You read the journal in the game and as Markdown files on your PC.

Every character gets the same narrator, who writes each session like a chapter of a novel: third person, past tense, with a sense of place. It still writes only what the record holds and invents nothing. What NPCs, bosses and pets say is used only as background and never retold.

## What you need

- WoW: Forever on Windows (client 1.60.1, interface 16001).
- Windows PowerShell 5.1, which comes with Windows 10 and 11.
- [Claude Code](https://claude.com/claude-code), installed and signed in, so that the `claude` command works in a terminal. The app sends each session's record to the AI through this command, under your own account.

## Install

1. Copy the add-on into the game:

   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\deploy_addon.ps1
   ```

   By default it copies to `E:\World of Warcraft\_forever_\Interface\AddOns`. Give `-AddOns "<your AddOns folder>"` for another path. The script never overwrites your journal snapshot in the installed add-on.

2. Start the app, and leave it running while you play:

   ```
   scripts\run_app.bat
   ```

   The app looks for the game in `E:\World of Warcraft\_forever_`. If your game is somewhere else, give `-WowDir "<your _forever_ folder>"`.

## How it works

1. **In the game**, the add-on records zones, quests (with the quest's own text and the quest giver), what people near you say, NPC (non-player character) speech, deaths (with the killer when the game's death recap names one), bosses, dungeon entries and exits, rare loot, gear, group members, levels, skills, standing, money milestones and your own notes. It also takes a screenshot at level-ups, boss kills and dungeon entries, and when you first arrive in a zone you have never visited. If you fly over a new zone and leave it before you land, that zone is still new at your next arrival. Separately, it takes a screenshot in a zone once you have stayed there for 5 minutes. After a zone's stay screenshot, that zone gets no new one for 45 minutes. If you are still there when the 45 minutes are over, it takes the next one at once; if you left and came back, it takes one once you have been back for 5 minutes. Going into a building (an inn, a town hall) does not restart that wait, and neither does moving between places of the same zone. It takes none while you fly, on a flight path or a flying mount; it waits until you land. A zone screenshot then waits one more minute on the ground. Subzones (the named places inside a zone, such as Dun Modr in the Wetlands) get screenshots too: one the first time you stay in a new subzone for 5 minutes without a break, and, in each session, one once your time in a subzone adds up to 20 minutes. Time spent flying does not count, and dungeons and raids are left out.
2. **The game writes the record to disk** at `/reload` or logout.
3. **The app stores the new entries** under `data\journeys\<character>\events\`. This is the permanent record.
4. **When you click Summarise**, the app has the AI write that session's summary as `data\journeys\<character>\sessions\<date>-<n>.md`. The app summarises nothing on its own. In dungeons and raids the game hides chat from add-ons, so the app fills those stretches from the game's own chat log, `Logs\WoWChatLog.txt`. The add-on turns chat logging on for this. A session file is never changed again once written, so you may edit it.

   **Summarise**, in the foot of the window, is shown for a session that is finished and has no summary yet, in the place of **Reload**. The session in progress shows **Finish session** (green) instead: click it to end the session and start a new one, then Summarise the finished one. Summarise reloads the interface, so the game writes the record to disk, and a few seconds after the login it tells the app which session to summarise. The app can stay in the background but must be running (`scripts\run_app.bat`), and it refuses a session that is not finished. Summarise itself ends nothing. A session shows as "requested" for ten minutes; then the button comes back. Logging out and back in within 30 minutes, even after closing the game, keeps the same session. Each character has its own sessions.
5. **The app also writes** `overview.md` (the journey so far: a section headed by the title of each session, with one of its screenshots, preferring one taken during the journey to a level-up) and gives the game a new snapshot of the summaries and the overview. The game's Overview tab shows it.
6. **After the app has finished, `/reload` or click Reload**, and the summary appears in the game.

## In the game

- Click the **minimap button** (a book), or type `/jm`, to open the journal. The add-on menu has an entry for it too.
- The **session list** on the left drives both tabs. **Journal** shows a session's summary. **Log** shows its raw entries, with one on/off switch for each kind of entry. **Settings** has the switches for each chat channel, NPC speech, screenshots, the minimap button and a reload prompt.
- **AI summaries**, under Settings, chooses the model (Opus, Sonnet, Haiku or Fable) and the effort level (low to max) the app summarises with. The default is Opus at low effort. Each click steps to the next choice. The change reaches the running app within seconds, through the chat log, and applies from its next summary. It is kept for each character. The app's `-Model` and `-Effort` options set the default for characters that have not chosen.
- The **Log** colours each line in the game's own chat colour for its kind (say, yell, party, emote, NPC speech and so on), loot in its item quality colour, and notes in white. Player emotes have their own switch, apart from chat.
- **Screenshots** show as thumbnails in the summary of each of the newest sessions. The AI is told when each screenshot was taken and places it at that point in the story; it does not see the pictures. Any it does not place go at the end. The app makes them in the add-on's `Thumbs\` folder. The game may only find a new thumbnail after a full restart of the game, not after `/reload`; this is not yet checked.
- **Open screenshots**, in the foot of the window, has the app open that session's screenshots in File Explorer a few seconds later, with no reload.
- **Summarise** asks the app to summarise the chosen session, which must be finished (see step 4 above); **Reload** takes its place for sessions that already have a summary.
- **Finish session** (the green button) ends the session in progress (also `/jm end`) and starts a new one. It does not summarise anything.
- An add-on cannot reach your PC itself, so these buttons send a hidden line through the game's chat log. About 48 KiB (kibibytes) of hidden filler follows it, which makes the game write the log to disk at once. This is the method RPMaster uses. It is proven on retail but not yet measured on WoW: Forever. Each click adds about 48 KiB to `Logs\WoWChatLog.txt`. The app must be running (`scripts\run_app.bat`).
- `/jm note <text>` adds a note about something the game cannot see.
- If part of the add-on fails, it says so once in chat and carries on recording. `/jm errors` lists every error since login, with how often each one happened.
- `/jm help` lists every command.

## Your files

Everything stays under `data\` in this folder. Git ignores it.

| Path under `data\journeys\<character>\` | What it holds |
| --- | --- |
| `events\<date>.jsonl` | The permanent record, one entry per line |
| `sessions\<date>-<n>.md` | One summary per play session |
| `records\<date>-<n>.txt` | The exact record the AI was given for that session, so you can check a summary against it |
| `screenshots\` | The milestone screenshots, linked from their sessions. Their thumbnails for the game are in the add-on's `Thumbs\` folder; the app deletes the ones no recent session uses |
| `overview.md` | The journey so far: one section for each session, headed by its title, with one screenshot each |

## Privacy

- Nothing leaves your PC except the text sent to the AI through your own signed-in `claude` command.
- The record includes other players' names and what they said in say, yell, emote, party, raid and instance chat near you. Whispers, guild, officer and numbered channels (General, Trade and the like) are never recorded.
- Each chat channel can be switched off under Settings.

## For developers

| Path | What it is |
| --- | --- |
| `src/JourneyMaster/` | The add-on (Lua 5.1). `Core.lua` and `Journal.lua` hold the logic with no game calls |
| `src/App/` | The app (Windows PowerShell 5.1). `JourneyMasterApp.psm1` holds the logic; `LuaReader.cs` reads the saved file |
| `src/JourneyProbe/`, `scripts/probe_report.py` | The Phase 0 probe that checked what the game allows. It is not installed any more |
| `tests/` | Offline harnesses |
| `scripts/replay_sessions.ps1` | Runs a made-up journey through the app and checks that no summary invents or loses anything |
| `scripts/compare_models.ps1` | Summarises one real session with a chosen AI model and effort, with the app's own prompt and checks, and saves the result for comparison (`-Label`, `-Model`, `-Effort`) |

Run the tests:

```
python scripts/run_lua_tests.py
powershell -NoProfile -ExecutionPolicy Bypass -File tests\app_harness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\replay_sessions.ps1 -Fake
```

The Lua harnesses need Python with [Lupa](https://pypi.org/project/lupa/) (`pip install lupa`). The app harness and `-Fake` use a stand-in for `claude`, so they cost nothing. Without `-Fake`, the replay uses the real `claude`.
