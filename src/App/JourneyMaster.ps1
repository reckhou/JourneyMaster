<#
.SYNOPSIS
JourneyMaster app: turns the add-on's record into a journal of AI-written session summaries.

.DESCRIPTION
Each run (or each change of the add-on's saved file, with -Watch):
  1. Reads JourneyMaster.lua (the add-on's SavedVariables) and appends new entries to
     <DataDir>\journeys\<character>\events\<date>.jsonl, the permanent record.
  2. Groups entries into play sessions and, for each finished session not yet summarised, fills its dungeon and raid
     windows from the game's chat log, has the AI write the summary (in parts for a very long session), and saves it as
     <DataDir>\journeys\<character>\sessions\<date>-<n>.md with its screenshots. A session file is never touched again.
  3. Rewrites the journey overview (overview.md) and the whole-journal export (journal.md).
  4. Writes JournalSnapshot.lua into the add-on's folder; the game shows it at the next /reload or login.
Examples:
  powershell -NoProfile -ExecutionPolicy Bypass -File src\App\JourneyMaster.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File src\App\JourneyMaster.ps1 -Watch
  powershell -NoProfile -ExecutionPolicy Bypass -File src\App\JourneyMaster.ps1 -Export
Kept ASCII-only: Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
#>
param(
    [string]$WowDir = 'E:\World of Warcraft\_forever_',
    [string]$DataDir = (Join-Path $PSScriptRoot '..\..\data'),
    [string]$SavedVariables,   # JourneyMaster.lua; by default the newest under <WowDir>\WTF\Account\*\SavedVariables
    [string]$AddOnDir,         # by default <WowDir>\Interface\AddOns\JourneyMaster
    [string]$ChatLog,          # by default <WowDir>\Logs\WoWChatLog.txt
    [string]$ScreenshotDir,    # by default <WowDir>\Screenshots
    [string]$LoreDir,          # by default ..\wow-forever-rp-profile\references\lore beside this repository, when present
    [string]$ClaudePath,
    [string]$Model = 'claude-sonnet-5-5',
    [string]$Effort = 'low',
    [int]$Attempts = 2,        # AI calls per summary when the first is refused or not grounded
    [int]$FullSessions = 10,   # newest sessions whose summary text goes into the snapshot; older ones by title only
    [int]$MaxPromptChars = 60000, # a record longer than this is summarised in parts
    [int]$OverviewMaxChars = 120000, # above this the overview is updated from the previous one and the new sessions
    [switch]$Watch,
    [int]$PollSeconds = 15,
    [switch]$Export,           # only write journal.md for every character, then stop
    [switch]$NoOverview,
    [switch]$NoExplorer,       # do not open File Explorer for the game's "Open screenshots on PC" button (for tests)
    [ValidateSet('auto', 'yes', 'no')][string]$GameRunning = 'auto',
    [long]$Now = 0,            # epoch seconds, for tests
    [switch]$DebugMode
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'JourneyMasterApp.psm1') -Force
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$DataDir = [IO.Path]::GetFullPath($DataDir)
if (-not $AddOnDir) { $AddOnDir = Join-Path $WowDir 'Interface\AddOns\JourneyMaster' }
if (-not $ChatLog) { $ChatLog = Join-Path $WowDir 'Logs\WoWChatLog.txt' }
if (-not $ScreenshotDir) { $ScreenshotDir = Join-Path $WowDir 'Screenshots' }
if (-not $LoreDir) {
    $guess = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\wow-forever-rp-profile\references\lore'))
    if (Test-Path -LiteralPath $guess) { $LoreDir = $guess }
}
$JourneysDir = Join-Path $DataDir 'journeys'
$StateFile = Join-Path $DataDir 'state.json'
$WorkDir = Join-Path $DataDir 'claude-cwd' # empty: the AI reads nothing itself
foreach ($d in @($DataDir, $JourneysDir, $WorkDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

function Say($text, $colour = 'Gray') { Write-Host "$(Get-Date -Format HH:mm:ss) $text" -ForegroundColor $colour }
function Dbg($text) { if ($DebugMode) { Write-Host "  [debug] $text" -ForegroundColor DarkGray } }
function NowEpoch { if ($Now -gt 0) { $Now } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } }
function Test-GameRunning {
    if ($GameRunning -eq 'yes') { return $true }
    if ($GameRunning -eq 'no') { return $false }
    [bool](Get-Process -Name 'Wow', 'WowClassic', 'Wow-64' -ErrorAction SilentlyContinue)
}

# State ------------------------------------------------------------------------------------------------------------------
# Characters: key -> LastSeq (newest entry stored), Name, Realm, Race, Class, Faction, Level, Folder, and Sessions
# (session number -> File, Title, First, Last, Zones, LevelFrom, LevelTo, Ungrounded). Revision: the snapshot's.

function Read-State {
    $s = @{ Revision = 0; Characters = @{} }
    if (Test-Path -LiteralPath $StateFile) {
        $j = (Read-FileText $StateFile) | ConvertFrom-Json
        $s.Revision = [long]$j.Revision
        foreach ($p in $j.Characters.PSObject.Properties) {
            $c = @{ Sessions = @{} }
            foreach ($q in $p.Value.PSObject.Properties) { if ($q.Name -ne 'Sessions') { $c[$q.Name] = $q.Value } }
            if ($p.Value.PSObject.Properties['Sessions']) {
                foreach ($q in $p.Value.Sessions.PSObject.Properties) { $c.Sessions[$q.Name] = $q.Value }
            }
            $s.Characters[$p.Name] = $c
        }
    }
    $s
}
function Save-State { Write-FileAtomic $StateFile (ConvertTo-Json -InputObject $State -Depth 8) }

function Find-SavedVariables {
    if ($SavedVariables) { return $SavedVariables }
    $root = Join-Path $WowDir 'WTF\Account'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $f = Get-ChildItem -Path $root -Recurse -Filter 'JourneyMaster.lua' -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'SavedVariables' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { $f.FullName } else { $null }
}

function Get-CharDir($c) { Join-Path $JourneysDir $c.Folder }

# Opens File Explorer on a session's first screenshot. A session not summarised yet has its screenshots only in the
# game's Screenshots folder, so that folder opens instead.
function Open-SessionShots($key, $c, [long]$Number) {
    $target = $null
    $known = $c.Sessions["$Number"]
    if ($known) {
        $md = Join-Path (Join-Path (Get-CharDir $c) 'sessions') $known.File
        if (Test-Path -LiteralPath $md) {
            $first = @(Get-SessionShots (Read-FileText $md)) | Select-Object -First 1
            if ($first) { $target = Join-Path (Join-Path (Get-CharDir $c) 'screenshots') $first.Name }
        }
    }
    if ($target -and (Test-Path -LiteralPath $target)) { $explorerArgs = "/select,`"$target`"" }
    else {
        $target = if ($known) { Join-Path (Get-CharDir $c) 'screenshots' } else { $ScreenshotDir }
        if (-not (Test-Path -LiteralPath $target)) { Say "$key`: no screenshots folder to open at $target" 'Yellow'; return }
        $explorerArgs = "`"$target`""
    }
    Say "$key`: opening $target, as asked in the game" 'Cyan'
    if (-not $NoExplorer) { Start-Process -FilePath 'explorer.exe' -ArgumentList $explorerArgs }
}

# Step 1: new entries into the event files -------------------------------------------------------------------------------

function Import-SavedVariables([string]$Path) {
    $g = Read-SavedVariables $Path
    $db = $g['JourneyMasterDB']
    if (-not $db -or -not $db['characters']) { Dbg 'no characters in the saved file yet'; return }
    foreach ($key in @($db['characters'].Keys)) {
        $sv = $db['characters'][$key]
        if (-not $State.Characters.ContainsKey($key)) {
            $State.Characters[$key] = @{ LastSeq = 0; Folder = (Get-SafeName $key); Sessions = @{} }
        }
        $c = $State.Characters[$key]
        foreach ($field in 'name', 'realm', 'race', 'class', 'faction', 'level', 'sex') {
            if ($null -ne $sv[$field]) { $c[(Get-Culture).TextInfo.ToTitleCase($field)] = $sv[$field] }
        }
        $entries = @($sv['entries'])
        $new = @($entries | Where-Object { $_ -is [Collections.IDictionary] -and [long]$_['i'] -gt [long]$c.LastSeq })
        if ($new.Count -gt 0) {
            $n = Add-EventEntries (Join-Path (Get-CharDir $c) 'events') $new
            $c.LastSeq = [long](($new | ForEach-Object { [long]$_['i'] } | Measure-Object -Maximum).Maximum)
            Say "$key`: $n new entries stored"
            $script:Changed = $true
        }
        if ([long]$sv['dropped'] -gt [long]$c['Dropped']) {
            Say "$key`: the add-on dropped $($sv['dropped']) entries at its size cap" 'Yellow'
            $c.Dropped = [long]$sv['dropped']
        }
        # The game's "Open screenshots on PC" button: each request (its time) is answered once.
        $req = $sv['openShots']
        if ($req -is [Collections.IDictionary] -and [long]$req['t'] -gt [long]$c['OpenShotsDone']) {
            $c.OpenShotsDone = [long]$req['t']
            Open-SessionShots $key $c ([long]$req['s'])
        }
    }
}

# Step 2: summaries ------------------------------------------------------------------------------------------------------

function Invoke-Model([string]$Rules, [string]$Prompt) {
    $rulesFile = Join-Path $WorkDir 'rules.md'
    [IO.File]::WriteAllText($rulesFile, $Rules, (New-Object Text.UTF8Encoding $false))
    $argList = @('-p', '--model', $Model, '--effort', $Effort, '--output-format', 'json', '--safe-mode', '--tools', '',
        '--system-prompt-file', $rulesFile)
    $r = Invoke-ClaudeCli -ClaudePath $ClaudePath -Arguments $argList -WorkDir $WorkDir -Prompt $Prompt
    Dbg "prompt: $($Prompt.Length) characters"
    if ($r.PSObject.Properties['total_cost_usd']) { Dbg "cost US`$$($r.total_cost_usd)" }
    $r
}

# Asks for an account that holds only what the source holds and loses none of the key facts. A reply that names things
# not in the source, or leaves out a key fact, is asked for again with those listed; if the last attempt still falls
# short, the best reply is kept and what it got wrong is reported.
function Get-GroundedReply([string]$Rules, [string]$Prompt, [string]$Source, $Facts = @(), [bool]$CheckTitle = $true) {
    $best = $null
    $ask = $Prompt
    for ($a = 1; $a -le $Attempts; $a++) {
        $r = Invoke-Model $Rules $ask
        if ($r.is_error -or -not $r.result) { Say "the AI call failed: $($r.result)" 'Yellow'; continue }
        $reply = ConvertFrom-SummaryReply ([string]$r.result)
        $checked = if ($CheckTitle) { $reply.Title + "`n" + $reply.Body } else { $reply.Body } # later parts' titles are thrown away
        $missing = @(Test-Grounded $checked $Source)
        $lost = @(Test-Coverage ($reply.Title + "`n" + $reply.Body) $Facts)
        $meta = @(Test-SourceMentions $reply.Body)
        $score = $missing.Count + $lost.Count + $meta.Count
        if (-not $best -or $score -lt $best.Score) { $best = [pscustomobject]@{ Title = $reply.Title; Body = $reply.Body; Missing = $missing; Lost = $lost; Meta = $meta; Score = $score } }
        if ($score -eq 0) { break }
        Dbg "not in the record: $($missing -join ', '); left out: $($lost -join ', '); talks about its sources: $($meta -join ', ')"
        $fix = @()
        if ($meta.Count -gt 0) { $fix += 'Your previous reply talked about its sources (' + ($meta -join ', ') + '). Write only about the events, as a chronicle.' }
        if ($missing.Count -gt 0) { $fix += 'Your previous reply named things the record does not hold: ' + ($missing -join ', ') + '. Use only what the record holds.' }
        if ($lost.Count -gt 0) { $fix += 'Your previous reply left out these events, which must be in the account: ' + ($lost -join '; ') + '.' }
        $ask = $Prompt + "`n`n# Correction`n" + ($fix -join "`n") + "`nWrite the account again."
    }
    $best
}

function Get-Players($Entries, [string]$Player) {
    $names = @($Player)
    foreach ($e in $Entries) { if ((Get-Field $e 'k') -eq 'group' -and (Get-Field $e 'who')) { $names += [string](Get-Field $e 'who') } }
    $names
}

function Save-Screenshots($c, $Session) {
    $shots = @()
    $dir = Join-Path (Get-CharDir $c) 'screenshots'
    foreach ($e in $Session.Entries) {
        if ((Get-Field $e 'k') -ne 'shot') { continue }
        $src = Find-Screenshot $ScreenshotDir ([long](Get-Field $e 't'))
        if (-not $src) { Dbg "no screenshot file for the entry at $(Get-Field $e 't')"; continue }
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $t = ConvertFrom-Epoch ([long](Get-Field $e 't'))
        $why = [string](Get-Field $e 'why')
        $name = $t.ToString('yyyy-MM-dd_HHmmss') + '-' + (($why -replace '[^a-zA-Z0-9]+', '-').Trim('-')) + [IO.Path]::GetExtension($src)
        $dest = Join-Path $dir $name
        if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $src -Destination $dest }
        $label = switch ($why) { 'level' { 'Level up' } 'boss' { 'Boss defeated' } 'dungeon' { 'Entering a dungeon' } 'new zone' { "First visit to $(Get-Field $e 'z')" } default { $why } }
        $shots += [pscustomobject]@{ Path = "../screenshots/$name"; Caption = "$label, $($t.ToString('HH:mm'))" }
    }
    $shots
}

function Invoke-SessionSummary($key, $c, $Session) {
    $player = [string]$c.Name
    $entries = $Session.Entries
    $windows = @(Get-InstanceWindows $Session)
    if ($windows.Count -gt 0) {
        $log = @(Read-ChatLogWindows $ChatLog $windows)
        Dbg "chat log: $($log.Count) lines in $($windows.Count) dungeon or raid windows"
        $entries = Merge-ChatLog $entries $log $player (Get-Players $entries $player)
    }
    $facts = Get-SessionFacts $Session $c.Level
    $header = Format-RecordHeader ([pscustomobject]@{ Name = $player; Race = $c.Race; Class = $c.Class; Faction = $c.Faction; Sex = $c['Sex'] }) $Session $facts
    $lines = @(Format-RecordLines $entries $player | ForEach-Object { "$($_.Time) $($_.Text)" })
    if ($lines.Count -eq 0) { $lines = @('(Nothing was recorded in this session beyond logging in.)') }
    $lore = Get-LoreText $LoreDir $facts.Zones $facts.Subzones
    $rules = Get-NarratorRules
    $parts = @(Split-RecordLines $lines $MaxPromptChars)
    $keyFacts = @(Get-KeyFacts $entries $player)
    $title = ''; $bodies = @(); $missing = @(); $lost = @(); $meta = @()
    for ($p = 0; $p -lt $parts.Count; $p++) {
        $partText = $parts[$p] -join "`n"
        # The key facts this part holds, so a long session summarised in parts loses none of them.
        $partFacts = @($keyFacts | Where-Object { $t = $_.Terms[0]; $t -and $partText.ToLowerInvariant().Contains($t.ToLowerInvariant()) })
        $prompt = New-SummaryPrompt $header $parts[$p] $lore ($p + 1) $parts.Count ($bodies -join "`n`n") @($partFacts | ForEach-Object { $_.What })
        $source = $header + "`n" + $partText + "`n" + $lore + "`n" + ($bodies -join "`n") + "`n$player"
        $reply = Get-GroundedReply $rules $prompt $source $partFacts ($p -eq 0)
        if (-not $reply) { return $false }
        if ($p -eq 0) { $title = $reply.Title }
        $bodies += $reply.Body
        $missing += $reply.Missing
        $lost += $reply.Lost
        $meta += $reply.Meta
    }
    if (-not $title) { $title = 'A session on ' + (ConvertFrom-Epoch $Session.First).ToString('d MMMM yyyy') }
    $shots = Save-Screenshots $c $Session
    $sessionsDir = Join-Path (Get-CharDir $c) 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsDir)) { New-Item -ItemType Directory -Force -Path $sessionsDir | Out-Null }
    $file = Get-SessionFileName $sessionsDir $Session.First
    $line = Format-SessionLine ([pscustomobject]@{ Name = $player }) $Session $facts
    Write-FileAtomic (Join-Path $sessionsDir $file) (Format-SessionMarkdown $title $line ($bodies -join "`n`n") $shots)
    # The exact record the AI was given, kept beside the summary so it can be checked against its source.
    Write-FileAtomic (Join-Path (Join-Path (Get-CharDir $c) 'records') ([IO.Path]::ChangeExtension($file, '.txt'))) ($header + "`n`n" + ($lines -join "`n") + "`n")
    $c.Sessions["$($Session.S)"] = [pscustomobject]@{ File = $file; Title = $title; First = $Session.First; Last = $Session.Last;
        Zones = @($facts.Zones); LevelFrom = $facts.LevelFrom; LevelTo = $facts.LevelTo; Parts = $parts.Count;
        Ungrounded = @($missing | Select-Object -Unique); Lost = @($lost | Select-Object -Unique); SourceMentions = @($meta | Select-Object -Unique) }
    if ($missing.Count -gt 0) { Say "$key`: '$title' names things not in the record: $(@($missing | Select-Object -Unique) -join ', ')" 'Yellow' }
    if ($lost.Count -gt 0) { Say "$key`: '$title' leaves out: $(@($lost | Select-Object -Unique) -join '; ')" 'Yellow' }
    Say "$key`: summarised session $($Session.S) as sessions\$file$(if ($parts.Count -gt 1) { " ($($parts.Count) parts)" })" 'Green'
    $true
}

function Update-Summaries {
    $running = Test-GameRunning
    $now = NowEpoch
    $updated = @()
    foreach ($key in @($State.Characters.Keys)) {
        $c = $State.Characters[$key]
        $sessions = @(Get-Sessions (Read-EventEntries (Join-Path (Get-CharDir $c) 'events')))
        for ($i = 0; $i -lt $sessions.Count; $i++) {
            $s = $sessions[$i]
            if ($c.Sessions.ContainsKey("$($s.S)")) { continue }
            if (-not (Test-SessionFinished $s ($i -eq $sessions.Count - 1) $now $running)) { Dbg "$key session $($s.S) is not finished yet"; continue }
            if (Invoke-SessionSummary $key $c $s) {
                $script:Changed = $true
                if ($updated -notcontains $key) { $updated += $key }
                Save-State
            }
        }
    }
    $updated
}

# Step 3: overview and export ---------------------------------------------------------------------------------------------

function Get-SessionDocs($c) {
    $dir = Join-Path (Get-CharDir $c) 'sessions'
    foreach ($k in @($c.Sessions.Keys | Sort-Object { [long]$c.Sessions[$_].First })) {
        $s = $c.Sessions[$k]
        $path = Join-Path $dir $s.File
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $doc = Read-SessionMarkdown (Read-FileText $path)
        [pscustomobject]@{ Number = [long]$k; S = $s; Title = $(if ($doc.Title) { $doc.Title } else { $s.Title }); Line = $doc.Line; Body = $doc.Body }
    }
}

function Update-Overview($key) {
    $c = $State.Characters[$key]
    $docs = @(Get-SessionDocs $c)
    if ($docs.Count -eq 0) { return }
    $path = Join-Path (Get-CharDir $c) 'overview.md'
    $all = ($docs | ForEach-Object { $_.Body }) -join "`n"
    $previous = ''
    $use = $docs
    if ($all.Length -gt $OverviewMaxChars -and (Test-Path -LiteralPath $path)) {
        $previous = (Read-SessionMarkdown (Read-FileText $path)).Body
        $since = [long]$c['OverviewUpTo']
        $use = @($docs | Where-Object { [long]$_.S.Last -gt $since })
    }
    $source = "$($c.Name)`n" + $previous + "`n" + (($use | ForEach-Object { "$($_.Title) $($_.Line) $($_.Body)" }) -join "`n")
    $reply = Get-GroundedReply (Get-OverviewRules) (New-OverviewPrompt ([string]$c.Name) $use $previous) $source
    if (-not $reply) { return }
    $text = (($reply.Title, $reply.Body) | Where-Object { $_ }) -join "`n`n"
    $from = (ConvertFrom-Epoch $docs[0].S.First).ToString('d MMMM yyyy')
    $to = (ConvertFrom-Epoch $docs[-1].S.Last).ToString('d MMMM yyyy')
    $span = "$($docs.Count) session$(if ($docs.Count -ne 1) { 's' }), " + $(if ($from -eq $to) { $from } else { "$from to $to" })
    Write-FileAtomic $path "# The journey of $($c.Name) so far`n`n*$span*`n`n$($text.Trim())`n"
    $c.OverviewUpTo = [long]$docs[-1].S.Last
    Say "$key`: overview updated" 'Green'
}

function Write-Export($key) {
    $c = $State.Characters[$key]
    $docs = @(Get-SessionDocs $c)
    if ($docs.Count -eq 0) { return }
    $overviewPath = Join-Path (Get-CharDir $c) 'overview.md'
    $overview = if (Test-Path -LiteralPath $overviewPath) { (Read-SessionMarkdown (Read-FileText $overviewPath)).Body } else { '' }
    Write-FileAtomic (Join-Path (Get-CharDir $c) 'journal.md') (New-JournalExport ([string]$c.Name) $overview $docs)
    Dbg "$key`: journal.md written"
}

# Step 4: the snapshot ---------------------------------------------------------------------------------------------------

# Thumbnails go in the add-on's Thumbs folder, one folder per character, named with letters, digits, - and _ only.
$ThumbsDir = Join-Path $AddOnDir 'Thumbs'
$script:ThumbsUsed = @{}

# The thumbnails of a session's screenshots (made when missing): Name, Thumb (game path), W, H.
function Get-Thumbnails($c, [string]$Body) {
    $folder = ([string]$c.Folder) -replace '[^A-Za-z0-9_-]+', '_'
    foreach ($shot in @(Get-SessionShots $Body)) {
        $src = Join-Path (Join-Path (Get-CharDir $c) 'screenshots') $shot.Name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $base = [IO.Path]::GetFileNameWithoutExtension($shot.Name) -replace '[^A-Za-z0-9_-]+', '_'
        $dest = Join-Path (Join-Path $ThumbsDir $folder) "$base.tga"
        $fit = New-Thumbnail $src $dest
        if (-not $fit) { Dbg "no thumbnail for $($shot.Name): not an image the app can read"; continue }
        $script:ThumbsUsed[[IO.Path]::GetFullPath($dest).ToLowerInvariant()] = $true
        [pscustomobject]@{ Name = $shot.Name; Thumb = "Interface\AddOns\JourneyMaster\Thumbs\$folder\$base"; W = $fit.W; H = $fit.H }
    }
}

# Deletes thumbnails no session in the snapshot uses any more, so the add-on folder stays small.
function Remove-UnusedThumbnails {
    if (-not (Test-Path -LiteralPath $ThumbsDir)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $ThumbsDir -Recurse -File -Filter '*.tga')) {
        if (-not $script:ThumbsUsed.ContainsKey($f.FullName.ToLowerInvariant())) { Remove-Item -LiteralPath $f.FullName; Dbg "thumbnail removed: $($f.Name)" }
    }
    $script:ThumbsUsed = @{}
}

