# JourneyMaster app: the work that has no side effects beyond the files it is given, so tests\app_harness.ps1 can
# check it offline. The script JourneyMaster.ps1 drives it.
# Windows PowerShell 5.1. Kept ASCII-only: Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
#
# Abbreviations: SV = SavedVariables (the Lua data file the game writes for the add-on). NPC = non-player character.
# AI = artificial intelligence. JSONL = JSON Lines (one JSON object per line).

Set-StrictMode -Version 2
$Utf8 = New-Object Text.UTF8Encoding $false
$Dot = [string][char]0x00B7

if (-not ('JourneyMasterLua' -as [type])) {
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'LuaReader.cs'))) -Language CSharp
}

# Files ----------------------------------------------------------------------------------------------------------------

# Reads a text file whole (UTF-8). Another process may be replacing it at that moment, which briefly locks it: the read
# allows sharing and is tried again a few times. (From RPMaster's Bridge.)
function Read-FileText([string]$Path) {
    for ($try = 1; ; $try++) {
        try {
            $fs = New-Object IO.FileStream($Path, 'Open', 'Read', 'ReadWrite, Delete')
            try {
                $sr = New-Object IO.StreamReader($fs, $Utf8, $true)
                return $sr.ReadToEnd()
            } finally { $fs.Dispose() }
        } catch [IO.IOException] {
            if ($try -ge 20) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

# Writes a whole file through a temporary file in the same folder, then replaces the old one, so a reader never sees
# half a file. If anything fails the old file is left as it was. (From RPMaster's Bridge.)
function Write-FileAtomic([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = $Utf8.GetBytes($Content)
        $fs = New-Object IO.FileStream($tmp, 'CreateNew', 'Write', 'None')
        try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

# Reads a SavedVariables file. Returns a Hashtable of its globals (tables as Hashtable or object[]).
function Read-SavedVariables([string]$Path) {
    $bytes = $null
    for ($try = 1; ; $try++) {
        try { $bytes = [IO.File]::ReadAllBytes($Path); break } catch [IO.IOException] {
            if ($try -ge 20) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
    [JourneyMasterLua]::Parse($bytes)
}

# A name safe as a folder or file name.
function Get-SafeName([string]$Name) {
    $bad = [IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) { if ($bad -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) } }
    $sb.ToString().Trim().TrimEnd('.')
}

function ConvertFrom-Epoch([long]$Epoch) { [DateTimeOffset]::FromUnixTimeSeconds($Epoch).LocalDateTime }
function ConvertTo-Epoch([DateTime]$Time) { [long]([DateTimeOffset]$Time).ToUnixTimeSeconds() }

# A field of an entry, whether the entry is a Hashtable (fresh from SV) or an object (read back from JSON); $null when absent.
function Get-Field($Entry, [string]$Name) {
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [Collections.IDictionary]) { if ($Entry.Contains($Name)) { return $Entry[$Name] } else { return $null } }
    $p = $Entry.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# Event files -------------------------------------------------------------------------------------------------------------

# Appends entries to <EventsDir>\<yyyy-MM-dd>.jsonl by the local date of each entry. Returns how many were written.
function Add-EventEntries([string]$EventsDir, $Entries) {
    if (-not (Test-Path -LiteralPath $EventsDir)) { New-Item -ItemType Directory -Force -Path $EventsDir | Out-Null }
    $byDate = @{}
    $n = 0
    foreach ($e in @($Entries)) {
        $day = (ConvertFrom-Epoch ([long](Get-Field $e 't'))).ToString('yyyy-MM-dd')
        if (-not $byDate.ContainsKey($day)) { $byDate[$day] = New-Object Collections.Generic.List[string] }
        $byDate[$day].Add((ConvertTo-Json -InputObject $e -Compress -Depth 5))
        $n++
    }
    foreach ($day in $byDate.Keys) {
        $path = Join-Path $EventsDir "$day.jsonl"
        [IO.File]::AppendAllText($path, (($byDate[$day] -join "`n") + "`n"), $Utf8)
    }
    $n
}

# Reads every event file of a character, oldest first, without duplicates (by entry number).
function Read-EventEntries([string]$EventsDir) {
    $out = New-Object Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $EventsDir)) { return $out.ToArray() }
    $seen = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $EventsDir -Filter '*.jsonl' | Sort-Object Name)) {
        $lines = @((Read-FileText $file.FullName) -split "`n" | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -eq 0) { continue }
        $items = $null
        try { $items = @(('[' + ($lines -join ',') + ']') | ConvertFrom-Json | ForEach-Object { $_ }) } catch { $items = $null }
        if ($null -eq $items) { $items = @(foreach ($l in $lines) { try { $l | ConvertFrom-Json } catch { } }) }
        foreach ($e in $items) {
            $i = [long](Get-Field $e 'i')
            if ($seen.ContainsKey($i)) { continue }
            $seen[$i] = $true
            $out.Add($e)
        }
    }
    @($out.ToArray() | Sort-Object { [long](Get-Field $_ 'i') })
}

# Removes the entries of session S from every event file in EventsDir (each file rewritten whole, or deleted when
# empty). Returns the entries removed.
function Remove-SessionEvents([string]$EventsDir, [long]$S) {
    $removed = New-Object Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $EventsDir)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $EventsDir -Filter '*.jsonl')) {
        $keep = New-Object Collections.Generic.List[string]
        $hit = $false
        foreach ($l in @((Read-FileText $file.FullName) -split "`n" | Where-Object { $_.Trim() -ne '' })) {
            $e = $null
            try { $e = $l | ConvertFrom-Json } catch { }
            if ($e -and [long](Get-Field $e 's') -eq $S) { $removed.Add($e); $hit = $true } else { $keep.Add($l.TrimEnd("`r")) }
        }
        if (-not $hit) { continue }
        if ($keep.Count -eq 0) { Remove-Item -LiteralPath $file.FullName } else { Write-FileAtomic $file.FullName (($keep -join "`n") + "`n") }
    }
    @($removed.ToArray())
}

# Renaming and deleting sessions in the game (see Signal.lua) ----------------------------------------------------------

# A signal's or saved file's change: "<s>=<t>" (DELETE) or "<s>=<t>=<title as UTF-8 in hex>" (TITLE). Returns S, T and
# Title ($null for a delete), or $null when it is not one.
function ConvertFrom-SessionChange([string]$Arg) {
    $m = [regex]::Match($Arg, '^(\d+)=(\d+)(?:=((?:[0-9a-fA-F]{2})*))?$')
    if (-not $m.Success) { return $null }
    $title = $null
    if ($m.Groups[3].Success) {
        $h = $m.Groups[3].Value
        $bytes = New-Object byte[] ($h.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }
        $title = $Utf8.GetString($bytes)
    }
    [pscustomobject]@{ S = [long]$m.Groups[1].Value; T = [long]$m.Groups[2].Value; Title = $title }
}

# A table of the saved file keyed by session number (c.titles, c.deleted) as a Hashtable: session number -> value. The
# reader turns a table keyed 1..n into an array.
function Get-SessionMap($Value) {
    $out = @{}
    if ($Value -is [Collections.IDictionary]) {
        foreach ($k in $Value.Keys) { if ("$k" -match '^\d+$') { $out[[long]"$k"] = $Value[$k] } }
    } elseif ($Value -is [Array]) {
        for ($i = 0; $i -lt $Value.Count; $i++) { if ($null -ne $Value[$i]) { $out[[long]($i + 1)] = $Value[$i] } }
    }
    $out
}

# A session file with its title (the first "# " heading) replaced, or added when it has none.
function Set-SessionTitle([string]$Text, [string]$Title) {
    $Title = ($Title -replace '[\r\n]+', ' ').Trim()
    $m = [regex]::Match($Text, '^(\s*)#[ \t]+[^\r\n]*')
    if ($m.Success) { return $Text.Substring(0, $m.Index) + $m.Groups[1].Value + "# $Title" + $Text.Substring($m.Index + $m.Length) }
    "# $Title`n`n" + $Text
}

# Sessions ----------------------------------------------------------------------------------------------------------------

# Groups entries into play sessions by their session number. Returns objects S, Entries, First, Last, oldest first.
function Get-Sessions($Entries) {
    $by = [ordered]@{}
    foreach ($e in @($Entries)) {
        $s = [long](Get-Field $e 's')
        if (-not $by.Contains($s)) { $by[$s] = New-Object Collections.Generic.List[object] }
        $by[$s].Add($e)
    }
    $out = foreach ($s in $by.Keys) {
        $list = @($by[$s] | Sort-Object { [long](Get-Field $_ 't') }, { [long](Get-Field $_ 'i') })
        [pscustomobject]@{ S = $s; Entries = $list; First = [long](Get-Field $list[0] 't'); Last = [long](Get-Field $list[-1] 't') }
    }
    @($out | Sort-Object S)
}

