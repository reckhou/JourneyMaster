<#
.SYNOPSIS
Replays a made-up journey of four play sessions through the JourneyMaster app and checks that each summary invents
nothing and loses nothing (Phase 4).

.DESCRIPTION
The sessions use invented characters and places from the game, never real players:
  1. A quiet hour of quests in Northshire Valley.
  2. A dungeon run in The Stockade, whose chat comes only from a made-up chat log, with a death and a boss.
  3. A very long evening of talk at the Lion's Pride Inn, long enough to be summarised in parts.
  4. A short session of small milestones: gear, money, a skill, a standing and a note.
The app runs against a made-up game folder; then every summary is checked again here:
  - invents nothing: every name and number in the account is in the record the AI was given;
  - loses nothing: every key fact of the session (quests, dungeon, boss, levels, deaths and killers, people who joined)
    is in the account.
The report is written to <DataDir>\replay-report.md. Exit code 0 when every session passes.
Examples:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\replay_sessions.ps1            # with the real claude
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\replay_sessions.ps1 -Fake      # offline, fake claude
Kept ASCII-only.
#>
param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\private-local\replay'),
    [switch]$Fake,
    [string]$ClaudePath,
    [int]$MaxPromptChars = 20000
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\App\JourneyMasterApp.psm1') -Force
$Utf8 = New-Object Text.UTF8Encoding $false
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$DataDir = [IO.Path]::GetFullPath($DataDir)
if (Test-Path -LiteralPath $DataDir) { Remove-Item -Recurse -Force -LiteralPath $DataDir }
$Wow = Join-Path $DataDir 'game'
$AppData = Join-Path $DataDir 'data'
$AddOn = Join-Path $Wow 'Interface\AddOns\JourneyMaster'
New-Item -ItemType Directory -Force $AddOn, (Join-Path $Wow 'Logs'), (Join-Path $Wow 'Screenshots') | Out-Null
Copy-Item (Join-Path $Root 'src\JourneyMaster\JournalSnapshot.lua') $AddOn