function Publish-Snapshot {
    if (-not (Test-Path -LiteralPath $AddOnDir)) { Say "no add-on folder at $AddOnDir; the snapshot was not written" 'Yellow'; return }
    $chars = foreach ($key in @($State.Characters.Keys | Sort-Object)) {
        $c = $State.Characters[$key]
        $docs = @(Get-SessionDocs $c)
        [array]::Reverse($docs)
        $i = 0
        $sessions = foreach ($d in $docs) {
            $i++
            $rel = "data\journeys\$($c.Folder)\sessions\$($d.S.File)"
            $full = $i -le $FullSessions
            [pscustomobject]@{ S = $d.Number
                Title = $d.Title; First = $d.S.First; Last = $d.S.Last; Zones = @($d.S.Zones); LevelFrom = $d.S.LevelFrom; LevelTo = $d.S.LevelTo
                File = $rel; Text = $(if ($full) { Get-SnapshotText $d.Body } else { $null })
                Shots = $(if ($full) { @(Get-Thumbnails $c $d.Body) } else { @() }) }
        }
        [pscustomobject]@{ Key = $key; Confirmed = [long]$c.LastSeq; Sessions = @($sessions) }
    }
    Remove-UnusedThumbnails
    $State.Revision = [long]$State.Revision + 1
    $lua = New-JournalSnapshotLua ([pscustomobject]@{ Revision = $State.Revision; Written = (NowEpoch); Characters = @($chars) })
    $why = Test-JournalSnapshotLua $lua
    if ($why) { Say "the snapshot was not written: $why" 'Red'; return }
    Write-FileAtomic (Join-Path $AddOnDir 'JournalSnapshot.lua') $lua
    Save-State
    Say "snapshot $($State.Revision) written; /reload in game to read it" 'Green'
}