# True when the dungeon or raid windows of a session hold anything (they need the chat log).
function Test-HasInstance($Session) {
    foreach ($e in $Session.Entries) { if ((Get-Field $e 'k') -eq 'enter') { return $true } }
    $false
}

# Whether a session is over and ready to summarise:
# - The player finished it (an "end" entry, from /jm end or Finish session): at once. Finishing also forces the chat log
#   to disk, so a dungeon in it need not wait.
# - A later session of the same character exists: the add-on never adds to a session after starting the next one.
# - It is the character's latest session: only once the game is closed and 30 minutes have passed since its last entry.
#   While the game runs, the record on disk is only as new as the last /reload or logout, so its age says nothing about
#   whether the player is still playing; judging by it could summarise a session in progress and lose the rest of it.
#   A logout alone does not end a session: logging back in within 30 minutes continues it (owner's decision,
#   13 November 2026).
# A finished session with a dungeon or raid still waits for the game to close, because the chat log reaches disk at exit,
# unless it ended more than two hours ago.
function Test-SessionFinished($Session, [bool]$IsLatest, [long]$Now, [bool]$GameRunning, [int]$GapSeconds = 1800) {
    if ((Get-Field $Session.Entries[-1] 'k') -eq 'end') { return $true }
    $idle = $Now - $Session.Last
    if ($IsLatest -and ($GameRunning -or $idle -le $GapSeconds)) { return $false }
    if ($GameRunning -and (Test-HasInstance $Session) -and $idle -lt 7200) { return $false }
    $true
}

# Facts about a session for its header and the snapshot: zones in order of first visit, levels, and the last
# instance-free zone.
function Get-SessionFacts($Session, $StartLevel) {
    $zones = New-Object Collections.Generic.List[string]
    $subs = New-Object Collections.Generic.List[string]
    $levelFrom = $null; $levelTo = $null
    foreach ($e in $Session.Entries) {
        $z = Get-Field $e 'z'
        if ($z -and -not $zones.Contains([string]$z)) { $zones.Add([string]$z) }
        $sz = Get-Field $e 'sz'
        if ($sz -and -not $subs.Contains([string]$sz)) { $subs.Add([string]$sz) }
        $k = Get-Field $e 'k'
        if ($k -eq 'login' -and $null -eq $levelFrom -and (Get-Field $e 'lvl')) { $levelFrom = [int](Get-Field $e 'lvl') }
        if ($k -eq 'level') {
            if ($null -eq $levelFrom) { $levelFrom = [int](Get-Field $e 'level') - 1 }
            $levelTo = [int](Get-Field $e 'level')
        }
    }
    if ($null -eq $levelFrom -and $StartLevel) { $levelFrom = [int]$StartLevel }
    if ($null -eq $levelTo) { $levelTo = $levelFrom }
    [pscustomobject]@{ Zones = $zones.ToArray(); Subzones = $subs.ToArray(); LevelFrom = $levelFrom; LevelTo = $levelTo }
}

# The chat log ------------------------------------------------------------------------------------------------------------

# Dungeon and raid windows of a session: Start, End (epoch seconds) and Name, from its enter and leave entries. A window
# with no leave ends at the session's last entry.
function Get-InstanceWindows($Session) {
    $out = New-Object Collections.Generic.List[object]
    $open = $null
    foreach ($e in $Session.Entries) {
        $k = Get-Field $e 'k'
        if ($k -eq 'enter') {
            if ($open) { $open.End = [long](Get-Field $e 't'); $out.Add($open) }
            $open = [pscustomobject]@{ Start = [long](Get-Field $e 't'); End = $Session.Last; Name = [string](Get-Field $e 'inst'); Kind = [string](Get-Field $e 'itype') }
        } elseif ($k -eq 'leave' -and $open) {
            $open.End = [long](Get-Field $e 't')
            $out.Add($open)
            $open = $null
        }
    }
    if ($open) { $out.Add($open) }
    $out.ToArray()
}

# The epoch time of a chat log stamp ("11/8 22:32:12.551", PC local time, no year). The year is the one that puts the
# moment nearest to `Near` (epoch seconds), so a session over New Year still works.
function ConvertFrom-ChatLogStamp([int]$Month, [int]$Day, [int]$H, [int]$M, [int]$S, [long]$Near) {
    $nearTime = ConvertFrom-Epoch $Near
    $best = $null; $bestGap = [double]::MaxValue
    foreach ($y in @(($nearTime.Year - 1), $nearTime.Year, ($nearTime.Year + 1))) {
        try { $t = New-Object DateTime $y, $Month, $Day, $H, $M, $S, ([DateTimeKind]::Local) } catch { continue }
        $gap = [Math]::Abs(($t - $nearTime).TotalSeconds)
        if ($gap -lt $bestGap) { $best = $t; $bestGap = $gap }
    }
    if ($null -eq $best) { return $null }
    ConvertTo-Epoch $best
}

$ChatLogLine = [regex]'^(\d{1,2})/(\d{1,2}) (\d{2}):(\d{2}):(\d{2})\.\d{3}  (.*)$'

# One chat log line, parsed into an event the summary can use, or $null for lines it does not need (numbered channels,
# whispers, crafting, RPMaster's signal lines, system chatter). Kinds: chat (party, raid, instance, say, yell),
# said (say or yell by someone who may be a player or an NPC), death (Who, or the player), kill (Name), loot (Item, N),
# quest (Act accept or done, Title), group (Act join or leave, Who).
function ConvertFrom-ChatLogLine([string]$Line, [long]$Near) {
    $m = $ChatLogLine.Match($Line)
    if (-not $m.Success) { return $null }
    $t = ConvertFrom-ChatLogStamp ([int]$m.Groups[1].Value) ([int]$m.Groups[2].Value) ([int]$m.Groups[3].Value) ([int]$m.Groups[4].Value) ([int]$m.Groups[5].Value) $Near
    if ($null -eq $t) { return $null }
    $body = $m.Groups[6].Value
    # Hidden lines other add-ons write into the log, never chat: RPMaster's transcripts, padding, signals and draft
    # requests (RPMT, RPMP, RPMS, RPMD), its old ClaudeCapture probe (PAD, BEGIN), and JourneyMaster's own signals.
    if ($body -match '^(RPM[A-Z]*|JM[SP]|PAD|BEGIN):') { return $null }
    $g = [regex]::Match($body, '^\|Hchannel:(PARTY|RAID|INSTANCE_CHAT|RAID_WARNING)\|h\[([^\]]+)\]\|h (.+?): (.*)$')
    if ($g.Success) {
        $ch = switch ($g.Groups[1].Value) { 'PARTY' { 'party' } 'INSTANCE_CHAT' { 'instance' } default { 'raid' } }
        return [pscustomobject]@{ T = $t; Kind = 'chat'; Ch = $ch; Who = $g.Groups[3].Value; Text = $g.Groups[4].Value }
    }
    if ($body.StartsWith('|H') -or $body -match '^\[\d+\. ' -or $body -match '^To \S' -or $body -match ' whispers: ') { return $null }
    $g = [regex]::Match($body, "^([^:]{1,60}?) (says|yells): (.*)$")
    if ($g.Success) { return [pscustomobject]@{ T = $t; Kind = 'said'; Ch = $(if ($g.Groups[2].Value -eq 'yells') { 'yell' } else { 'say' }); Who = $g.Groups[1].Value; Text = $g.Groups[3].Value } }
    if ($body -eq 'You died.') { return [pscustomobject]@{ T = $t; Kind = 'death'; Who = $null } }
    $g = [regex]::Match($body, '^([^,:]{1,60}) has died\.$')
    if ($g.Success) { return [pscustomobject]@{ T = $t; Kind = 'death'; Who = $g.Groups[1].Value } }
    $g = [regex]::Match($body, '^(.{1,60}?) dies, you gain \d+ experience')
    if ($g.Success) { return [pscustomobject]@{ T = $t; Kind = 'kill'; Name = $g.Groups[1].Value } }
    $g = [regex]::Match($body, '^You have slain (.{1,60})!$')
    if ($g.Success) { return [pscustomobject]@{ T = $t; Kind = 'kill'; Name = $g.Groups[1].Value } }
    $g = [regex]::Match($body, '^You receive loot: (.+?)(?:x(\d+))?\.?$')
    if ($g.Success) { return [pscustomobject]@{ T = $t; Kind = 'loot'; Item = $g.Groups[1].Value; N = $(if ($g.Groups[2].Success) { [int]$g.Groups[2].Value } else { 1 }) } }
    $g = [regex]::Match($body, '^Quest accepted: (.+)$')
    if ($g.Success) { return [pscustomobject]@{ T = $t; Kind = 'quest'; Act = 'accept'; Title = $g.Groups[1].Value } }
    $g = [regex]::Match($body, '^(.{1,80}) completed\.$')
    if ($g.Success) { return [pscustomobject]@{ T = $t; Kind = 'quest'; Act = 'done'; Title = $g.Groups[1].Value } }
    $g = [regex]::Match($body, '^(.{1,60}) (joins|leaves) the (party|raid group)\.$')
    if ($g.Success) { return [pscustomobject]@{ T = $t; Kind = 'group'; Act = $(if ($g.Groups[2].Value -eq 'joins') { 'join' } else { 'leave' }); Who = $g.Groups[1].Value } }
    $null
}