# The saved file, written as the game writes it -------------------------------------------------------------------------
function ConvertTo-Lua($v, [int]$Depth = 0) {
    $tab = "`t" * ($Depth + 1)
    if ($null -eq $v) { return 'nil' }
    if ($v -is [bool]) { return $(if ($v) { 'true' } else { 'false' }) }
    if ($v -is [int] -or $v -is [long] -or $v -is [double]) { return [string]$v }
    if ($v -is [string]) {
        $s = $v.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n')
        return '"' + $s + '"'
    }
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('{')
    if ($v -is [Collections.IDictionary]) {
        foreach ($k in $v.Keys) { $lines.Add("$tab[`"$k`"] = $(ConvertTo-Lua $v[$k] ($Depth + 1)),") }
    } else {
        $n = 0
        foreach ($item in $v) { $n++; $lines.Add("$tab$(ConvertTo-Lua $item ($Depth + 1)), -- [$n]") }
    }
    $lines.Add(("`t" * $Depth) + '}')
    $lines -join "`n"
}

# The made-up journey ---------------------------------------------------------------------------------------------------
$P = 'Maren Ashdown'
$entries = New-Object Collections.Generic.List[object]
$log = New-Object Collections.Generic.List[string]
$script:i = 0
$script:s = 0
function Add-E([long]$T, [hashtable]$E) { $script:i++; $E.i = $script:i; $E.s = $script:s; $E.t = $T; $entries.Add($E) }
function Add-Log([long]$T, [string]$Text) { $d = ConvertFrom-Epoch $T; $log.Add("$($d.Month)/$($d.Day) $($d.ToString('HH:mm:ss')).000  $Text") }
function At([int]$Day, [int]$H, [int]$M) { ConvertTo-Epoch (Get-Date -Year 2026 -Month 11 -Day $Day -Hour $H -Minute $M -Second 0 -Millisecond 0) }

# Session 1: a quiet hour in Northshire.
$script:s = 1
$t = At 1 19 0
Add-E $t @{ k = 'login'; lvl = 5; z = 'Elwynn Forest'; sz = 'Northshire Valley' }
Add-E ($t + 60) @{ k = 'quest'; act = 'accept'; id = 1; title = 'A Threat Within'; giver = 'Deputy Willem'; text = 'Marshal McBride is looking for able bodies to help defend Northshire. Report to him inside the Abbey.'; z = 'Elwynn Forest'; sz = 'Northshire Valley' }
Add-E ($t + 200) @{ k = 'npc'; ch = 'say'; who = 'Marshal McBride'; text = 'Kobolds have been seen near the vineyards. Keep your blade ready.'; z = 'Elwynn Forest'; sz = 'Northshire Abbey' }
Add-E ($t + 240) @{ k = 'quest'; act = 'turnin'; id = 1; title = 'A Threat Within'; giver = 'Marshal McBride'; xp = 40; money = 0; reward = 'Good, we need every hand we can find.'; z = 'Elwynn Forest'; sz = 'Northshire Abbey' }
Add-E ($t + 300) @{ k = 'quest'; act = 'accept'; id = 7; title = 'Kobold Camp Cleanup'; giver = 'Marshal McBride'; text = 'The kobolds of the Echo Ridge Mine threaten the valley. Kill ten Kobold Vermin.'; obj = 'Kill 10 Kobold Vermin.'; z = 'Elwynn Forest'; sz = 'Northshire Abbey' }
Add-E ($t + 900) @{ k = 'chat'; ch = 'say'; who = 'Tobin Fairweather'; text = 'Morning! Are you new to the Abbey?'; z = 'Elwynn Forest'; sz = 'Northshire Vineyards' }
Add-E ($t + 930) @{ k = 'chat'; ch = 'say'; who = $P; text = 'Arrived yesterday. The marshal has me hunting kobolds.'; z = 'Elwynn Forest'; sz = 'Northshire Vineyards' }
Add-E ($t + 960) @{ k = 'group'; act = 'join'; who = 'Tobin Fairweather'; z = 'Elwynn Forest'; sz = 'Northshire Vineyards' }
Add-E ($t + 1500) @{ k = 'chat'; ch = 'party'; who = 'Tobin Fairweather'; text = 'That makes ten. Back to McBride?'; z = 'Elwynn Forest'; sz = 'Echo Ridge Mine' }
Add-E ($t + 1600) @{ k = 'level'; level = 6; played = 7200; z = 'Elwynn Forest'; sz = 'Echo Ridge Mine' }
Add-E ($t + 1602) @{ k = 'shot'; why = 'level'; z = 'Elwynn Forest'; sz = 'Echo Ridge Mine' }
# The game's screenshot for it, a moment later (any bytes will do: the app only copies the file).
$shotName = 'WoWScrnShot_' + (ConvertFrom-Epoch ($t + 1603)).ToString('MMddyy_HHmmss') + '.jpg'
Add-E ($t + 2400) @{ k = 'quest'; act = 'turnin'; id = 7; title = 'Kobold Camp Cleanup'; giver = 'Marshal McBride'; xp = 180; money = 35; z = 'Elwynn Forest'; sz = 'Northshire Abbey' }
Add-E ($t + 2500) @{ k = 'group'; act = 'leave'; who = 'Tobin Fairweather'; z = 'Elwynn Forest'; sz = 'Northshire Abbey' }
Add-E ($t + 3000) @{ k = 'logout'; z = 'Elwynn Forest'; sz = 'Northshire Abbey' }

# Session 2: The Stockade, its chat from the chat log only.
$script:s = 2
$t = At 2 20 0
Add-E $t @{ k = 'login'; lvl = 24; z = 'Stormwind City'; sz = 'Trade District' }
Add-E ($t + 120) @{ k = 'group'; act = 'join'; who = 'Elsa Brightvale'; z = 'Stormwind City'; sz = 'Trade District' }
Add-E ($t + 130) @{ k = 'group'; act = 'join'; who = 'Tobin Fairweather'; z = 'Stormwind City'; sz = 'Trade District' }
Add-E ($t + 200) @{ k = 'quest'; act = 'accept'; id = 386; title = 'What Comes Around...'; giver = 'Guard Berton'; text = 'Targorr the Dread has escaped his cell in the Stockade. Bring me his head.'; z = 'Stormwind City'; sz = 'The Mage Quarter' }
Add-E ($t + 600) @{ k = 'enter'; inst = 'The Stockade'; itype = 'party'; z = 'The Stockade' }
Add-E ($t + 610) @{ k = 'gap'; what = 'chat lines'; n = 5; z = 'The Stockade' }
Add-Log ($t + 640) '|Hchannel:PARTY|h[Party Leader]|h Elsa Brightvale: Stay close, the cells are full of rioters.'
Add-Log ($t + 700) 'Defias Prisoner dies, you gain 120 experience. (+30 group bonus)'
Add-Log ($t + 760) 'Defias Prisoner dies, you gain 120 experience. (+30 group bonus)'
Add-Log ($t + 900) 'Targorr the Dread yells: You will not leave this place alive!'
Add-Log ($t + 930) '|Hchannel:PARTY|h[Party]|h Tobin Fairweather: He hits hard, heal me!'
Add-E ($t + 960) @{ k = 'death'; recap = 'ok'; killer = 'Targorr the Dread'; spell = 'Thrash'; z = 'The Stockade' }
Add-Log ($t + 960) 'You died.'
Add-Log ($t + 1100) 'Tobin has died.'
Add-Log ($t + 1300) 'Targorr the Dread dies, you gain 400 experience. (+100 group bonus)'
Add-Log ($t + 1310) 'You receive loot: Dread Head.'
Add-Log ($t + 1800) 'Bazil Thredd yells: Lads, a visitor! Show them the way out!'
Add-E ($t + 2100) @{ k = 'boss'; name = 'Bazil Thredd'; z = 'The Stockade' }
Add-Log ($t + 2110) '|Hchannel:PARTY|h[Party Leader]|h Elsa Brightvale: That is the last of them. Well fought.'
Add-E ($t + 2400) @{ k = 'leave'; inst = 'The Stockade'; itype = 'party'; z = 'Stormwind City'; sz = 'The Mage Quarter' }
Add-E ($t + 2500) @{ k = 'quest'; act = 'turnin'; id = 386; title = 'What Comes Around...'; giver = 'Guard Berton'; xp = 2850; money = 1500; z = 'Stormwind City'; sz = 'The Mage Quarter' }
Add-E ($t + 2600) @{ k = 'logout'; z = 'Stormwind City'; sz = 'The Mage Quarter' }

# Session 3: a very long evening at the Lion's Pride Inn.
$script:s = 3
$t = At 4 18 0
Add-E $t @{ k = 'login'; lvl = 24; z = 'Elwynn Forest'; sz = 'Goldshire' }
$talk = @(
    @('Elsa Brightvale', 'The harvest in Westfall failed again, the farmers say.'),
    @($P, 'I heard the same in Sentinel Hill. The Defias take what is left.'),
    @('Tobin Fairweather', 'Someone should ride out and see for themselves.'),
    @('Elsa Brightvale', 'My brother keeps a farm near the Jangolode Mine.'),
    @($P, 'Is he safe there?'),
    @('Elsa Brightvale', 'He writes that the miners have stopped coming to market.'),
    @('Tobin Fairweather', 'Another round before we talk of grim things.'),
    @($P, 'Agreed. The stew here is better than the Abbey food.'),
    @('Tobin Fairweather', 'Brother Neals would not agree.'),
    @('Elsa Brightvale', 'Brother Neals would agree with anything that ends in prayer.')
)
$minute = 0
for ($n = 0; $n -lt 600; $n++) {
    $sec = $t + 60 + $n * 30
    $line = $talk[$n % $talk.Count]
    Add-E $sec @{ k = 'chat'; ch = 'say'; who = $line[0]; text = "$($line[1]) (round $([Math]::Floor($n / $talk.Count) + 1))"; z = 'Elwynn Forest'; sz = "Lion's Pride Inn" }
    if ($n -eq 150) { Add-E ($sec + 5) @{ k = 'quest'; act = 'accept'; id = 62; title = 'The Fargodeep Mine'; giver = 'Marshal Dughan'; text = 'Kobolds have been seen in the Fargodeep Mine. Scout it and report back.'; z = 'Elwynn Forest'; sz = 'Goldshire' } }
    if ($n -eq 300) { Add-E ($sec + 5) @{ k = 'level'; level = 25; played = 260000; z = 'Elwynn Forest'; sz = "Lion's Pride Inn" } }
    if ($n -eq 450) { Add-E ($sec + 5) @{ k = 'group'; act = 'join'; who = 'Corwin Hale'; z = 'Elwynn Forest'; sz = "Lion's Pride Inn" } }
    if ($n -eq 560) { Add-E ($sec + 5) @{ k = 'quest'; act = 'turnin'; id = 62; title = 'The Fargodeep Mine'; giver = 'Marshal Dughan'; xp = 900; money = 300; z = 'Elwynn Forest'; sz = 'Goldshire' } }
    if ($n -eq 580) { Add-E ($sec + 5) @{ k = 'note'; text = 'Promised Elsa to ride to Westfall with her next week.'; z = 'Elwynn Forest'; sz = "Lion's Pride Inn" } }
}
Add-E ($t + 60 + 600 * 30 + 60) @{ k = 'logout'; z = 'Elwynn Forest'; sz = "Lion's Pride Inn" }

# Session 4: small milestones.
$script:s = 4
$t = At 5 21 0
Add-E $t @{ k = 'login'; lvl = 25; z = 'Stormwind City'; sz = 'Trade District' }
Add-E ($t + 60) @{ k = 'gear'; item = '[Blackened Defias Belt]'; slot = 'waist'; q = 2; z = 'Stormwind City'; sz = 'Trade District' }
Add-E ($t + 120) @{ k = 'money'; copper = 100000; z = 'Stormwind City'; sz = 'Trade District' }
Add-E ($t + 300) @{ k = 'skill'; skill = 'Tailoring'; value = 75; z = 'Stormwind City'; sz = 'The Canals' }
Add-E ($t + 400) @{ k = 'rep'; faction = 'Stormwind'; standing = 'Honored'; z = 'Stormwind City'; sz = 'The Canals' }
Add-E ($t + 500) @{ k = 'note'; text = 'Bought a new robe pattern from the tailor.'; z = 'Stormwind City'; sz = 'The Canals' }
Add-E ($t + 1200) @{ k = 'logout'; z = 'Stormwind City'; sz = 'Trade District' }

$char = [ordered]@{ name = $P; realm = 'Replay'; race = 'Human'; class = 'Priest'; faction = 'Alliance'; sex = 3; level = 25; seq = $script:i; dropped = 0; entries = $entries.ToArray() }
$svPath = Join-Path $Wow 'WTF\Account\REPLAY\SavedVariables\JourneyMaster.lua'
New-Item -ItemType Directory -Force (Split-Path $svPath) | Out-Null
[IO.File]::WriteAllText($svPath, "`nJourneyMasterDB = $(ConvertTo-Lua ([ordered]@{ schema = 1; characters = [ordered]@{ 'Maren Ashdown-Replay' = $char } }))`n", $Utf8)
[IO.File]::WriteAllText((Join-Path $Wow 'Logs\WoWChatLog.txt'), (($log.ToArray() -join "`r`n") + "`r`n"), $Utf8)
[IO.File]::WriteAllBytes((Join-Path $Wow "Screenshots\$shotName"), [byte[]](255, 216, 255, 217))
Write-Host "Made-up journey: $($script:i) entries in 4 sessions, $($log.Count) chat log lines." -ForegroundColor Cyan

# Run the app --------------------------------------------------------------------------------------------------------------
$appArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'src\App\JourneyMaster.ps1'), '-WowDir', $Wow, '-DataDir', $AppData,
    '-GameRunning', 'no', '-MaxPromptChars', $MaxPromptChars)
if ($Fake) { $appArgs += @('-ClaudePath', (Join-Path $Root 'tests\fake_claude.ps1')) } elseif ($ClaudePath) { $appArgs += @('-ClaudePath', $ClaudePath) }
$sw = [Diagnostics.Stopwatch]::StartNew()
& powershell @appArgs
Write-Host "App run took $([Math]::Round($sw.Elapsed.TotalSeconds)) seconds." -ForegroundColor Cyan

# Check every summary again ------------------------------------------------------------------------------------------------
$charDir = Join-Path $AppData 'journeys\Maren Ashdown-Replay'
$state = (Read-FileText (Join-Path $AppData 'state.json')) | ConvertFrom-Json
$sessions = @(Get-Sessions (Read-EventEntries (Join-Path $charDir 'events')))
$report = New-Object Collections.Generic.List[string]
$report.Add('# JourneyMaster replay report')
$report.Add('')
$report.Add("Run: $(Get-Date -Format 'd MMMM yyyy HH:mm'). AI: $(if ($Fake) { 'fake claude (offline)' } else { 'claude' }). Parts start above $MaxPromptChars characters of record.")
$report.Add('')
$report.Add('| Session | Title | Parts | Invented (not in the record) | Lost (key facts left out) | Talks about its sources (style warning) | Result |')
$report.Add('| --- | --- | --- | --- | --- | --- | --- |')
$failed = 0
foreach ($s in $sessions) {
    $info = $state.Characters.'Maren Ashdown-Replay'.Sessions.PSObject.Properties["$($s.S)"]
    if (-not $info) { $report.Add("| $($s.S) | (not summarised) | | | | | FAIL |"); $failed++; continue }
    $info = $info.Value
    $doc = Read-SessionMarkdown (Read-FileText (Join-Path $charDir "sessions\$($info.File)"))
    $record = Read-FileText (Join-Path $charDir ('records\' + [IO.Path]::ChangeExtension($info.File, '.txt')))
    $account = $doc.Title + "`n" + ($doc.Body -replace '(?s)\n## Screenshots.*$', '') # the app adds that section, not the AI
    $invented = @(Test-Grounded $account ($record + "`n" + $P))
    $lost = @(Test-Coverage $account (Get-KeyFacts $s.Entries $P))
    $meta = @(Test-SourceMentions $doc.Body)
    $ok = $invented.Count -eq 0 -and $lost.Count -eq 0
    if (-not $ok) { $failed++ }
    $report.Add("| $($s.S) | $($doc.Title) | $($info.Parts) | $(if ($invented) { $invented -join ', ' } else { 'none' }) | $(if ($lost) { $lost -join '; ' } else { 'none' }) | $(if ($meta) { $meta -join ', ' } else { 'none' }) | $(if ($ok) { 'pass' } else { 'FAIL' }) |")
}
# Phase 5: the screenshot is linked from its session, the overview invents nothing, and the export holds every session.
$docs = @(Get-ChildItem (Join-Path $charDir 'sessions') -Filter '*.md' | Sort-Object Name | ForEach-Object { Read-SessionMarkdown (Read-FileText $_.FullName) })
$extras = @()
if (-not ($docs[0].Body -match '!\[Level up, \d\d:\d\d\]\(\.\./screenshots/[^)]+-level\.jpg\)')) { $extras += 'the level-up screenshot is not linked from session 1' }
if (@(Get-ChildItem (Join-Path $charDir 'screenshots') -ErrorAction SilentlyContinue).Count -ne 1) { $extras += 'the screenshot was not copied' }
$overviewPath = Join-Path $charDir 'overview.md'
if (Test-Path -LiteralPath $overviewPath) {
    $ov = (Read-SessionMarkdown (Read-FileText $overviewPath)).Body
    $ovSource = "$P`n" + (($docs | ForEach-Object { "$($_.Title) $($_.Line) $($_.Body)" }) -join "`n")
    $ovInvented = @(Test-Grounded $ov $ovSource)
    if ($ovInvented.Count -gt 0) { $extras += "the overview names things the sessions do not hold: $($ovInvented -join ', ')" }
    $ovMeta = @(Test-SourceMentions $ov)
    $report.Add('')
    $report.Add("Overview: $(($ov -split '\s+').Count) words; invented: $(if ($ovInvented) { $ovInvented -join ', ' } else { 'none' }); talks about its sources: $(if ($ovMeta) { $ovMeta -join ', ' } else { 'none' }).")
} else { $extras += 'no overview was written' }
$journalPath = Join-Path $charDir 'journal.md'
if (Test-Path -LiteralPath $journalPath) {
    $j = Read-FileText $journalPath
    foreach ($d in $docs) { if (-not $j.Contains("## $($d.Title)")) { $extras += "the export lacks '$($d.Title)'" } }
    if (-not ($j -match '\]\(screenshots/')) { $extras += 'the export does not link the screenshot from the character folder' }
    $report.Add("Export: journal.md with $($docs.Count) sessions$(if ($j -match '## Overview') { ' and the overview' }).")
} else { $extras += 'no export was written' }
foreach ($x in $extras) { $report.Add("FAIL: $x."); $failed++ }

$long = $state.Characters.'Maren Ashdown-Replay'.Sessions.'3'
if (-not $long -or [int]$long.Parts -lt 2) { $report.Add(''); $report.Add('FAIL: the long session was not summarised in parts.'); $failed++ }
$report.Add('')
$report.Add("Session files: $charDir\sessions. Records sent to the AI: $charDir\records.")
$text = ($report -join "`n") + "`n"
[IO.File]::WriteAllText((Join-Path $DataDir 'replay-report.md'), $text, $Utf8)
Write-Host ''
Write-Host $text
if ($failed -gt 0) { Write-Host "$failed sessions failed" -ForegroundColor Red; exit 1 }
Write-Host 'Replay passed: nothing invented, nothing lost.' -ForegroundColor Green