# Run ----------------------------------------------------------------------------------------------------------------------

$State = Read-State
if ($Export) {
    foreach ($key in @($State.Characters.Keys)) { Write-Export $key; Say "$key`: $(Join-Path (Get-CharDir $State.Characters[$key]) 'journal.md')" 'Green' }
    return
}
if (-not $ClaudePath) { $ClaudePath = (Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }

function Invoke-Once {
    $script:Changed = $false
    $sv = Find-SavedVariables
    if (-not $sv -or -not (Test-Path -LiteralPath $sv)) { Say 'no JourneyMaster.lua saved file yet: play with the add-on, then /reload or log out' 'Yellow'; return }
    Dbg "saved file: $sv"
    Import-SavedVariables $sv
    Save-State
    $updated = @(Update-Summaries)
    foreach ($key in $updated) {
        if (-not $NoOverview) { Update-Overview $key }
        Write-Export $key
    }
    $snap = Join-Path $AddOnDir 'JournalSnapshot.lua'
    $stale = (Test-Path -LiteralPath $snap) -and -not ((Read-FileText $snap) -match 'revision = [1-9]')
    if ($script:Changed -or $stale) { Publish-Snapshot }
    Save-State
}

if (-not $Watch) { Invoke-Once; return }

Say "watching for changes every $PollSeconds seconds; Ctrl+C stops" 'Cyan'
$lastStamp = ''
$lastCheck = 0
while ($true) {
    $sv = Find-SavedVariables
    $stamp = if ($sv -and (Test-Path -LiteralPath $sv)) { (Get-Item -LiteralPath $sv).LastWriteTimeUtc.Ticks } else { '' }
    $running = Test-GameRunning
    # Run when the saved file changes, and every few minutes anyway: a session also finishes by time, and a dungeon
    # session waits for the game to close.
    if ($stamp -ne $lastStamp -or ((NowEpoch) - $lastCheck) -gt 300 -or ($script:WasRunning -and -not $running)) {
        try { Invoke-Once } catch { Say "error: $_" 'Red' }
        $lastStamp = $stamp
        $lastCheck = NowEpoch
    }
    $script:WasRunning = $running
    Start-Sleep -Seconds $PollSeconds
}