# A signal from the add-on in a chat log line ("JMS:<id>:<KIND>:<arg>:<character key>", see Signal.lua): Id, Kind, Arg
# (a session number, or "field=value" for SET), S (the arg as a number, 0 when it is not one) and Key, or $null for any
# other line. Anchored to the start of the line's text, so a player who says "JMS:..." in
# chat (logged as "<name> says: JMS:...") cannot send one.
$SignalLine = [regex]'^(?:\d{1,2}/\d{1,2} \d{2}:\d{2}:\d{2}\.\d{3}\s+)?JMS:([^:]+):([A-Z]+):([^:]*):(.+)$'
function ConvertFrom-SignalLine([string]$Line) {
    $m = $SignalLine.Match($Line.TrimEnd("`r"))
    if (-not $m.Success) { return $null }
    $arg = $m.Groups[3].Value
    [pscustomobject]@{ Id = $m.Groups[1].Value; Kind = $m.Groups[2].Value; Arg = $arg
        S = $(if ($arg -match '^\d+$') { [long]$arg } else { 0 }); Key = $m.Groups[4].Value }
}

# The chat log lines that fall in any of the windows (a few seconds of slack either side), parsed. Lines are matched
# on their date and hour ("11/8 21:") first, so only the lines near a window are parsed and a large file is read quickly.
function Read-ChatLogWindows([string]$Path, $Windows) {
    $out = New-Object Collections.Generic.List[object]
    if (-not $Path -or -not (Test-Path -LiteralPath $Path) -or @($Windows).Count -eq 0) { return $out.ToArray() }
    $prefixes = @{}
    foreach ($w in $Windows) {
        for ($t = $w.Start - 3600; $t -le $w.End + 3600; $t += 1800) {
            $d = ConvertFrom-Epoch $t
            $prefixes["$($d.Month)/$($d.Day) $($d.ToString('HH')):"] = $true
        }
    }
    $fs = New-Object IO.FileStream($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        $sr = New-Object IO.StreamReader($fs, $Utf8, $true)
        while ($null -ne ($line = $sr.ReadLine())) {
            $colon = $line.IndexOf(':')
            if ($colon -lt 5 -or $colon -gt 9 -or -not $prefixes.ContainsKey($line.Substring(0, $colon + 1))) { continue }
            foreach ($w in $Windows) {
                $p = ConvertFrom-ChatLogLine $line $w.Start
                if ($p -and $p.T -ge ($w.Start - 5) -and $p.T -le ($w.End + 5)) { $p | Add-Member -NotePropertyName Window -NotePropertyValue $w.Name; $out.Add($p); break }
            }
        }
    } finally { $fs.Dispose() }
    $out.ToArray()
}

# Turns chat log lines from dungeon and raid windows into entries for the session. Speech already recorded by the add-on
# is not repeated. Kills and the player's own loot are gathered into one entry per window. The player's own death from
# the log is added only when the add-on recorded none near that time. Players: names known to be players (the
# character, group members, party speakers), so "says" lines can be told apart from NPC speech.
function Merge-ChatLog($Entries, $LogLines, [string]$Player, $Players) {
    $known = @{}
    foreach ($p in @($Players)) { if ($p) { $known[[string]$p] = $true } }
    if ($Player) { $known[$Player] = $true }
    foreach ($l in @($LogLines)) { if ($l.Kind -eq 'chat') { $known[$l.Who] = $true } }
    $spoken = @{}
    $deaths = New-Object Collections.Generic.List[long]
    foreach ($e in @($Entries)) {
        $k = Get-Field $e 'k'
        if ($k -eq 'chat' -or $k -eq 'npc') { $spoken["$(Get-Field $e 'who')`n$(Get-Field $e 'text')"] = [long](Get-Field $e 't') }
        if ($k -eq 'death') { $deaths.Add([long](Get-Field $e 't')) }
    }
    $added = New-Object Collections.Generic.List[object]
    $kills = [ordered]@{}; $loot = [ordered]@{}
    foreach ($l in @($LogLines)) {
        $win = $l.Window
        switch ($l.Kind) {
            { $_ -eq 'chat' -or $_ -eq 'said' } {
                $key = "$($l.Who)`n$($l.Text)"
                if ($spoken.ContainsKey($key) -and [Math]::Abs($spoken[$key] - $l.T) -le 10) { break }
                # Group members are players. Anyone else saying or yelling may be an NPC (a boss) or a passing player:
                # the log does not say, so the record does not either.
                $isPlayer = $l.Kind -eq 'chat' -or $known.ContainsKey($l.Who) -or $known.ContainsKey(($l.Who -split ' ')[0])
                $added.Add([ordered]@{ t = $l.T; k = $(if ($isPlayer) { 'chat' } else { 'said' }); ch = $l.Ch; who = $l.Who; text = $l.Text; z = $win; src = 'log' })
            }
            'death' {
                if ($null -eq $l.Who) {
                    $near = $false
                    foreach ($d in $deaths) { if ([Math]::Abs($d - $l.T) -le 15) { $near = $true } }
                    if (-not $near) { $added.Add([ordered]@{ t = $l.T; k = 'death'; z = $win; src = 'log' }) }
                } else {
                    $added.Add([ordered]@{ t = $l.T; k = 'death'; who = $l.Who; z = $win; src = 'log' })
                }
            }
            # Kills and loot are gathered into one entry per window, placed at the last of them, so the account never
            # suggests that all of it had happened by the first.
            'kill' { if (-not $kills.Contains($win)) { $kills[$win] = [ordered]@{ T = $l.T; Names = [ordered]@{} } }; $kills[$win].T = $l.T; $kills[$win].Names[$l.Name] = 1 + [int]$kills[$win].Names[$l.Name] }
            'loot' { if (-not $loot.Contains($win)) { $loot[$win] = [ordered]@{ T = $l.T; Items = [ordered]@{} } }; $loot[$win].T = $l.T; $loot[$win].Items[$l.Item] = $l.N + [int]$loot[$win].Items[$l.Item] }
            'quest' { $added.Add([ordered]@{ t = $l.T; k = 'quest'; act = $(if ($l.Act -eq 'accept') { 'accept' } else { 'done' }); title = $l.Title; z = $win; src = 'log' }) }
            'group' { $added.Add([ordered]@{ t = $l.T; k = 'group'; act = $l.Act; who = $l.Who; z = $win; src = 'log' }) }
        }
    }
    foreach ($win in $kills.Keys) {
        $list = @(foreach ($n in $kills[$win].Names.Keys) { if ($kills[$win].Names[$n] -gt 1) { "$n x$($kills[$win].Names[$n])" } else { $n } })
        $added.Add([ordered]@{ t = $kills[$win].T; k = 'kills'; list = ($list -join ', '); z = $win; src = 'log' })
    }
    foreach ($win in $loot.Keys) {
        $list = @(foreach ($n in $loot[$win].Items.Keys) { if ($loot[$win].Items[$n] -gt 1) { "$n x$($loot[$win].Items[$n])" } else { $n } })
        $added.Add([ordered]@{ t = $loot[$win].T; k = 'logloot'; list = ($list -join ', '); z = $win; src = 'log' })
    }
    $all = @(@($Entries) + @($added.ToArray()))
    @($all | Sort-Object { [long](Get-Field $_ 't') })
}

# The record sent to the AI ------------------------------------------------------------------------------------------------

function Format-Money([long]$Copper) {
    $g = [Math]::Floor($Copper / 10000); $s = [Math]::Floor($Copper / 100) % 100; $c = $Copper % 100
    $parts = @()
    if ($g -gt 0) { $parts += "$g gold" }
    if ($s -gt 0) { $parts += "$s silver" }
    if ($c -gt 0 -or $parts.Count -eq 0) { $parts += "$c copper" }
    $parts -join ' '
}

