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
  4. Writes JournalSnapshot.lua into the add-on's folder, with thumbnails of the newest sessions' screenshots; the game
     shows it at the next /reload or login.
A session is finished at once when the player finishes it in the game, or once the game is closed and 30 minutes have
passed since its last entry (a logout alone does not finish it; while the game runs, the record on disk may be stale). With -Watch the app also reads the add-on's signals from the end of the chat log every 2 seconds
(Open screenshots, Finish session; see src\JourneyMaster\Signal.lua).
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
    [string]$Model = 'opus',   # default AI model (a claude alias); each character's choice under Settings in the game wins
    [string]$Effort = 'low',   # default effort level, likewise
    [int]$Attempts = 2,        # AI calls per summary when the first is refused or not grounded
    [int]$FullSessions = 10,   # newest sessions whose summary text goes into the snapshot; older ones by title only
    [int]$MaxPromptChars = 60000, # a record longer than this is summarised in parts
    [int]$OverviewMaxChars = 120000, # above this the overview is updated from the previous one and the new sessions
    [switch]$Watch,
    [int]$PollSeconds = 15,
    [switch]$Export,           # only write journal.md for every character, then stop
    [long]$Restore = 0,        # only put deleted session <n> back (of -Character, when more than one has it), then stop
    [string]$Character,        # the character key ("Name-Realm") for -Restore
    [switch]$NoOverview,
    [switch]$NoExplorer,
    [long]$SignalsFrom = -1,   # for tests: in a single run, also act on chat log signals from this byte on       # do not open File Explorer for the game's "Open screenshots on PC" button (for tests)
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
# The player's changes in the game, each keyed by session number: Titles (own titles), Deleted (time of the delete),
# SeenTitles and SeenDeleted (time of the newest rename or delete handled, so neither is applied twice).
$StateMaps = 'Sessions', 'Titles', 'Deleted', 'SeenTitles', 'SeenDeleted'

function New-CharState($key) {
    $c = @{ LastSeq = 0; Folder = (Get-SafeName $key) }
    foreach ($m in $StateMaps) { $c[$m] = @{} }
    $c
}