function Format-Quote($Text) { '"' + ([string]$Text -replace '"', "'") + '"' }

# One line of the record for an entry, or $null for entries the summary does not need (screenshots, reloads).
function Format-Entry($Entry, [string]$Player) {
    $f = { param($n) Get-Field $Entry $n }
    $who = & $f 'who'
    $k = & $f 'k'
    $fromLog = if ((& $f 'src') -eq 'log') { ' (from the chat log)' } else { '' }
    switch ($k) {
        'login' { if (& $f 'reload') { return $null } else { return "$Player logged in." } }
        'logout' { return "$Player logged out." }
        'zone' { $p = & $f 'z'; if (& $f 'sz') { $p = "$p, $(& $f 'sz')" }; return "$Player arrived in $p." }
        'enter' { return "$Player entered the $(if ((& $f 'itype') -eq 'raid') { 'raid' } else { 'dungeon' }) $(& $f 'inst'). Inside it the game hides chat from the add-on; lines marked 'from the chat log' fill that gap." }
        'leave' { return "$Player left $(& $f 'inst')." }
        'quest' {
            $title = Format-Quote (& $f 'title')
            switch (& $f 'act') {
                'accept' {
                    $line = "$Player accepted the quest $title" + $(if (& $f 'giver') { " from $(& $f 'giver')" } else { '' }) + "$fromLog."
                    if (& $f 'text') { $line += " Quest text: $(Format-Quote (& $f 'text'))" }
                    if (& $f 'obj') { $line += " Objective: $(Format-Quote (& $f 'obj'))" }
                    return $line
                }
                'turnin' {
                    $extra = @()
                    if ((& $f 'xp') -gt 0) { $extra += "$(& $f 'xp') experience" }
                    if ((& $f 'money') -gt 0) { $extra += (Format-Money ([long](& $f 'money'))) }
                    $line = "$Player handed in the quest $title" + $(if (& $f 'giver') { " to $(& $f 'giver')" } else { '' }) + $(if ($extra) { " (reward: $($extra -join ', '))" } else { '' }) + '.'
                    if (& $f 'reward') { $line += " Hand-in text: $(Format-Quote (& $f 'reward'))" }
                    return $line
                }
                'done' { return "The quest $title was completed$fromLog." }
            }
            return "Quest $title."
        }
        # Speech of NPCs, bosses and pets (a warlock's minions speak as NPCs) is background only: the narrator rules say
        # not to report it (owner's decision, 13 November 2026).
        'npc' {
            $verb = switch (& $f 'ch') { 'yell' { 'yelled' } 'whisper' { 'whispered' } 'emote' { 'emote' } default { 'said' } }
            if ($verb -eq 'emote') { return "[background] (NPC emote$fromLog) $(& $f 'text')" }
            return "[background] $who (NPC) $verb$fromLog`: $(Format-Quote (& $f 'text'))"
        }
        'said' {
            $verb = if ((& $f 'ch') -eq 'yell') { 'yelled' } else { 'said' }
            return "[background] $who (an NPC, or a player outside the group) $verb$fromLog`: $(Format-Quote (& $f 'text'))"
        }
        'chat' {
            $ch = & $f 'ch'
            $role = if ($who -eq $Player) { "$who (the character)" } else { "$who (player)" }
            if ($ch -eq 'emote') {
                if (& $f 'stock') { return "(emote) $(& $f 'text')" }
                return "(emote) $who $(& $f 'text')"
            }
            $how = switch ($ch) { 'say' { 'said' } 'yell' { 'yelled' } 'party' { 'said in party chat' } 'raid' { 'said in raid chat' } 'instance' { 'said in instance chat' } default { "said ($ch)" } }
            return "$role $how$fromLog`: $(Format-Quote (& $f 'text'))"
        }
        'gap' { return "[$(& $f 'n') $(& $f 'what') here were hidden from the add-on by the game.]" }
        'death' {
            if ($who) { return "$who (group member) died$fromLog." }
            $place = & $f 'z'
            $line = "$Player died in $place$fromLog"
            if (& $f 'killer') {
                $line += ", killed by $(& $f 'killer')"
                if ((& $f 'spell') -and (& $f 'spell') -ne 'melee') { $line += " ($(& $f 'spell'))" }
            }
            return "$line."
        }
        'boss' { return "$Player's group defeated $(& $f 'name')." }
        'kills' { return "Creatures killed in $(& $f 'z') during this visit, up to now (from the chat log): $(& $f 'list')." }
        'logloot' { return "$Player's own loot in $(& $f 'z') during this visit, up to now (from the chat log): $(& $f 'list')." }
        'loot' { $n = & $f 'n'; return "$Player looted $(& $f 'item')" + $(if ($n -gt 1) { " x$n" } else { '' }) + '.' }
        'gear' { return "$Player equipped $(& $f 'item') ($(& $f 'slot'))." }
        'money' { return "$Player's money reached $(Format-Money ([long](& $f 'copper')))." }
        'level' {
            $line = "$Player reached level $(& $f 'level')"
            if (& $f 'played') { $line += " after $([Math]::Round([long](& $f 'played') / 3600.0, 1)) hours played in total" }
            return "$line."
        }
        'skill' { return "$Player's $(& $f 'skill') skill reached $(& $f 'value')." }
        'rep' { return "$Player became $(& $f 'standing') with $(& $f 'faction')." }
        'group' { return "$who $(if ((& $f 'act') -eq 'join') { 'joined' } else { 'left' }) the group$fromLog." }
        'note' { return "Note written by the player: $(Format-Quote (& $f 'text'))" }
        'shot' { return $null }
    }
    $null
}

# What a screenshot shows, from its entry's reason: "Level up", "First visit to Duskwood".
function Get-ShotLabel($Entry) {
    $why = [string](Get-Field $Entry 'why')
    $z = Get-Field $Entry 'z'
    switch ($why) {
        'level' { 'Level up' } 'boss' { 'Boss defeated' } 'dungeon' { 'Entering a dungeon' }
        'new zone' { "First visit to $z" } 'zone' { "Exploring $z" } default { $why }
    }
}

# The record of a session as lines "HH:mm Text". Returns objects Time and Text (Text without the time).
# Pictures: screenshot entry time (t) -> picture number, for the screenshots the session file will show. Each becomes
# a line "[picture N: caption]" so the narrator can place the picture in the account (owner's decision, 13 November
# 2026). Screenshots not in Pictures are left out.
function Format-RecordLines($Entries, [string]$Player, [hashtable]$Pictures = @{}) {
    $out = New-Object Collections.Generic.List[object]
    foreach ($e in @($Entries)) {
        $text = Format-Entry $e $Player
        if ((Get-Field $e 'k') -eq 'shot') {
            $n = $Pictures["$(Get-Field $e 't')"]
            if ($n) { $text = "[picture $n`: $(Get-ShotLabel $e)]" }
        }
        if ($text) { $out.Add([pscustomobject]@{ Time = (ConvertFrom-Epoch ([long](Get-Field $e 't'))).ToString('HH:mm'); Text = $text }) }
    }
    $out.ToArray()
}

# "male" or "female" from the game's UnitSex value (2 male, 3 female), or '' when not known.
function Get-SexWord($Character) {
    $p = $Character.PSObject.Properties['Sex']
    if (-not $p) { return '' }
    switch ([int]$p.Value) { 2 { 'male' } 3 { 'female' } default { '' } }
}

# The facts at the top of the record: who, when, where.
function Format-RecordHeader($Character, $Session, $Facts) {
    $start = ConvertFrom-Epoch $Session.First
    $end = ConvertFrom-Epoch $Session.Last
    $lines = @(
        "Character: $($Character.Name)" + $(if ($Character.Race -or $Character.Class) { (", a $(Get-SexWord $Character) $($Character.Race) $($Character.Class)" -replace '\s+', ' ') } else { '' }) + $(if ($Character.Faction) { " of the $($Character.Faction)" } else { '' }) + '.',
        "Play session: $($start.ToString('dddd d MMMM yyyy, HH:mm')) to $($end.ToString('HH:mm'))" + $(if ($end.Date -ne $start.Date) { " on $($end.ToString('d MMMM'))" } else { '' }) + '.'
    )
    if ($Facts.LevelFrom) {
        if ($Facts.LevelTo -and $Facts.LevelTo -ne $Facts.LevelFrom) { $lines += "Level: $($Facts.LevelFrom) to $($Facts.LevelTo)." } else { $lines += "Level: $($Facts.LevelFrom)." }
    }
    if ($Facts.Zones.Count -gt 0) { $lines += "Zones, in order of first visit: $($Facts.Zones -join ', ')." }
    $lines -join "`n"
}

# Lore: the overview of each zone visited and the sections of the subzones visited, from the lore folder RPMaster uses
# (zones\<zone-name>.md). Only so that places are named and described correctly. At most MaxChars in all.
function Get-LoreText([string]$LoreDir, $Zones, $Subzones, [int]$MaxChars = 12000) {
    if (-not $LoreDir -or -not (Test-Path -LiteralPath $LoreDir)) { return '' }
    $parts = New-Object Collections.Generic.List[string]
    $total = 0
    foreach ($z in @($Zones)) {
        $slug = (([string]$z).ToLowerInvariant() -replace "['']", '' -replace '[^a-z0-9]+', '-').Trim('-')
        $file = Join-Path $LoreDir "zones\$slug.md"
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $text = Read-FileText $file
        $sections = [regex]::Split($text, '(?m)^(?=## )')
        $keep = @($sections[0].Trim())
        foreach ($sec in $sections | Select-Object -Skip 1) {
            $title = ($sec -split "`n")[0].Substring(3).Trim()
            if (@($Subzones) -contains $title) { $keep += $sec.Trim() }
        }
        $piece = $keep -join "`n`n"
        if ($total + $piece.Length -gt $MaxChars) { $piece = $piece.Substring(0, [Math]::Max(0, $MaxChars - $total)) }
        if ($piece) { $parts.Add($piece); $total += $piece.Length }
        if ($total -ge $MaxChars) { break }
    }
    $parts -join "`n`n"
}

# The narrator ------------------------------------------------------------------------------------------------------------

# The narrator's rules (the system prompt), the same for every character: a novel's voice (owner's decision,
# 13 November 2026, replacing the plan's plain chronicle), held to the record by the faithfulness rules.
function Get-NarratorRules {
@'
You write one chapter of a novel: the story of one play session of a character in World of Warcraft (the WoW: Forever server). You are given the session's record, written by an add-on and in places filled from the game's chat log.

Style and tone:
- Write it like a novel: third person, past tense, flowing narrative prose with a sense of place, pace and scene. British English.
- Set each scene: where the character was and what the place was like, drawn from the zone names and the lore notes. Let the events carry the story, with turning points (a level, a death, a dungeon, a hard-won quest) given their weight.
- Spoken words of other players may appear as dialogue in quotation marks, exactly as recorded.
- No first person, no jokes, no addressing the reader. Rich, but never purple: every flourish must rest on a fact from the record or the lore notes.
- The character's name, race, class and level are facts and may appear. Use "he" or "she" for the character only when the session facts give the character's sex; otherwise use the name or "they".
- The record does not hold anyone else's sex: refer to other people by name or as "they".

Faithfulness:
- State only what the record holds. Do not invent events, motives, feelings, thoughts or dialogue.
- Every person, place, item, quest, creature and number you name must appear in the record (or, for places, in the lore notes). If the record does not say why something happened, do not say why.
- The quest text explains why a quest was taken; you may say what the quest asked, in your own words.
- Lore notes are background only, so that places are described correctly. Never take events from them.
- Lines marked [background] are what NPCs, bosses and pets (such as a warlock's minions) said or emoted. They are context only, to help you understand what was happening. Do not report, quote or paraphrase them, and do not mention a speaker only because of them.
- Lines marked "hidden from the add-on" mean the game hid what was said; do not guess at it. You may say only that what was said there is not known.
- Write about the events, not about your sources: never mention the record, the add-on, the chat log, the lore notes or the parts of a long session.
- If something did not happen or was not recorded, leave it out. Do not write that the record shows nothing, or that nothing more is known.
- A death with no killer recorded has no known killer. Do not name one.

Other players:
- Name them as recorded and tell what they did and said, as dialogue or as reported speech.
- Never judge or characterise anyone, and never give anyone feelings or thoughts the record does not hold.
- Leave out out-of-character talk: text in brackets or double brackets, such as (( brb )) or (ooc), and game-mechanics chatter such as "lfg" or "inv".
- Leave out trade and recruitment adverts and other chatter that has nothing to do with the character.

Length and form:
- The length follows the session: a quiet hour gets a few paragraphs, a long evening of quests and talk gets more. No padding, no summary of the summary.
- Write in paragraphs of prose, in the order things happened. No headings, no bullet lists, no times of day unless they matter to the story.

Pictures:
- A line such as "[picture 2: First visit to Duskwood]" means a screenshot was taken at that moment. Place each picture once, as a line of its own between paragraphs, written exactly as {{picture 2}}, after the paragraph that tells of that moment.
- Do not describe a picture or mention it in the prose: you do not know what it shows.

Reply in exactly this form:
TITLE: <a chapter title for the session, at most eight words, in sentence case: a capital letter only for the first word and for names>

<the account>
'@
}

# The pattern of a picture marker the narrator places in an account: {{picture N}}.
$PictureMarker = '\{\{\s*picture\s+(\d+)\s*\}\}'

# Puts the session's pictures into its account (Shots: N, Path and Caption): each marker {{picture N}} becomes the
# picture, between paragraphs. A marker for no known picture, or for one already placed, is dropped. Returns Account
# and Rest (the pictures the narrator did not place, for the end of the file).
function Add-AccountPictures([string]$Account, $Shots) {
    $byN = @{}
    foreach ($s in @($Shots | Where-Object { $_ })) { $byN["$($s.N)"] = $s }
    $placed = @{}
    $text = [regex]::Replace($Account, $PictureMarker, {
        param($m)
        $s = $byN[$m.Groups[1].Value]
        if (-not $s -or $placed.ContainsKey("$($s.N)")) { return '' }
        $placed["$($s.N)"] = $true
        "`n`n![$($s.Caption)]($($s.Path -replace '\\', '/'))`n`n"
    })
    $text = [regex]::Replace($text, '[ \t]*\n[ \t]*', "`n")
    $text = [regex]::Replace($text, '\n{3,}', "`n`n").Trim()
    [pscustomobject]@{
        Account = $text
        Rest = @($Shots | Where-Object { $_ -and -not $placed.ContainsKey("$($_.N)") })
    }
}

# The user prompt for a session or for one part of a long session.
function New-SummaryPrompt([string]$Header, [string[]]$Lines, [string]$Lore, [int]$Part = 1, [int]$Parts = 1, [string]$Previous = '') {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('# Session facts')
    [void]$sb.AppendLine($Header)
    if ($Parts -gt 1) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("This session is long, so its record comes in $Parts pieces; this is piece $Part. Write the account of this piece only, as the next stretch of one continuous chapter. The reader must not be able to tell where one piece ends: never mention pieces or parts.")
        if ($Previous) {
            [void]$sb.AppendLine('The account so far, for continuity only. Do not repeat it; continue from where it ends, in the same voice:')
            [void]$sb.AppendLine('"""')
            [void]$sb.AppendLine($Previous.Trim())
            [void]$sb.AppendLine('"""')
            [void]$sb.AppendLine('Give a TITLE line as usual; it is ignored for parts after the first.')
        }
    }
    if ($Lore) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('# Lore notes (background for places only)')
        [void]$sb.AppendLine($Lore.Trim())
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('# Record')
    foreach ($l in $Lines) { [void]$sb.AppendLine($l) }
    $sb.ToString()
}

# Splits record lines into parts of at most MaxChars each, in order, never splitting a line.
function Split-RecordLines([string[]]$Lines, [int]$MaxChars) {
    $parts = New-Object Collections.Generic.List[object]
    $cur = New-Object Collections.Generic.List[string]
    $size = 0
    foreach ($l in $Lines) {
        if ($cur.Count -gt 0 -and $size + $l.Length + 1 -gt $MaxChars) {
            $parts.Add($cur.ToArray()); $cur = New-Object Collections.Generic.List[string]; $size = 0
        }
        $cur.Add($l); $size += $l.Length + 1
    }
    if ($cur.Count -gt 0) { $parts.Add($cur.ToArray()) }
    $parts.ToArray()
}

# The title and account from the AI's reply.
function ConvertFrom-SummaryReply([string]$Text) {
    $Text = ($Text -replace "`r", '').Trim()
    $Text = [regex]::Replace($Text, '^```[a-z]*\n|\n```$', '')
    $m = [regex]::Match($Text, '(?m)^\s*\**TITLE:?\**\s*:?\s*(.+?)\s*$')
    if ($m.Success) {
        $title = $m.Groups[1].Value.Trim().Trim('*').Trim('"').Trim()
        $body = $Text.Remove($m.Index, $m.Length).Trim()
    } else { $title = ''; $body = $Text }
    $body = [regex]::Replace($body, '(?m)^#+\s.*$\n?', '').Trim()
    [pscustomobject]@{ Title = $title; Body = $body }
}