function Read-State {
    $s = @{ Revision = 0; Characters = @{} }
    if (Test-Path -LiteralPath $StateFile) {
        $j = (Read-FileText $StateFile) | ConvertFrom-Json
        $s.Revision = [long]$j.Revision
        foreach ($p in $j.Characters.PSObject.Properties) {
            $c = @{}
            foreach ($m in $StateMaps) { $c[$m] = @{} }
            foreach ($q in $p.Value.PSObject.Properties) {
                if ($StateMaps -contains $q.Name) {
                    if ($q.Value) { foreach ($r in $q.Value.PSObject.Properties) { $c[$q.Name][$r.Name] = $r.Value } }
                } else { $c[$q.Name] = $q.Value }
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

# Renaming and deleting sessions -------------------------------------------------------------------------------------------
# Changes made in the game arrive as signals (TITLE, DELETE) and again in the saved file; the time of each change
# (SeenTitles, SeenDeleted) keeps it from being applied twice. A deleted session's files go to
# <character>\deleted\session-<n>\, in the same layout (events\, sessions\, records\, screenshots\) plus session.json,
# its entry in the state, so -Restore can put everything back. The overview is left alone until the next summary.

function Get-DeletedDir($c, [long]$Number) { Join-Path (Join-Path (Get-CharDir $c) 'deleted') "session-$Number" }

function Move-IntoFolder([string]$Path, [string]$Folder) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Force -Path $Folder | Out-Null }
    Move-Item -LiteralPath $Path -Destination (Join-Path $Folder (Split-Path -Leaf $Path)) -Force
}

# Moves a session's summary, record, screenshots and entries to its deleted folder. Returns $true when it did.
function Remove-Session($key, $c, [long]$Number, [long]$T) {
    $k = "$Number"
    if ([long]$c.SeenDeleted[$k] -ge $T) { return $false }
    $c.SeenDeleted[$k] = $T
    $charDir = Get-CharDir $c
    $dir = Get-DeletedDir $c $Number
    $moved = @(Remove-SessionEvents (Join-Path $charDir 'events') $Number)
    if ($moved.Count -gt 0) { [void](Add-EventEntries (Join-Path $dir 'events') $moved) }
    $known = $c.Sessions[$k]
    if ($known) {
        $md = Join-Path (Join-Path $charDir 'sessions') $known.File
        if (Test-Path -LiteralPath $md) {
            foreach ($shot in @(Get-SessionShots (Read-FileText $md))) { Move-IntoFolder (Join-Path (Join-Path $charDir 'screenshots') $shot.Name) (Join-Path $dir 'screenshots') }
            Move-IntoFolder $md (Join-Path $dir 'sessions')
        }
        Move-IntoFolder (Join-Path (Join-Path $charDir 'records') ([IO.Path]::ChangeExtension($known.File, '.txt'))) (Join-Path $dir 'records')
        Write-FileAtomic (Join-Path $dir 'session.json') (ConvertTo-Json -InputObject $known -Depth 5)
        $c.Sessions.Remove($k)
    }
    $c.Deleted[$k] = $T
    Save-State
    Write-Export $key
    Say "$key`: session $Number deleted in the game; its files are in $dir" 'Cyan'
    $true
}

# Gives a session the player's own title: written into its file when summarised, else used when it is. Returns $true
# when it changed anything.
function Rename-Session($key, $c, [long]$Number, [long]$T, [string]$Title) {
    $k = "$Number"
    $Title = ($Title -replace '[\r\n|]+', ' ').Trim()
    if (-not $Title -or [long]$c.SeenTitles[$k] -ge $T) { return $false }
    $c.SeenTitles[$k] = $T
    $c.Titles[$k] = $Title
    $known = $c.Sessions[$k]
    if ($known) {
        $md = Join-Path (Join-Path (Get-CharDir $c) 'sessions') $known.File
        if (Test-Path -LiteralPath $md) { Write-FileAtomic $md (Set-SessionTitle (Read-FileText $md) $Title) }
        $known.Title = $Title
    }
    Save-State
    Write-Export $key
    Say "$key`: session $Number renamed in the game to '$Title'" 'Cyan'
    $true
}

# Puts a deleted session back (-Restore): its entries, summary, record and screenshots.
function Restore-Session($key, $c, [long]$Number) {
    $k = "$Number"
    $dir = Get-DeletedDir $c $Number
    if (-not (Test-Path -LiteralPath $dir)) { Say "$key`: no deleted session $Number in $(Split-Path -Parent $dir)" 'Yellow'; return $false }
    $charDir = Get-CharDir $c
    $json = Join-Path $dir 'session.json'
    $known = if (Test-Path -LiteralPath $json) { (Read-FileText $json) | ConvertFrom-Json } else { $null }
    if ($known -and (Test-Path -LiteralPath (Join-Path (Join-Path $charDir 'sessions') $known.File))) {
        Say "$key`: sessions\$($known.File) exists already; move it away first" 'Yellow'; return $false
    }
    $entries = @(Read-EventEntries (Join-Path $dir 'events'))
    if ($entries.Count -gt 0) { [void](Add-EventEntries (Join-Path $charDir 'events') $entries) }
    foreach ($sub in 'sessions', 'records', 'screenshots') {
        $from = Join-Path $dir $sub
        if (Test-Path -LiteralPath $from) { foreach ($f in @(Get-ChildItem -LiteralPath $from -File)) { Move-IntoFolder $f.FullName (Join-Path $charDir $sub) } }
    }
    if ($known) { $c.Sessions[$k] = $known }
    $c.Deleted.Remove($k)
    Remove-Item -LiteralPath $dir -Recurse -Force
    Save-State
    Write-Export $key
    Say "$key`: session $Number restored$(if ($known) { " as sessions\$($known.File)" } else { ' (not summarised yet)' })" 'Green'
    $true
}

# Step 1: new entries into the event files -------------------------------------------------------------------------------

function Import-SavedVariables([string]$Path) {
    $g = Read-SavedVariables $Path
    $db = $g['JourneyMasterDB']
    if (-not $db -or -not $db['characters']) { Dbg 'no characters in the saved file yet'; return }
    foreach ($key in @($db['characters'].Keys)) {
        $sv = $db['characters'][$key]
        if (-not $State.Characters.ContainsKey($key)) { $State.Characters[$key] = New-CharState $key }
        $c = $State.Characters[$key]
        foreach ($field in 'name', 'realm', 'race', 'class', 'faction', 'level', 'sex') {
            if ($null -ne $sv[$field]) { $c[(Get-Culture).TextInfo.ToTitleCase($field)] = $sv[$field] }
        }
        $entries = @($sv['entries'])
        $new = @($entries | Where-Object { $_ -is [Collections.IDictionary] -and [long]$_['i'] -gt [long]$c.LastSeq })
        if ($new.Count -gt 0) {
            # Entries of a deleted session go straight to its folder under deleted\.
            $kept = @($new | Where-Object { -not $c.Deleted.ContainsKey("$([long]$_['s'])") })
            foreach ($g in @($new | Where-Object { $c.Deleted.ContainsKey("$([long]$_['s'])") } | Group-Object { [long]$_['s'] })) {
                [void](Add-EventEntries (Join-Path (Get-DeletedDir $c ([long]$g.Name)) 'events') @($g.Group))
            }
            $n = if ($kept.Count -gt 0) { Add-EventEntries (Join-Path (Get-CharDir $c) 'events') $kept } else { 0 }
            $c.LastSeq = [long](($new | ForEach-Object { [long]$_['i'] } | Measure-Object -Maximum).Maximum)
            Say "$key`: $n new entries stored$(if ($kept.Count -lt $new.Count) { ", $($new.Count - $kept.Count) of deleted sessions put with them" })"
            $script:Changed = $true
        }
        # Renames and deletes made in the game, in case their signals were lost; each is applied only once.
        foreach ($p in (Get-SessionMap $sv['deleted']).GetEnumerator()) {
            if (Remove-Session $key $c ([long]$p.Key) ([long]$p.Value)) { $script:Changed = $true }
        }
        foreach ($p in (Get-SessionMap $sv['titles']).GetEnumerator()) {
            if ($p.Value -is [Collections.IDictionary] -and (Rename-Session $key $c ([long]$p.Key) ([long]$p.Value['t']) ([string]$p.Value['text']))) { $script:Changed = $true }
        }
        $settings = $sv['settings']
        # The AI choice in the saved file. The file is only as new as the last /reload or logout, and a choice made since
        # has already arrived as a signal, so a value is applied only when the file's value itself has changed.
        if ($settings -is [Collections.IDictionary]) {
            foreach ($pair in @(@('model', 'aiModel', 'SeenModel'), @('effort', 'aiEffort', 'SeenEffort'))) {
                $v = [string]$settings[$pair[1]]
                if ($v -and $v -ne [string]$c[$pair[2]]) { $c[$pair[2]] = $v; [void](Set-AISetting $c $pair[0] $v) }
            }
        }
        if ([long]$sv['dropped'] -gt [long]$c['Dropped']) {
            Say "$key`: the add-on dropped $($sv['dropped']) entries at its size cap" 'Yellow'
            $c.Dropped = [long]$sv['dropped']
        }
    }
}

# Signals from the add-on through the chat log (see src\JourneyMaster\Signal.lua) -----------------------------------------
# The add-on writes a signal line and about 48 KiB of padding, so the game writes the chat log to disk about a second
# later. In watch mode the app reads what was added to the file since its last look. It starts at the file's end, so
# signals sent while the app was not running are not acted on later.

$script:LogPos = -1     # bytes of the chat log already read; -1 until the first look
$script:LogRest = ''    # an unfinished last line, kept for the next look
$script:SignalsDone = @{}

function Read-Signals {
    if (-not (Test-Path -LiteralPath $ChatLog)) { return }
    $len = (Get-Item -LiteralPath $ChatLog).Length
    if ($script:LogPos -lt 0) { $script:LogPos = $len; return }
    if ($len -lt $script:LogPos) { $script:LogPos = 0; $script:LogRest = '' } # a new or emptied file
    if ($len -eq $script:LogPos) { return }
    $fs = New-Object IO.FileStream($ChatLog, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        [void]$fs.Seek($script:LogPos, 'Begin')
        $buf = New-Object byte[] ($len - $script:LogPos)
        $got = 0
        while ($got -lt $buf.Length) { $n = $fs.Read($buf, $got, $buf.Length - $got); if ($n -le 0) { break }; $got += $n }
    } finally { $fs.Dispose() }
    $script:LogPos += $got
    $lines = ($script:LogRest + [Text.Encoding]::UTF8.GetString($buf, 0, $got)) -split "`n"
    $script:LogRest = $lines[-1]
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        $line = $lines[$i]
        $sig = ConvertFrom-SignalLine $line
        if (-not $sig -or $script:SignalsDone.ContainsKey($sig.Id)) { continue }
        $script:SignalsDone[$sig.Id] = $true
        Invoke-Signal $sig
    }
}

function Invoke-Signal($Sig) {
    if (-not $State.Characters.ContainsKey($Sig.Key)) { Say "a signal for $($Sig.Key), a character the app has no record of yet" 'Yellow'; return }
    $c = $State.Characters[$Sig.Key]
    switch ($Sig.Kind) {
        'OPEN' { Open-SessionShots $Sig.Key $c $Sig.S }
        'SET' {
            $field, $value = ([string]$Sig.Arg) -split '=', 2
            if (Set-AISetting $c $field $value) { Save-State; Say "$($Sig.Key)`: AI $field set to $value in the game; used from the next summary" 'Cyan' }
            elseif (@('model', 'effort') -notcontains $field -or ($AIModels + $AIEfforts) -notcontains $value) { Say "$($Sig.Key)`: unknown AI setting $($Sig.Arg)" 'Yellow' }
        }
        { $_ -in 'TITLE', 'DELETE' } {
            $ch = ConvertFrom-SessionChange $Sig.Arg
            if (-not $ch -or (($Sig.Kind -eq 'TITLE') -ne ($null -ne $ch.Title))) { Say "$($Sig.Key)`: a $($Sig.Kind) signal the app cannot read: $($Sig.Arg)" 'Yellow'; return }
            $done = if ($Sig.Kind -eq 'TITLE') { Rename-Session $Sig.Key $c $ch.S $ch.T $ch.Title } else { Remove-Session $Sig.Key $c $ch.S $ch.T }
            if ($done) { Publish-Snapshot }
        }
        'END' { Say "$($Sig.Key)`: session $($Sig.S) finished in the game; it is summarised once the game writes the record (at /reload or logout)" 'Cyan' }
        default { Dbg "unknown signal $($Sig.Kind)" }
    }
}

# Step 2: summaries ------------------------------------------------------------------------------------------------------

# The AI model and effort: each character's choice from the game (Settings), else -Model and -Effort.
$AIModels = 'opus', 'sonnet', 'haiku', 'fable'
$AIEfforts = 'low', 'medium', 'high', 'xhigh', 'max'
$script:UseModel = $Model
$script:UseEffort = $Effort

# Records a character's choice of model or effort, if it is one of the allowed values. Returns $true when it changed.
function Set-AISetting($c, [string]$Field, [string]$Value) {
    $list = if ($Field -eq 'model') { $AIModels } else { $AIEfforts }
    if ($list -notcontains $Value) { return $false }
    $name = if ($Field -eq 'model') { 'Model' } else { 'Effort' }
    if ([string]$c[$name] -eq $Value) { return $false }
    $c[$name] = $Value
    $true
}

function Use-AISettings($c) {
    $script:UseModel = if ($c -and $c['Model']) { [string]$c['Model'] } else { $Model }
    $script:UseEffort = if ($c -and $c['Effort']) { [string]$c['Effort'] } else { $Effort }
    Dbg "AI: $script:UseModel, $script:UseEffort effort"
}

function Invoke-Model([string]$Rules, [string]$Prompt) {
    $rulesFile = Join-Path $WorkDir 'rules.md'
    [IO.File]::WriteAllText($rulesFile, $Rules, (New-Object Text.UTF8Encoding $false))
    $argList = @('-p', '--model', $script:UseModel, '--effort', $script:UseEffort, '--output-format', 'json', '--safe-mode', '--tools', '',
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
        if ($meta.Count -gt 0) { $fix += 'Your previous reply talked about its sources (' + ($meta -join ', ') + '). Write only about the events, as a novel.' }
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
    if ($c.Titles.ContainsKey("$($Session.S)")) { $title = [string]$c.Titles["$($Session.S)"] } # renamed in the game before its summary
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

$script:LateWarned = @{}

function Update-Summaries {
    $running = Test-GameRunning
    $now = NowEpoch
    $updated = @()
    foreach ($key in @($State.Characters.Keys)) {
        $c = $State.Characters[$key]
        $sessions = @(Get-Sessions (Read-EventEntries (Join-Path (Get-CharDir $c) 'events')))
        for ($i = 0; $i -lt $sessions.Count; $i++) {
            $s = $sessions[$i]
            if ($c.Sessions.ContainsKey("$($s.S)")) {
                # Entries after a session was summarised are kept in events\ but are in no summary. The finishing rules
                # (Test-SessionFinished) and the add-on's login check should prevent it; say so if it happens anyway.
                $late = @($s.Entries | Where-Object { [long](Get-Field $_ 't') -gt [long]$c.Sessions["$($s.S)"].Last -and (Get-Field $_ 'k') -ne 'logout' })
                if ($late.Count -gt 0 -and -not $script:LateWarned.ContainsKey("$key/$($s.S)")) {
                    $script:LateWarned["$key/$($s.S)"] = $true
                    Say "$key`: $($late.Count) entries arrived after session $($s.S) was summarised; they are kept in events\ but are not in its summary" 'Yellow'
                }
                continue
            }
            if (-not (Test-SessionFinished $s ($i -eq $sessions.Count - 1) $now $running)) { Dbg "$key session $($s.S) is not finished yet"; continue }
            Use-AISettings $c
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

# The names and write times of a character's session files and overview, to notice edits made on the PC.
function Get-FilesStamp($c) {
    $files = @(Get-ChildItem -LiteralPath (Join-Path (Get-CharDir $c) 'sessions') -Filter '*.md' -File -ErrorAction SilentlyContinue)
    $files += @(Get-Item -LiteralPath (Join-Path (Get-CharDir $c) 'overview.md') -ErrorAction SilentlyContinue)
    (@($files | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.LastWriteTimeUtc.Ticks)" }) -join '|')
}

function Write-Export($key) {
    $c = $State.Characters[$key]
    $docs = @(Get-SessionDocs $c)
    if ($docs.Count -eq 0) {
        # Every session deleted: the export, which the app writes, goes too.
        $old = Join-Path (Get-CharDir $c) 'journal.md'
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old }
        return
    }
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
        [pscustomobject]@{ Key = $key; Confirmed = [long]$c.LastSeq; Sessions = @($sessions)
            Deleted = @($c.Deleted.Keys | ForEach-Object { [long]$_ }); SeenTitle = $c.SeenTitles; SeenDelete = $c.SeenDeleted }
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
if ($Restore -gt 0) {
    $keys = @($State.Characters.Keys | Where-Object { (-not $Character -or $_ -eq $Character) -and (Test-Path -LiteralPath (Get-DeletedDir $State.Characters[$_] $Restore)) })
    if ($keys.Count -ne 1) {
        Say $(if ($keys.Count -eq 0) { "no deleted session $Restore$(if ($Character) { " for $Character" })" } else { "more than one character has a deleted session $Restore ($($keys -join ', ')): give -Character" }) 'Yellow'
        return
    }
    if (Restore-Session $keys[0] $State.Characters[$keys[0]] $Restore) { Publish-Snapshot }
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
        Use-AISettings $State.Characters[$key]
        if (-not $NoOverview) { Update-Overview $key }
        Write-Export $key
    }
    # Session files or the overview edited (or deleted) on the PC: the export and the game's snapshot follow.
    foreach ($key in @($State.Characters.Keys)) {
        $c = $State.Characters[$key]
        $stamp = Get-FilesStamp $c
        if ($c.ContainsKey('FilesStamp') -and [string]$c.FilesStamp -ne $stamp -and $updated -notcontains $key) {
            Say "$key`: session files changed on the PC; the journal export and the game's snapshot follow" 'Cyan'
            Write-Export $key
            $script:Changed = $true
        }
        $c.FilesStamp = $stamp
    }
    $snap = Join-Path $AddOnDir 'JournalSnapshot.lua'
    $stale = (Test-Path -LiteralPath $snap) -and -not ((Read-FileText $snap) -match 'revision = [1-9]')
    if ($script:Changed -or $stale) { Publish-Snapshot }
    Save-State
}

if (-not $Watch) {
    Invoke-Once
    if ($SignalsFrom -ge 0) { $script:LogPos = $SignalsFrom; Read-Signals }
    return
}

Say "watching for changes every $PollSeconds seconds, and for the game's buttons every 2 seconds; Ctrl+C stops" 'Cyan'
$lastStamp = ''
$lastCheck = 0
$lastPoll = 0
Read-Signals # the first look only notes where the chat log ends
while ($true) {
    # The game's buttons (Open screenshots, Finish session) arrive through the chat log within a few seconds.
    try { Read-Signals } catch { Say "error reading the chat log: $_" 'Red' }
    if (((NowEpoch) - $lastPoll) -ge $PollSeconds) {
        $lastPoll = NowEpoch
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
    }
    Start-Sleep -Seconds 2
}