# Grounding ---------------------------------------------------------------------------------------------------------------

$CommonWords = @('The', 'A', 'An', 'He', 'She', 'They', 'It', 'His', 'Her', 'Hers', 'Their', 'Theirs', 'Its', 'Him', 'Them', 'Then', 'After', 'Afterwards',
    'Before', 'When', 'While', 'Whilst', 'At', 'In', 'On', 'Later', 'Next', 'Finally', 'Meanwhile', 'Back', 'With', 'From', 'During', 'Once',
    'There', 'This', 'That', 'These', 'Those', 'Along', 'By', 'For', 'Of', 'To', 'As', 'Having', 'Nothing', 'No', 'One', 'Two', 'Three', 'Four',
    'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Both', 'Each', 'Every', 'Some', 'Several', 'Many', 'Most', 'Other', 'Others', 'Another',
    'Soon', 'Shortly', 'Towards', 'Toward', 'Near', 'Outside', 'Inside', 'Into', 'Out', 'Over', 'Under', 'Through', 'Throughout', 'Upon',
    'Not', 'But', 'And', 'Or', 'Yet', 'So', 'If', 'Where', 'Who', 'What', 'Which', 'Why', 'How', 'Here', 'Now', 'Also', 'Still', 'Again',
    'Among', 'Across', 'Around', 'Between', 'Without', 'Within', 'Until', 'Since', 'Though', 'Although', 'Despite', 'Instead', 'First', 'Second',
    'Third', 'Last', 'Earlier', 'Further', 'Furthermore', 'However', 'Thereafter', 'Together', 'Alone', 'Monday', 'Tuesday', 'Wednesday',
    'Thursday', 'Friday', 'Saturday', 'Sunday', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
    'November', 'December', 'Only', 'Just', 'Even', 'Otherwise', 'Perhaps', 'Eventually', 'Thus', 'Hence', 'Indeed', 'Briefly',
    'Overall', 'Neither', 'Nor', 'Either', 'All', 'Any', 'None', 'Much', 'More', 'Less', 'Few', 'Little', 'Such', 'Same', 'Twice',
    'Long', 'Little', 'Yes', 'Well', 'Again', 'Aside', 'Apart', 'Beyond', 'Above', 'Below', 'Behind', 'Beside', 'Like', 'Unlike',
    'Following', 'Shortly', 'Moments', 'Minutes', 'Hours', 'Later', 'Midway', 'Partway', 'Elsewhere', 'Nearby', 'Whether', 'I', 'TITLE', 'NPC', 'XP', 'Level', 'Quest', 'Party', 'Raid', 'Gold', 'Silver', 'Copper', 'World', 'Warcraft', 'WoW', 'Forever')

# The names and numbers in an account that its source does not hold: capitalised words that appear nowhere in the
# source (in any case), and numbers that are not in it. Each is reported once. An empty list means grounded.
function Test-Grounded([string]$Account, [string]$Source) {
    $src = ' ' + ($Source.ToLowerInvariant() -replace "[^\p{L}\p{N}' ]+", ' ') + ' '
    $srcNumbers = @{}
    foreach ($m in [regex]::Matches(($Source -replace '(?<=\d),(?=\d{3})', ''), '\d+(?:\.\d+)?')) { $srcNumbers[$m.Value] = $true }
    $missing = New-Object Collections.Generic.List[string]
    $seen = @{}
    # Words the account itself uses in lower case are ordinary words, so a capital at the start of a sentence or a line
    # does not make them names ("Quiet" after "a quiet hour").
    $plain = @{}
    foreach ($m in [regex]::Matches($Account, "(?<![\p{L}'])\p{Ll}[\p{L}']*")) { $plain[$m.Value] = $true }
    foreach ($m in [regex]::Matches($Account, "\b\p{Lu}[\p{L}']*(?:-\p{Lu}[\p{L}']*)?")) {
        $w = $m.Value.TrimEnd("'").Replace("'s", '')
        if ($seen.ContainsKey($w) -or $CommonWords -ccontains $w) { continue }
        $before = $Account.Substring(0, $m.Index).TrimEnd(' ', '"', "'", '(', '*')
        $startsSentence = $before -eq '' -or $before.EndsWith('.') -or $before.EndsWith('!') -or $before.EndsWith('?') -or $before.EndsWith(':') -or $before.EndsWith("`n")
        if ($startsSentence -and $plain.ContainsKey($w.ToLowerInvariant())) { continue }
        $seen[$w] = $true
        $low = $w.ToLowerInvariant()
        $parts = $low -split '-'
        $found = $true
        foreach ($p in $parts) {
            # The word, or the word without a plural ending ("Healers" for "Skeletal Healer"), or the word with one.
            $forms = @($p, ($p -replace 'es$', ''), ($p -replace 's$', '')) | Where-Object { $_.Length -gt 1 }
            $hit = $false
            foreach ($form in $forms) { if ($src.Contains(" $form ") -or $src.Contains(" $form'") -or $src.Contains(" $($form)s ") -or $src.Contains(" $($form)es ")) { $hit = $true } }
            if (-not $hit) { $found = $false }
        }
        if (-not $found) { $missing.Add($w) }
    }
    foreach ($m in [regex]::Matches(($Account -replace '(?<=\d),(?=\d{3})', ''), '\d+(?:\.\d+)?')) {
        $n = $m.Value
        if ($seen.ContainsKey("#$n")) { continue }
        $seen["#$n"] = $true
        if (-not $srcNumbers.ContainsKey($n)) { $missing.Add($n) }
    }
    $missing.ToArray()
}

# The key facts of a session that its account must not lose: dungeons entered, bosses defeated, levels reached, deaths (and the killer when known), and people who joined the group. Returns objects What
# (a description) and Terms (the account must contain one of them, in any case).
function Get-KeyFacts($Entries, [string]$Player) {
    $out = New-Object Collections.Generic.List[object]
    $seen = @{}
    foreach ($e in @($Entries)) {
        $f = { param($n) Get-Field $e $n }
        $item = switch (& $f 'k') {
            'enter' { [pscustomobject]@{ What = "entered $(& $f 'inst')"; Terms = @([string](& $f 'inst')) } }
            'boss' { [pscustomobject]@{ What = "defeated $(& $f 'name')"; Terms = @([string](& $f 'name')) } }
            'level' { [pscustomobject]@{ What = "level $(& $f 'level')"; Terms = @("level $(& $f 'level')") } }
            'death' {
                if (& $f 'who') { $null }
                elseif (& $f 'killer') { [pscustomobject]@{ What = "death, killed by $(& $f 'killer')"; Terms = @([string](& $f 'killer')) } }
                else { [pscustomobject]@{ What = 'death'; Terms = @('died', 'death', 'killed', 'fell', 'slain') } }
            }
            'group' { if ((& $f 'act') -eq 'join') { $name = [string](& $f 'who'); [pscustomobject]@{ What = "$name joined"; Terms = @($name, ($name -split ' ')[0]) } } }
        }
        if ($item -and -not $seen.ContainsKey($item.What)) { $seen[$item.What] = $true; $out.Add($item) }
    }
    $out.ToArray()
}

# The key facts an account does not mention. An empty list means nothing was lost.
function Test-Coverage([string]$Account, $Facts) {
    $low = $Account.ToLowerInvariant() -replace '\s+', ' '
    foreach ($f in @($Facts | Where-Object { $_ })) {
        $hit = $false
        foreach ($t in $f.Terms) { if ($t -and $low.Contains(([string]$t).ToLowerInvariant())) { $hit = $true } }
        if (-not $hit) { $f.What }
    }
}

# Phrases by which an account talks about its sources instead of the events (the narrator rules forbid them).
function Test-SourceMentions([string]$Account) {
    $found = New-Object Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Account, '(?i)\b(the record|this (?:part|piece)|the (?:next|previous|earlier) (?:part|piece)|the add-on|the chat log|lore notes)\b')) {
        $v = $m.Value.ToLowerInvariant()
        if (-not $found.Contains($v)) { $found.Add($v) }
    }
    $found.ToArray()
}

# Session files -----------------------------------------------------------------------------------------------------------

# The file name for a new session: <yyyy-MM-dd>-<n>.md, n counting the sessions already on that date.
function Get-SessionFileName([string]$SessionsDir, [long]$First) {
    $day = (ConvertFrom-Epoch $First).ToString('yyyy-MM-dd')
    $n = 1
    while (Test-Path -LiteralPath (Join-Path $SessionsDir "$day-$n.md")) { $n++ }
    "$day-$n.md"
}

# The line under a session's title: character and level, date and time span, zones.
function Format-SessionLine($Character, $Session, $Facts) {
    $start = ConvertFrom-Epoch $Session.First
    $end = ConvertFrom-Epoch $Session.Last
    $parts = @()
    $who = $Character.Name
    if ($Facts.LevelFrom) { $who += $(if ($Facts.LevelTo -and $Facts.LevelTo -ne $Facts.LevelFrom) { ", level $($Facts.LevelFrom) to $($Facts.LevelTo)" } else { ", level $($Facts.LevelFrom)" }) }
    $parts += $who
    $parts += "$($start.ToString('dddd d MMMM yyyy, HH:mm')) to $($end.ToString('HH:mm'))"
    if ($Facts.Zones.Count -gt 0) { $parts += ($Facts.Zones -join ', ') }
    $parts -join " $Dot "
}

# A session's Markdown file: title, the line under it, the account, and the screenshots (Shots: Path relative to the
# sessions folder, and Caption).
function Format-SessionMarkdown([string]$Title, [string]$Line, [string]$Account, $Shots) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("# $Title`n`n*$Line*`n`n$($Account.Trim())`n")
    $Shots = @($Shots | Where-Object { $_ })
    if ($Shots.Count -gt 0) {
        [void]$sb.Append("`n## Screenshots`n`n")
        foreach ($s in $Shots) { [void]$sb.Append("![$($s.Caption)]($($s.Path -replace '\\', '/'))`n`n") }
    }
    $sb.ToString().TrimEnd() + "`n"
}

# The title, the line under it and the body of a session file (which the player may have edited).
function Read-SessionMarkdown([string]$Text) {
    $Text = $Text -replace "`r", ''
    $title = ''; $line = ''
    $m = [regex]::Match($Text, '^\s*#\s+(.+)\n')
    if ($m.Success) { $title = $m.Groups[1].Value.Trim(); $Text = $Text.Substring($m.Length) }
    $m = [regex]::Match($Text, '^\s*\*([^\n]+)\*\s*\n')
    if ($m.Success) { $line = $m.Groups[1].Value.Trim(); $Text = $Text.Substring($m.Length) }
    [pscustomobject]@{ Title = $title; Line = $line; Body = $Text.Trim() }
}

# Screenshots -------------------------------------------------------------------------------------------------------------

# The game's screenshot taken for a screenshot entry: the file named WoWScrnShot_MMddyy_HHmmss nearest to its time,
# within a few seconds after it (the add-on takes it a moment after the milestone). $null when there is none.
function Find-Screenshot([string]$Dir, [long]$Epoch) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $null }
    $best = $null; $bestGap = 999
    $t = ConvertFrom-Epoch $Epoch
    for ($d = -2; $d -le 12; $d++) {
        $name = 'WoWScrnShot_' + $t.AddSeconds($d).ToString('MMddyy_HHmmss')
        foreach ($ext in '.jpg', '.png', '.tga') {
            $p = Join-Path $Dir ($name + $ext)
            if ((Test-Path -LiteralPath $p) -and [Math]::Abs($d) -lt $bestGap) { $best = $p; $bestGap = [Math]::Abs($d) }
        }
    }
    $best
}

# The pictures a session's Markdown links: Caption, Path as written, and Name (the file name alone).
function Get-SessionShots([string]$Body) {
    foreach ($m in [regex]::Matches([string]$Body, '!\[([^\]]*)\]\(([^)\s]+)\)')) {
        $path = $m.Groups[2].Value
        [pscustomobject]@{ Caption = $m.Groups[1].Value; Path = $path; Name = ($path -split '[\\/]')[-1] }
    }
}

# A thumbnail the game can show: a 24-bit uncompressed TGA (Truevision TGA, the format of the add-on's icon) of
# CanvasW by CanvasH pixels, powers of two, with the picture scaled to fit in its top-left corner and black around it.
# Returns the width and height the picture fills, or $null when the source cannot be read as an image. An existing
# Dest is kept: screenshots never change.
function New-Thumbnail([string]$Source, [string]$Dest, [int]$CanvasW = 512, [int]$CanvasH = 256) {
    Add-Type -AssemblyName System.Drawing
    try { $img = [System.Drawing.Image]::FromFile($Source) } catch { return $null }
    try {
        $scale = [Math]::Min($CanvasW / $img.Width, $CanvasH / $img.Height)
        $w = [Math]::Min($CanvasW, [Math]::Max(1, [int][Math]::Round($img.Width * $scale)))
        $h = [Math]::Min($CanvasH, [Math]::Max(1, [int][Math]::Round($img.Height * $scale)))
        if (Test-Path -LiteralPath $Dest) { return [pscustomobject]@{ W = $w; H = $h } } # made on an earlier run
        $bmp = New-Object System.Drawing.Bitmap $CanvasW, $CanvasH, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Black)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($img, 0, 0, $w, $h)
        $g.Dispose()
        $rect = New-Object System.Drawing.Rectangle 0, 0, $CanvasW, $CanvasH
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $bmp.PixelFormat)
        $row = $CanvasW * 3
        $pixels = New-Object byte[] ($row * $CanvasH)
        # TGA rows run from the bottom up; the bitmap's run from the top down, each Stride bytes apart. Both are BGR.
        for ($y = 0; $y -lt $CanvasH; $y++) {
            [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($data.Scan0, $y * $data.Stride), $pixels, ($CanvasH - 1 - $y) * $row, $row)
        }
        $bmp.UnlockBits($data)
        $bmp.Dispose()
        $header = New-Object byte[] 18
        $header[2] = 2 # uncompressed true colour
        $header[12] = $CanvasW -band 0xFF; $header[13] = $CanvasW -shr 8
        $header[14] = $CanvasH -band 0xFF; $header[15] = $CanvasH -shr 8
        $header[16] = 24
        $dir = Split-Path -Parent $Dest
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $fs = [IO.File]::Create($Dest)
        try { $fs.Write($header, 0, 18); $fs.Write($pixels, 0, $pixels.Length) } finally { $fs.Dispose() }
        [pscustomobject]@{ W = $w; H = $h }
    } finally { $img.Dispose() }
}

# The snapshot the game reads ---------------------------------------------------------------------------------------------

# A Lua string literal with every UTF-8 byte as a three-digit decimal escape: plain ASCII source that can never end the
# string early or become code, whatever the text holds. (From RPMaster's memory snapshot.)
function ConvertTo-LuaString([string]$Text) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($b in $Utf8.GetBytes([string]$Text)) { [void]$sb.Append('\').Append(([int]$b).ToString('000')) }
    [void]$sb.Append('"')
    $sb.ToString()
}

# Text cut to at most MaxBytes of UTF-8 on a whole character, with a note when cut.
function Get-SnapshotText([string]$Text, [int]$MaxBytes = 16000) {
    $bytes = $Utf8.GetBytes($Text)
    if ($bytes.Length -le $MaxBytes) { return $Text }
    $end = $MaxBytes
    while ($end -gt 0 -and ($bytes[$end] -band 0xC0) -eq 0x80) { $end-- }
    $Utf8.GetString($bytes, 0, $end) + "`n`n(The rest of this summary is in its file on your PC.)"
}

# JournalSnapshot.lua: Revision, Written, and Characters (Key, Confirmed, Sessions newest first: S, Title, First, Last,
# Zones, LevelFrom, LevelTo, File, Text or $null for an older session listed by date and title only, and optional Shots:
# Name, Thumb (the thumbnail's game path), W and H (the part of the thumbnail the picture fills)). Optional per
# character: Deleted (session numbers), SeenTitle and SeenDelete (session number -> time of the game's rename or
# delete the app has handled).
function New-JournalSnapshotLua($Model) {
    $out = New-Object Collections.Generic.List[string]
    $out.Add('-- JourneyMaster journal snapshot, written by the app. Read-only: edit the Markdown files on your PC.')
    $out.Add('local _, ns = ...')
    $out.Add('ns.journalSnapshot = {')
    $out.Add('    schema = 1,')
    $out.Add("    revision = $([long]$Model.Revision),")
    $out.Add("    written = $([long]$Model.Written),")
    $out.Add('    characters = {')
    foreach ($c in @($Model.Characters)) {
        $out.Add('        [' + (ConvertTo-LuaString $c.Key) + '] = {')
        $out.Add("            confirmed = $([long]$c.Confirmed),")
        $out.Add('            sessions = {')
        foreach ($s in @($c.Sessions)) {
            $fields = @("s = $([long]$s.S)", ('title = ' + (ConvertTo-LuaString $s.Title)), "first = $([long]$s.First)", "last = $([long]$s.Last)")
            if ($s.LevelFrom) { $fields += "levelFrom = $([int]$s.LevelFrom)" }
            if ($s.LevelTo) { $fields += "levelTo = $([int]$s.LevelTo)" }
            $fields += ('zones = { ' + ((@($s.Zones) | ForEach-Object { ConvertTo-LuaString $_ }) -join ', ') + ' }')
            $fields += ('file = ' + (ConvertTo-LuaString $s.File))
            if ($s.Text) { $fields += ('text = ' + (ConvertTo-LuaString $s.Text)) }
            $shots = @(if ($s.PSObject.Properties['Shots']) { $s.Shots | Where-Object { $_ } })
            if ($shots.Count -gt 0) {
                $fields += ('shots = { ' + (($shots | ForEach-Object {
                    '{ name = ' + (ConvertTo-LuaString $_.Name) + ', thumb = ' + (ConvertTo-LuaString $_.Thumb) + ", w = $([int]$_.W), h = $([int]$_.H) }"
                }) -join ', ') + ' }')
            }
            $out.Add('                { ' + ($fields -join ', ') + ' },')
        }
        $out.Add('            },')
        $deleted = @(if ($c.PSObject.Properties['Deleted']) { $c.Deleted | Where-Object { $null -ne $_ } | Sort-Object { [long]$_ } })
        if ($deleted.Count -gt 0) { $out.Add('            deleted = { ' + (($deleted | ForEach-Object { [long]$_ }) -join ', ') + ' },') }
        foreach ($pair in @(@('SeenTitle', 'seenTitle'), @('SeenDelete', 'seenDelete'))) {
            $map = if ($c.PSObject.Properties[$pair[0]]) { $c.($pair[0]) } else { $null }
            if ($map -and $map.Count -gt 0) {
                $out.Add("            $($pair[1]) = { " + ((@($map.Keys) | Sort-Object { [long]$_ } | ForEach-Object { "[$([long]$_)] = $([long]$map[$_])" }) -join ', ') + ' },')
            }
        }
        $out.Add('        },')
    }
    $out.Add('    },')
    $out.Add('}')
    ($out -join "`n") + "`n"
}

# Checks generated snapshot source before it is published: every string fully escaped, nothing else but the fixed
# names, numbers and punctuation, and at most 4 MiB. Returns '' when it is safe, or the reason.
function Test-JournalSnapshotLua([string]$Lua) {
    if ($Lua.Length -gt 4MB) { return 'larger than 4 MiB' }
    $rest = [regex]::Replace($Lua, '"(?:\\\d{3})*"', '0')
    if ($rest.Contains('"')) { return 'a string value is not fully escaped' }
    $rest = $rest -replace '(?m)^--[^\n]*$', ''
    if ($rest -match '[^\sA-Za-z0-9_=,{}.\[\]]') { return 'unexpected text outside string values' }
    $allowed = 'local', '_', 'ns', 'journalSnapshot', 'schema', 'revision', 'written', 'characters', 'confirmed', 'sessions',
        's', 'title', 'first', 'last', 'levelFrom', 'levelTo', 'zones', 'file', 'text', 'shots', 'name', 'thumb', 'w', 'h',
        'deleted', 'seenTitle', 'seenDelete'
    foreach ($w in [regex]::Matches($rest, '[A-Za-z_]+')) { if ($allowed -cnotcontains $w.Value) { return "unexpected name $($w.Value)" } }
    ''
}

# The overview and the export ---------------------------------------------------------------------------------------------

function Get-OverviewRules {
@'
You write the overview of a character's journey in World of Warcraft (the WoW: Forever server), built only from the chapters written for its play sessions, which you are given in order.

- Write it like a novel: third person, past tense, flowing narrative prose, British English. No first person, no jokes, no addressing the reader; every flourish must rest on the entries.
- State only what the entries hold. Do not invent events, motives, feelings or dialogue, and do not add lore.
- Every person, place, quest and number you name must appear in the entries.
- Tell the journey as a whole: where the character went, what it did and with whom, the turning points (levels, deaths, dungeons, bosses). Leave out small detail.
- Paragraphs of prose, in order. No headings and no lists.
- If a previous overview is given, rewrite it to take in the new entries; keep what it says that is still true.
- Write about the events, not about your sources: never mention entries, records, sessions' files or the chat log.

Reply with the overview only.
'@
}

function New-OverviewPrompt([string]$Character, $Sessions, [string]$Previous = '') {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("# Character: $Character")
    if ($Previous) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('# Previous overview')
        [void]$sb.AppendLine($Previous.Trim())
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine($(if ($Previous) { '# New entries' } else { '# Entries' }))
    foreach ($s in $Sessions) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("## $($s.Title) ($($s.Line))")
        [void]$sb.AppendLine($s.Body)
    }
    $sb.ToString()
}

# The whole journal as one Markdown document: title, overview, then every session in order with its headings one level
# down and its picture paths made relative to the character's folder.
function New-JournalExport([string]$Character, [string]$Overview, $Sessions) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("# The journey of $Character`n`n")
    if ($Overview) { [void]$sb.Append("## Overview`n`n$($Overview.Trim())`n`n") }
    foreach ($s in $Sessions) {
        [void]$sb.Append("## $($s.Title)`n`n")
        if ($s.Line) { [void]$sb.Append("*$($s.Line)*`n`n") }
        $body = [regex]::Replace($s.Body, '(?m)^(#+)\s', { param($m) '#' + $m.Groups[1].Value + ' ' })
        $body = $body -replace '\]\(\.\./', ']('
        [void]$sb.Append($body.Trim() + "`n`n")
    }
    $sb.ToString().TrimEnd() + "`n"
}

# Claude ------------------------------------------------------------------------------------------------------------------

function Format-CliArgument($arg) {
    if ($arg -eq '') { '""' } elseif ($arg -match '[\s"]') { '"' + ($arg -replace '"', '\"') + '"' } else { $arg }
}

# Runs headless Claude Code with the prompt on standard input, no tools. Returns the result event (or an object with
# is_error and the output when there is none). (From RPMaster's Bridge.)
function Invoke-ClaudeCli([string]$ClaudePath, [string[]]$Arguments, [string]$WorkDir, [string]$Prompt) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($ClaudePath -match '\.ps1$') {
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Format-CliArgument $ClaudePath) + ' ' + (($Arguments | ForEach-Object { Format-CliArgument $_ }) -join ' ')
    } else {
        $psi.FileName = $ClaudePath
        $psi.Arguments = ($Arguments | ForEach-Object { Format-CliArgument $_ }) -join ' '
    }
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $psi.EnvironmentVariables.Remove('CLAUDECODE')
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $bytes = $Utf8.GetBytes($Prompt)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $p.WaitForExit()
    $out = $outTask.Result
    try { $events = @($out | ConvertFrom-Json | ForEach-Object { $_ }) } catch { $events = @() }
    $result = $events | Where-Object { $_.PSObject.Properties['type'] -and $_.type -eq 'result' } | Select-Object -Last 1
    if (-not $result) { $result = [pscustomobject]@{ is_error = $true; result = ($out + $errTask.Result).Trim() } }
    $result
}

Export-ModuleMember -Function Test-SourceMentions, Get-KeyFacts, Test-Coverage, Get-SexWord, Read-FileText, Write-FileAtomic, Read-SavedVariables, Get-SafeName, ConvertFrom-Epoch, ConvertTo-Epoch,
    Get-Field, Add-EventEntries, Read-EventEntries, Remove-SessionEvents, ConvertFrom-SessionChange, Get-SessionMap, Set-SessionTitle, Get-Sessions, Test-HasInstance, Test-SessionFinished, Get-SessionFacts,
    Get-InstanceWindows, ConvertFrom-ChatLogStamp, ConvertFrom-ChatLogLine, ConvertFrom-SignalLine, Read-ChatLogWindows, Merge-ChatLog, Format-Money,
    Format-Entry, Format-RecordLines, Get-ShotLabel, Add-AccountPictures, Format-RecordHeader, Get-LoreText, Get-NarratorRules, New-SummaryPrompt, Split-RecordLines,
    ConvertFrom-SummaryReply, Test-Grounded, Get-SessionFileName, Format-SessionLine, Format-SessionMarkdown, Read-SessionMarkdown,
    Find-Screenshot, Get-SessionShots, New-Thumbnail, ConvertTo-LuaString, Get-SnapshotText, New-JournalSnapshotLua, Test-JournalSnapshotLua, Get-OverviewRules,
    New-OverviewPrompt, New-JournalExport, Format-CliArgument, Invoke-ClaudeCli
