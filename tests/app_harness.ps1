# Offline tests for the JourneyMaster app (src\App): the saved-file reader, event files, sessions, the chat log fill, the
# record, grounding, splitting, the session files, the snapshot, and whole runs of JourneyMaster.ps1 against a made-up
# game folder with a fake claude (tests\fake_claude.ps1).
# Run from the project root with Windows PowerShell 5.1:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\app_harness.ps1
# Kept ASCII-only: Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\App\JourneyMasterApp.psm1') -Force
$Utf8 = New-Object Text.UTF8Encoding $false
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$App = Join-Path $Root 'src\App\JourneyMaster.ps1'
$Fake = Join-Path $Root 'tests\fake_claude.ps1'

$failures = 0
function Check($what, $actual, $expected) {
    if ("$actual" -cne "$expected") {
        Write-Host "FAIL ${what}: expected [$expected], got [$actual]" -ForegroundColor Red
        $script:failures++
    }
}
function True($what, $cond) { if (-not $cond) { Write-Host "FAIL $what" -ForegroundColor Red; $script:failures++ } }

# Writes a value as the game writes SavedVariables (tabs, ["key"] = value, arrays with -- [n] comments).
function ConvertTo-TestLua($v, [int]$Depth = 0) {
    $tab = "`t" * ($Depth + 1)
    if ($null -eq $v) { return 'nil' }
    if ($v -is [bool]) { return $(if ($v) { 'true' } else { 'false' }) }
    if ($v -is [int] -or $v -is [long] -or $v -is [double]) { return [string]$v }
    if ($v -is [string]) {
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append('"')
        foreach ($ch in $v.ToCharArray()) {
            switch ($ch) { '"' { [void]$sb.Append('\"') } '\' { [void]$sb.Append('\\') } "`n" { [void]$sb.Append('\n') } default { [void]$sb.Append($ch) } }
        }
        return $sb.Append('"').ToString()
    }
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('{')
    if ($v -is [Collections.IDictionary]) {
        foreach ($k in $v.Keys) { $lines.Add("$tab[`"$k`"] = $(ConvertTo-TestLua $v[$k] ($Depth + 1)),") }
    } else {
        $n = 0
        foreach ($item in $v) { $n++; $lines.Add("$tab$(ConvertTo-TestLua $item ($Depth + 1)), -- [$n]") }
    }
    $lines.Add(("`t" * $Depth) + '}')
    $lines -join "`n"
}
function Write-TestSV([string]$Path, $Db) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [IO.File]::WriteAllText($Path, "`nJourneyMasterDB = $(ConvertTo-TestLua $Db)`n", $Utf8)
}

# The saved-file reader ----------------------------------------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('jm-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
try {
    $svText = @"

JourneyMasterDB = {
`t["schema"] = 1,
`t["characters"] = {
`t`t["Adra\195\171l-Realm"] = {
`t`t`t["entries"] = {
`t`t`t`t{
`t`t`t`t`t["k"] = "chat",
`t`t`t`t`t["text"] = "say \"hi\"\\ and\nnew line caf\195\169",
`t`t`t`t`t["t"] = 1794520000,
`t`t`t`t`t["stock"] = true,
`t`t`t`t`t["x"] = 1.5,
`t`t`t`t`t["neg"] = -3,
`t`t`t`t}, -- [1]
`t`t`t`t{
`t`t`t`t`t["k"] = "note", ["text"] = "Adra" .. "",
`t`t`t`t}, -- [2]
`t`t`t},
`t`t`t["settings"] = {
`t`t`t},
`t`t`t["zonesSeen"] = { ["Elwynn Forest"] = true, [5] = "five" },
`t`t},
`t},
}
JourneyMasterOther = nil
"@
    # The ".." above is not valid SV; remove it so the file is what the game writes.
    $svText = $svText.Replace(' .. ""', '')
    $svPath = Join-Path $tmp 'sv.lua'
    [IO.File]::WriteAllText($svPath, $svText, $Utf8)
    $g = Read-SavedVariables $svPath
    $chars = $g['JourneyMasterDB']['characters']
    $key = @($chars.Keys)[0]
    Check 'UTF-8 escapes decoded in keys' $key ("Adra" + [char]0xEB + "l-Realm")
    $e = $chars[$key]['entries']
    True 'array becomes object[]' ($e -is [object[]])
    Check 'escapes' $e[0]['text'] ("say `"hi`"\ and`nnew line caf" + [char]0xE9)
    Check 'integer' $e[0]['t'] 1794520000
    True 'integer is long' ($e[0]['t'] -is [long])
    Check 'boolean' $e[0]['stock'] $true
    Check 'decimal' $e[0]['x'] 1.5
    Check 'negative' $e[0]['neg'] -3
    True 'empty table is a Hashtable' ($chars[$key]['settings'] -is [Collections.Hashtable])
    Check 'mixed keys' $chars[$key]['zonesSeen']['5'] 'five'
    Check 'nil global absent' $g.ContainsKey('JourneyMasterOther') $false

    # Event files and sessions --------------------------------------------------------------------------------------------
    $T = ConvertTo-Epoch (Get-Date -Year 2026 -Month 11 -Day 12 -Hour 21 -Minute 0 -Second 0 -Millisecond 0)
    $evDir = Join-Path $tmp 'events'
    $entries = @(
        @{ i = 1; s = 1; t = $T; k = 'login'; lvl = 26; z = 'Stormwind City' },
        @{ i = 2; s = 1; t = $T + 60; k = 'zone'; z = 'Duskwood'; sz = 'Darkshire' },
        @{ i = 3; s = 1; t = $T + 120; k = 'level'; level = 27; z = 'Duskwood' },
        @{ i = 4; s = 2; t = $T + 3 * 3600; k = 'login'; z = 'Duskwood' }
    )
    Check 'entries written' (Add-EventEntries $evDir $entries) 4
    [void](Add-EventEntries $evDir @($entries[0])) # a repeat is ignored when read back
    $read = @(Read-EventEntries $evDir)
    Check 'read back without duplicates' $read.Count 4
    $sessions = @(Get-Sessions $read)
    Check 'two sessions' $sessions.Count 2
    Check 'first session entries' $sessions[0].Entries.Count 3
    True 'earlier session finished' (Test-SessionFinished $sessions[0] $false ($T + 3 * 3600) $true)
    True 'latest session running' (-not (Test-SessionFinished $sessions[1] $true ($T + 3 * 3600 + 60) $true))
    True 'latest session, game running, record 31 minutes old: not finished (the player may still be playing)' (-not (Test-SessionFinished $sessions[1] $true ($T + 3 * 3600 + 1860) $true))
    True 'latest session, game running, record 5 hours old: still not finished' (-not (Test-SessionFinished $sessions[1] $true ($T + 8 * 3600) $true))
    True 'latest session idle 31 minutes, game closed: finished' (Test-SessionFinished $sessions[1] $true ($T + 3 * 3600 + 1860) $false)
    $logoutSession = [pscustomobject]@{ S = 3; Entries = @(@{ k = 'login'; t = $T }, @{ k = 'logout'; t = $T + 10 }); First = $T; Last = $T + 10 }
    True 'logout with the game closed: waits 30 minutes for a login' (-not (Test-SessionFinished $logoutSession $true ($T + 20) $false))
    True 'logout with the game running (a reload): not finished' (-not (Test-SessionFinished $logoutSession $true ($T + 20) $true))
    True 'logout 31 minutes ago: finished' (Test-SessionFinished $logoutSession $true ($T + 1871) $false)
    $endSession = [pscustomobject]@{ S = 5; Entries = @(@{ k = 'enter'; t = $T; inst = 'The Stockade' }, @{ k = 'end'; t = $T + 10 }); First = $T; Last = $T + 10 }
    True 'finished by the player: at once, even a dungeon with the game running' (Test-SessionFinished $endSession $true ($T + 20) $true)
    $dungeon = [pscustomobject]@{ S = 4; Entries = @(@{ k = 'enter'; t = $T; inst = 'The Stockade' }, @{ k = 'leave'; t = $T + 600; inst = 'The Stockade' }); First = $T; Last = $T + 600 }
    True 'dungeon session waits for the game to close' (-not (Test-SessionFinished $dungeon $false ($T + 4000) $true))
    True 'dungeon session after the game closed' (Test-SessionFinished $dungeon $false ($T + 4000) $false)
    $facts = Get-SessionFacts $sessions[0] $null
    Check 'levels' "$($facts.LevelFrom)-$($facts.LevelTo)" '26-27'
    Check 'zones' ($facts.Zones -join '|') 'Stormwind City|Duskwood'
    Check 'subzones' ($facts.Subzones -join '|') 'Darkshire'

    # The chat log ------------------------------------------------------------------------------------------------------------
    $win = @(Get-InstanceWindows $dungeon)
    Check 'one window' $win.Count 1
    Check 'window name' $win[0].Name 'The Stockade'
    $stamp = { param($s) $d = ConvertFrom-Epoch ($T + $s); "$($d.Month)/$($d.Day) $($d.ToString('HH:mm:ss')).123  " }
    $p = ConvertFrom-ChatLogLine ((& $stamp 30) + '|Hchannel:PARTY|h[Party Leader]|h Seph Stormbrewer: come to me') $T
    Check 'party line' "$($p.Kind)|$($p.Ch)|$($p.Who)|$($p.Text)" 'chat|party|Seph Stormbrewer|come to me'
    Check 'party line time' $p.T ($T + 30)
    $p = ConvertFrom-ChatLogLine ((& $stamp 40) + 'Bazil Thredd yells: Lads, a visitor!') $T
    Check 'yell line' "$($p.Kind)|$($p.Ch)|$($p.Who)" 'said|yell|Bazil Thredd'
    Check 'kill line' (ConvertFrom-ChatLogLine ((& $stamp 50) + 'Defias Prisoner dies, you gain 60 experience. (+18 group bonus)') $T).Name 'Defias Prisoner'
    Check 'own loot' (ConvertFrom-ChatLogLine ((& $stamp 51) + 'You receive loot: Linen Clothx3') $T).N 3
    Check 'group death' (ConvertFrom-ChatLogLine ((& $stamp 52) + 'Seph has died.') $T).Who 'Seph'
    Check 'own death' (ConvertFrom-ChatLogLine ((& $stamp 53) + 'You died.') $T).Kind 'death'
    Check 'quest progress' (ConvertFrom-ChatLogLine ((& $stamp 54) + 'Quest accepted: The Stockade Riots') $T).Title 'The Stockade Riots'
    Check 'joins' (ConvertFrom-ChatLogLine ((& $stamp 55) + 'Ask Forgeorage joins the party.') $T).Act 'join'
    True 'numbered channel skipped' ($null -eq (ConvertFrom-ChatLogLine ((& $stamp 56) + '[2. Trade] Someone: WTS') $T))
    True 'RPMaster signal skipped' ($null -eq (ConvertFrom-ChatLogLine ((& $stamp 57) + 'RPMP: x') $T))
    True 'whisper skipped' ($null -eq (ConvertFrom-ChatLogLine ((& $stamp 58) + 'Seph whispers: secret') $T))
    True 'other players loot skipped' ($null -eq (ConvertFrom-ChatLogLine ((& $stamp 59) + 'Seph Stormbrewer receives loot: Tin Ore.') $T))
    $nye = ConvertTo-Epoch (Get-Date -Year 2026 -Month 12 -Day 31 -Hour 23 -Minute 59 -Second 0 -Millisecond 0)
    Check 'stamp over New Year' (ConvertFrom-Epoch (ConvertFrom-ChatLogStamp 1 1 0 1 0 $nye)).Year 2027

    $logPath = Join-Path $tmp 'WoWChatLog.txt'
    $logLines = @(
        ((& $stamp -3600) + '|Hchannel:PARTY|h[Party]|h Before Window: too early'),
        ((& $stamp 30) + '|Hchannel:PARTY|h[Party Leader]|h Seph Stormbrewer: come to me'),
        ((& $stamp 40) + 'Bazil Thredd yells: Lads, a visitor!'),
        ((& $stamp 45) + 'Seph Stormbrewer says: on my way'),
        ((& $stamp 50) + 'Defias Prisoner dies, you gain 60 experience. (+18 group bonus)'),
        ((& $stamp 60) + 'Defias Prisoner dies, you gain 60 experience. (+18 group bonus)'),
        ((& $stamp 70) + 'You receive loot: Linen Clothx3'),
        ((& $stamp 80) + 'You died.'),
        ((& $stamp 81) + 'JMS:1-1:OPEN:2:Baldrake Cavendell-LivingFlame'),
        ((& $stamp 82) + 'JMP:1-1:00001:......'),
        # RPMaster's hidden lines, some holding text that would otherwise read as chat or a death.
        ((& $stamp 83) + 'RPMT:c1:L:1:say:Seph Stormbrewer:Seph Stormbrewer says: on my way'),
        ((& $stamp 84) + 'RPMT:c1:HEAD:scene=1;login=2'),
        ((& $stamp 85) + 'RPMP:c1:00001:You died.'),
        ((& $stamp 86) + 'RPMS:s1:OPEN:Baldrake:file'),
        ((& $stamp 87) + 'RPMD:r1:Defias Prisoner dies, you gain 60 experience.'),
        ((& $stamp 88) + 'PAD:p1:00001:You receive loot: Linen Cloth'),
        ((& $stamp 89) + 'BEGIN:p1:system'),
        ((& $stamp 5000) + '|Hchannel:PARTY|h[Party]|h After Window: too late')
    )
    [IO.File]::WriteAllText($logPath, ($logLines -join "`r`n") + "`r`n", $Utf8)
    $inWin = @(Read-ChatLogWindows $logPath $win)
    Check 'lines in the window only, signal lines and RPMaster lines left out' $inWin.Count 7
    True 'an RPMaster line holding a signal is not one' ($null -eq (ConvertFrom-SignalLine ((& $stamp 83) + 'RPMT:c1:L:1:say:X:JMS:1-9:OPEN:2:Baldrake Cavendell-LivingFlame')))
    $sig = ConvertFrom-SignalLine ((& $stamp 81) + 'JMS:1-1:OPEN:2:Baldrake Cavendell-LivingFlame')
    Check 'signal kind' $sig.Kind 'OPEN'
    Check 'signal session' $sig.S 2
    Check 'signal character' $sig.Key 'Baldrake Cavendell-LivingFlame'
    True 'a player saying a signal is not one' ($null -eq (ConvertFrom-SignalLine ((& $stamp 81) + 'Mallory says: JMS:1-2:OPEN:2:Baldrake Cavendell-LivingFlame')))
    True 'padding is not a signal' ($null -eq (ConvertFrom-SignalLine ((& $stamp 82) + 'JMP:1-1:00001:......')))
    $merged = @(Merge-ChatLog (@($dungeon.Entries) + @(@{ k = 'death'; t = $T + 82 })) $inWin 'Baldrake Cavendell' @())
    $kinds = ($merged | ForEach-Object { Get-Field $_ 'k' }) -join ','
    Check 'merged kinds' $kinds 'enter,chat,said,chat,kills,logloot,death,leave'
    Check 'kills placed at the last kill' (Get-Field ($merged | Where-Object { (Get-Field $_ 'k') -eq 'kills' }) 't') ($T + 60)
    $kills = $merged | Where-Object { (Get-Field $_ 'k') -eq 'kills' }
    Check 'kills gathered' (Get-Field $kills 'list') 'Defias Prisoner x2'
    $said = $merged | Where-Object { (Get-Field $_ 'who') -eq 'Seph Stormbrewer' -and (Get-Field $_ 'ch') -eq 'say' }
    Check 'party member saying is a player' (Get-Field $said 'k') 'chat'
    Check 'own death from the log not repeated' @($merged | Where-Object { (Get-Field $_ 'k') -eq 'death' }).Count 1

    # The record ------------------------------------------------------------------------------------------------------------
    $P = 'Baldrake Cavendell'
    Check 'accept line' (Format-Entry @{ k = 'quest'; act = 'accept'; title = 'Worgen in the Woods'; giver = 'Calor'; text = 'Bring this "message".'; obj = 'Kill 6.' } $P) `
        "Baldrake Cavendell accepted the quest `"Worgen in the Woods`" from Calor. Quest text: `"Bring this 'message'.`" Objective: `"Kill 6.`""
    Check 'turn-in line' (Format-Entry @{ k = 'quest'; act = 'turnin'; title = 'Q'; giver = 'G'; xp = 1900; money = 2200 } $P) "Baldrake Cavendell handed in the quest `"Q`" to G (reward: 1900 experience, 22 silver)."
    Check 'death with killer' (Format-Entry @{ k = 'death'; z = 'Duskwood'; killer = 'Stitches'; spell = 'melee' } $P) 'Baldrake Cavendell died in Duskwood, killed by Stitches.'
    Check 'death without killer' (Format-Entry @{ k = 'death'; z = 'Duskwood' } $P) 'Baldrake Cavendell died in Duskwood.'
    Check 'own say' (Format-Entry @{ k = 'chat'; ch = 'say'; who = $P; text = 'hello' } $P) 'Baldrake Cavendell (the character) said: "hello"'
    Check 'own say under the full name' (Format-Entry @{ k = 'chat'; ch = 'say'; who = 'Baldrake Cavendell'; text = 'hello' } 'Baldrake') 'Baldrake Cavendell (the character) said: "hello"'
    Check 'own voiced line under the full name' (Format-Entry @{ k = 'chat'; ch = 'emote'; who = 'Baldrake Cavendell'; text = '|| Old Tom says: Aye.' } 'Baldrake') 'Old Tom (a character voiced in role-play by the character''s player) said: "Aye."'
    Check 'npc from log' (Format-Entry @{ k = 'npc'; ch = 'yell'; who = 'Bazil Thredd'; text = 'Lads!'; src = 'log' } $P) '[background] Bazil Thredd (NPC) yelled (from the chat log): "Lads!"'
    Check 'unmarked pet speech is background' (Format-Entry @{ k = 'npc'; ch = 'say'; who = 'Zigzag'; text = 'As you command.' } $P) '[background] Zigzag (NPC) said: "As you command."'
    Check 'own minion stock line' (Format-Entry @{ k = 'npc'; ch = 'say'; who = 'Zigzag'; text = 'As you command.'; own = $true; fam = 'Voidwalker' } $P) 'Zigzag (the character''s own minion, a Voidwalker) said, a stock line of the creature: "As you command."'
    Check 'own minion stock emote' (Format-Entry @{ k = 'npc'; ch = 'emote'; who = 'Zigzag'; text = 'Zigzag bows.'; own = $true } $P) '(Stock emote of Zigzag, the character''s own minion) Zigzag bows.'
    Check 'minion voiced in role-play' (Format-Entry @{ k = 'chat'; ch = 'emote'; who = $P; text = '|| Zigzag says: She stopped writing for a reason.'; pet = 'Zigzag'; fam = 'Voidwalker' } $P) 'Zigzag (the character''s own minion, a Voidwalker, speaking in role-play) said: "She stopped writing for a reason."'
    Check 'minion yelling in role-play' (Format-Entry @{ k = 'chat'; ch = 'emote'; who = $P; text = '| Zigzag yells: Run!'; pet = 'Zigzag' } $P) 'Zigzag (the character''s own minion, speaking in role-play) yelled: "Run!"'
    Check 'minion emote in role-play' (Format-Entry @{ k = 'chat'; ch = 'emote'; who = $P; text = '|| Zigzag bows low.'; pet = 'Zigzag'; fam = 'Voidwalker' } $P) '(Role-play emote of Zigzag, the character''s own minion, a Voidwalker) Zigzag bows low.'
    Check 'another character voiced by the player' (Format-Entry @{ k = 'chat'; ch = 'emote'; who = $P; text = '|| Old Tom whispers: Not here.'; pet = 'Zigzag' } $P) 'Old Tom (a character voiced in role-play by the character''s player) whispered: "Not here."'
    Check 'a character voiced by another player' (Format-Entry @{ k = 'chat'; ch = 'emote'; who = 'Seph' ; text = '|| The guard says: Halt.' } $P) 'The guard (a character voiced in role-play by the player Seph) said: "Halt."'
    Check 'role-play narration' (Format-Entry @{ k = 'chat'; ch = 'emote'; who = $P; text = '|| The wind rose.' } $P) '(Role-play narration by the character''s player) The wind rose.'
    Check 'plain emote unchanged' (Format-Entry @{ k = 'chat'; ch = 'emote'; who = 'Seph'; text = 'waves.' } $P) '(emote) Seph waves.'
    True 'narrator told stock lines are not conversation' ((Get-NarratorRules) -match 'stock line of the creature.*not conversation')
    True 'narrator told the minion is a companion' ((Get-NarratorRules) -match 'own minion.*companion in the story')
    True 'narrator told not to report background lines' ((Get-NarratorRules) -match 'Lines marked \[background\].*Do not report, quote or paraphrase them')
    Check 'gap' (Format-Entry @{ k = 'gap'; what = 'chat lines'; n = 3 } $P) '[3 chat lines here were hidden from the add-on by the game.]'
    True 'reload left out' ($null -eq (Format-Entry @{ k = 'login'; reload = $true } $P))
    True 'screenshot left out' ($null -eq (Format-Entry @{ k = 'shot'; why = 'level' } $P))
    Check 'first-visit label' (Get-ShotLabel @{ k = 'shot'; why = 'new zone'; z = 'Duskwood' }) 'First visit to Duskwood'
    Check 'stay label' (Get-ShotLabel @{ k = 'shot'; why = 'zone'; z = 'Duskwood' }) 'Exploring Duskwood'
    Check 'subzone first-visit label' (Get-ShotLabel @{ k = 'shot'; why = 'new subzone'; z = 'Wetlands'; sz = 'Dun Modr' }) 'First visit to Dun Modr, Wetlands'
    Check 'subzone stay label' (Get-ShotLabel @{ k = 'shot'; why = 'subzone'; z = 'Wetlands'; sz = 'Dun Modr' }) 'Time spent at Dun Modr, Wetlands'
    $recShots = @(@{ k = 'shot'; t = $T; why = 'level' }, @{ k = 'shot'; t = $T + 5; why = 'new zone'; z = 'Duskwood' })
    Check 'pictures in the record, only those with files' ((@(Format-RecordLines $recShots $P @{ "$($T + 5)" = 1 }) | ForEach-Object { $_.Text }) -join '|') '[picture 1: First visit to Duskwood]'
    Check 'no pictures given: screenshots left out' @(Format-RecordLines $recShots $P).Count 0
    True 'narrator told how to place pictures' ((Get-NarratorRules) -match '\{\{picture 2\}\}')
    $pics = @([pscustomobject]@{ N = 1; Path = '../screenshots/a.jpg'; Caption = 'Level up, 21:02' },
        [pscustomobject]@{ N = 2; Path = '../screenshots/b.jpg'; Caption = 'First visit to Duskwood, 21:10' },
        [pscustomobject]@{ N = 3; Path = '../screenshots/c.jpg'; Caption = 'Boss defeated, 21:40' })
    $placed = Add-AccountPictures "He rose a level.`n`n{{picture 1}}`n`nHe walked on. {{ picture 2 }} Duskwood was dark.`n`n{{picture 1}}`n`n{{picture 9}}`n`nThe end." $pics
    Check 'pictures placed in the account' $placed.Account "He rose a level.`n`n![Level up, 21:02](../screenshots/a.jpg)`n`nHe walked on.`n`n![First visit to Duskwood, 21:10](../screenshots/b.jpg)`n`nDuskwood was dark.`n`nThe end."
    Check 'the picture not placed is left for the end' (($placed.Rest | ForEach-Object { $_.N }) -join ',') '3'
    foreach ($k in 'said', 'zone', 'enter', 'leave', 'boss', 'loot', 'gear', 'money', 'level', 'skill', 'rep', 'group', 'note', 'kills', 'logloot', 'logout') {
        True "every kind formats: $k" ([string](Format-Entry @{ k = $k; t = $T } $P) -ne '')
    }

    # Grounding, splitting, replies ----------------------------------------------------------------------------------------
    $src = "Baldrake Cavendell met Seph Stormbrewer in Darkshire. He handed in Worgen in the Woods for 1,900 experience."
    Check 'grounded account' (@(Test-Grounded 'Later, Baldrake met Seph in Darkshire and earned 1900 experience.' $src).Count) 0
    Check 'invented name and number' ((Test-Grounded 'Then Baldrake met Zanzibar and earned 42 gold.' $src) -join ',') 'Zanzibar,42'
    Check 'possessive' (@(Test-Grounded "Baldrake's friend Seph's sword." $src).Count) 0
    Check 'ordinary word starting a title' (@(Test-Grounded ("Quiet evening in Darkshire`nIt was a quiet evening.") $src).Count) 0
    Check 'name starting a sentence still caught' ((Test-Grounded 'Baldrake went on. Quillfeather followed.' $src) -join ',') 'Quillfeather'
    Check 'ordinary words starting sentences' (@(Test-Grounded 'Baldrake went on. Returning, he rested. Companions came and went.' 'Baldrake rested with his companion.').Count) 0
    Check 'source mentions found' ((Test-SourceMentions 'The record holds nothing more. In this part Maren slept, as the chat log shows.') -join '|') 'the record|this part|the chat log'
    Check 'plain account has none' (@(Test-SourceMentions 'Maren slept at the inn and recorded nothing in her diary.').Count) 0
    Check 'plurals of recorded names' (@(Test-Grounded 'The Skeletal Healers and the Tainted Ones fell.' '3/3 Skeletal Healer slain. 8/8 Nightbane Tainted One slain.').Count) 0
    $hdr = Format-RecordHeader ([pscustomobject]@{ Name = 'Baldrake'; Race = 'Human'; Class = 'Warlock'; Faction = 'Alliance'; Sex = 2 }) ([pscustomobject]@{ First = $T; Last = $T + 60 }) ([pscustomobject]@{ LevelFrom = 26; LevelTo = 26; Zones = @('Duskwood') })
    True 'header gives the sex' ($hdr -match 'Character: Baldrake, a male Human Warlock of the Alliance\.')
    $hdr = Format-RecordHeader ([pscustomobject]@{ Name = 'Baldrake'; Race = 'Human'; Class = 'Warlock'; Faction = $null }) ([pscustomobject]@{ First = $T; Last = $T + 60 }) ([pscustomobject]@{ LevelFrom = $null; LevelTo = $null; Zones = @() })
    True 'header without the sex' ($hdr -match 'Character: Baldrake, a Human Warlock\.')
    $kf = @(Get-KeyFacts @(
        @{ k = 'quest'; act = 'accept'; title = 'The Stockade Riots' }, @{ k = 'quest'; act = 'turnin'; title = 'The Stockade Riots' },
        @{ k = 'enter'; inst = 'The Stockade' }, @{ k = 'boss'; name = 'Bazil Thredd' }, @{ k = 'level'; level = 25 },
        @{ k = 'death'; killer = 'Targorr the Dread' }, @{ k = 'death'; who = 'Seph' }, @{ k = 'group'; act = 'join'; who = 'Tobin Fairweather' },
        @{ k = 'chat'; ch = 'say'; who = 'X'; text = 'y' }) 'Maren')
    Check 'key facts, without those who joined' (($kf | ForEach-Object { $_.What }) -join '|') 'entered The Stockade|defeated Bazil Thredd|level 25|death, killed by Targorr the Dread'
    Check 'a player who only passed through may be left out' (@(Test-Coverage 'Maren entered The Stockade, saw Bazil Thredd fall, reached level 25, and was killed by Targorr the Dread.' $kf).Count) 0
    Check 'a level written in words counts' (@(Test-Coverage 'Maren entered The Stockade, saw Bazil Thredd fall, reached her twenty-fifth level, and was killed by Targorr the Dread.' $kf).Count) 0
    Check 'number words' ((Get-NumberWords 28) -join '|') 'twenty-eight|twenty-eighth'
    Check 'number words for a ten' ((Get-NumberWords 30) -join '|') 'thirty|thirtieth'
    $ovSrc = "## One (line)`nMaren met Seph in Darkshire.`n## Two (line)`nMaren reached level 25."
    Check 'a sound overview has no faults' (@(Test-Overview "## One`n`nMaren met Seph in Darkshire.`n`n{{picture 1}}`n`n## Two`n`nShe reached level 25." @('One', 'Two') $ovSrc).Count) 0
    True 'a missing section is a fault' (((Test-Overview "## One`n`nMaren met Seph and reached level 25." @('One', 'Two') $ovSrc) -join '|') -match '^It has 1 section for 2 entries')
    True 'a wrong heading is a fault' (((Test-Overview "## One`n`nMaren met Seph.`n`n## Second`n`nMaren reached level 25." @('One', 'Two') $ovSrc) -join '|') -match 'Section 2 is headed "Second"')
    True 'an invented name is a fault' (((Test-Overview "## One`n`nMaren met Zanzibar.`n`n## Two`n`nMaren reached level 25." @('One', 'Two') $ovSrc) -join '|') -match 'do not hold: Zanzibar\.')
    True 'talk about sources is a fault' (((Test-Overview "## One`n`nMaren met Seph.`n`n## Two`n`nIn the next chapter Maren reached level 25." @('One', 'Two') $ovSrc) -join '|') -match 'talks about its sources: the next chapter')
    True 'a correction holds the prompt, the faults and the reply' ((New-OverviewCorrection 'PROMPT' 'REPLY' @('Fault one.')) -match '(?s)^PROMPT\r?\n\r?\n# Correction.*- Fault one\..*"""\r?\nREPLY\r?\n"""')
    True 'narrator told to prefer names to they' ((Get-NarratorRules) -match 'Repeat the name or recast the sentence')
    True 'overview keeps the rules for other players' ((Get-OverviewRules) -match 'name only those who shaped' -and (Get-OverviewRules) -match 'repeat the name or recast the sentence' -and (Get-OverviewRules -Continue) -match 'reported speech by default')
    Check 'nothing lost' (@(Test-Coverage 'Maren took The Stockade Riots, entered The Stockade with Tobin, saw Bazil Thredd fall, reached level 25, and was killed by Targorr the Dread.' $kf).Count) 0
    Check 'lost facts reported' ((Test-Coverage 'Maren entered The Stockade with Tobin and reached level 25.' $kf) -join '|') 'defeated Bazil Thredd|death, killed by Targorr the Dread'
    True 'no empty screenshots heading' ((Format-SessionMarkdown 'T' 'L' 'Body.' $null) -notmatch 'Screenshots')
    $parts = @(Split-RecordLines @('aaaa', 'bbbb', 'cccc', 'dddd') 10)
    Check 'split in order' (($parts | ForEach-Object { $_ -join '' }) -join '|') 'aaaabbbb|ccccdddd'
    $r = ConvertFrom-SummaryReply "TITLE: Into Duskwood`n`n# Heading`nBaldrake went on."
    Check 'title' $r.Title 'Into Duskwood'
    Check 'body without headings' $r.Body 'Baldrake went on.'
    Check 'no title' (ConvertFrom-SummaryReply 'Just text.').Title ''

    # Session files and the snapshot -----------------------------------------------------------------------------------------
    $md = Format-SessionMarkdown 'Into Duskwood' 'Baldrake' 'Baldrake went on.' @([pscustomobject]@{ Path = '../screenshots/a.jpg'; Caption = 'Level up, 21:02' })
    $doc = Read-SessionMarkdown $md
    Check 'title read back' $doc.Title 'Into Duskwood'
    Check 'line read back' $doc.Line 'Baldrake'
    True 'screenshots in the body' ($doc.Body -match '!\[Level up, 21:02\]\(\.\./screenshots/a\.jpg\)')
    $sessDir = Join-Path $tmp 'sessions'
    New-Item -ItemType Directory $sessDir | Out-Null
    Check 'first file of a day' (Get-SessionFileName $sessDir $T) '2026-11-12-1.md'
    [IO.File]::WriteAllText((Join-Path $sessDir '2026-11-12-1.md'), 'x')
    Check 'second file of a day' (Get-SessionFileName $sessDir $T) '2026-11-12-2.md'
    $lua = New-JournalSnapshotLua ([pscustomobject]@{ Revision = 2; Written = $T; Characters = @(
        [pscustomobject]@{ Key = "Adra$([char]0xEB)l-Realm"; Confirmed = 9; Sessions = @(
            [pscustomobject]@{ S = 2; Title = 'He said "end" ]] --'; First = $T; Last = $T + 5; Zones = @('Duskwood'); LevelFrom = 26; LevelTo = 27; File = 'data\x.md'; Text = "Line one`nLine two"
                Shots = @([pscustomobject]@{ Name = 'a.jpg'; Thumb = 'Interface\AddOns\JourneyMaster\Thumbs\X\a'; W = 455; H = 256 }) },
            [pscustomobject]@{ S = 1; Title = 'Older'; First = $T - 9; Last = $T - 5; Zones = @(); LevelFrom = $null; LevelTo = $null; File = 'data\y.md'; Text = $null }) }) })
    Check 'snapshot passes its check' (Test-JournalSnapshotLua $lua) ''
    True 'snapshot with an overview passes its check' ((Test-JournalSnapshotLua (New-JournalSnapshotLua ([pscustomobject]@{ Revision = 1; Written = $T; Characters = @([pscustomobject]@{ Key = 'A-B'; Confirmed = 1; Overview = "## One`n`nText"; Sessions = @() }) }))) -eq '')
    Check 'overview reply keeps its section headings' (ConvertFrom-OverviewReply "TITLE: x`n`n## One`n`nText`n`n## Two`n`nMore") "## One`n`nText`n`n## Two`n`nMore"
    True 'the first overview asks for a section for each session' ((Get-OverviewRules) -match 'one section for each entry' -and (Get-OverviewRules) -notmatch 'new entries only')
    True 'a continuation asks for the new sections only' ((Get-OverviewRules -Continue) -match 'only the sections for the new entries')
    # The overview's picture: one for each session, from the journey rather than a level-up.
    $sh = @(
        [pscustomobject]@{ Caption = 'Level up, 20:55'; Path = '../screenshots/2026-11-13_205542-level.jpg'; Name = '2026-11-13_205542-level.jpg' },
        [pscustomobject]@{ Caption = 'Exploring Wetlands, 22:43'; Path = '../screenshots/2026-11-13_224357-zone.jpg'; Name = '2026-11-13_224357-zone.jpg' },
        [pscustomobject]@{ Caption = 'Level up, 23:26'; Path = '../screenshots/2026-11-13_232610-level.jpg'; Name = '2026-11-13_232610-level.jpg' })
    $sessEnd = [pscustomobject]@{ Entries = @(@{ k = 'login' }, @{ k = 'end' }) }
    $sessOpen = [pscustomobject]@{ Entries = @(@{ k = 'login' }, @{ k = 'note' }) }
    True 'a session the player finished can be summarised' (Test-SessionFinishedByPlayer $sessEnd $true)
    True 'an earlier session can be summarised' (Test-SessionFinishedByPlayer $sessOpen $false)
    True 'the latest session, not finished, cannot' (-not (Test-SessionFinishedByPlayer $sessOpen $true))
    Check 'a stay beats level-ups' (Select-OverviewShot $sh).Name '2026-11-13_224357-zone.jpg'
    Check 'a boss beats a stay' (Select-OverviewShot ($sh + [pscustomobject]@{ Caption = 'Boss defeated, 23:00'; Path = '../screenshots/2026-11-13_230000-boss.jpg'; Name = '2026-11-13_230000-boss.jpg' })).Name '2026-11-13_230000-boss.jpg'
    Check 'only level-ups: the middle one' (Select-OverviewShot @($sh[0], $sh[2], $sh[0])).Name '2026-11-13_232610-level.jpg'
    Check 'no pictures, no pick' (Select-OverviewShot @()) $null
    $entryBody = Get-OverviewEntryBody "First.`n`n![Level up, 20:55](../screenshots/2026-11-13_205542-level.jpg)`n`nSecond.`n`n## Screenshots`n`n![Exploring Wetlands, 22:43](../screenshots/2026-11-13_224357-zone.jpg)`n" '2026-11-13_224357-zone.jpg' 3
    Check 'the entry shows only the chosen picture, as a marker' $entryBody "First.`n`nSecond.`n`n[picture 3: Exploring Wetlands, 22:43]"
    $ovShots = @([pscustomobject]@{ N = 1; Path = 'screenshots/a.jpg'; Caption = 'One, 10:00' }, [pscustomobject]@{ N = 2; Path = 'screenshots/b.jpg'; Caption = 'Two, 11:00' })
    $ovText = Add-OverviewPictures "## A`n`nText a.`n`n{{picture 1}}`n`nMore a.`n`n## B`n`nText b." $ovShots 2
    True 'a placed picture stays where the AI put it' ($ovText -match '(?s)Text a\.\s+!\[One, 10:00\]\(screenshots/a\.jpg\)\s+More a\.')
    True 'an unplaced picture goes to the end of its section' ($ovText -match '(?s)Text b\.\s+!\[Two, 11:00\]\(screenshots/b\.jpg\)\s*$')
    True 'a marker for no picture is dropped' ((Add-OverviewPictures "## A`n`nX {{picture 9}} y." $ovShots 1) -notmatch '\{\{')
    Check 'tampered snapshot refused' (Test-JournalSnapshotLua ($lua + "`nos.exit()")) 'unexpected text outside string values'
    Check 'ascii only' ([regex]::IsMatch($lua, '[^\x00-\x7F]')) $false
    Check 'cut on a character' (Get-SnapshotText ('ab' + [char]0xE9 + 'cd') 3).StartsWith('ab' + [char]0xE9) $false

    # Screenshots: the pictures a session links, and their thumbnails for the game.
    $shots = @(Get-SessionShots "Text.`n`n![Level up, 21:02](../screenshots/a.jpg)`n`n![Boss, 22:00](../screenshots/b.png)`n")
    Check 'pictures found' $shots.Count 2
    Check 'picture name' $shots[1].Name 'b.png'
    Check 'picture caption' $shots[0].Caption 'Level up, 21:02'
    Add-Type -AssemblyName System.Drawing
    $imgPath = Join-Path $tmp 'shot.jpg'
    $bmp = New-Object System.Drawing.Bitmap 1920, 1080
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.Clear([System.Drawing.Color]::Red); $g.Dispose()
    $bmp.Save($imgPath, [System.Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
    $tga = Join-Path $tmp 'thumbs\shot.tga'
    $fit = New-Thumbnail $imgPath $tga
    Check 'thumbnail width' $fit.W 455
    Check 'thumbnail height' $fit.H 256
    $bytes = [IO.File]::ReadAllBytes($tga)
    Check 'thumbnail file size' $bytes.Length (18 + 512 * 256 * 3)
    Check 'thumbnail is uncompressed true colour' $bytes[2] 2
    Check 'thumbnail is 24-bit' $bytes[16] 24
    $top = 18 + (255 - 10) * 512 * 3 + 10 * 3 # 10 pixels in from the top left; the file's last row is the picture's top
    # row (the edge pixels blend with the black around the picture)
    True 'picture red at the top left' ($bytes[$top] -lt 30 -and $bytes[$top + 2] -gt 220)
    True 'black right of the picture' ($bytes[18 + 500 * 3] -eq 0 -and $bytes[18 + 500 * 3 + 2] -eq 0)
    Check 'an existing thumbnail is kept' (New-Thumbnail $imgPath $tga).W 455
    [IO.File]::WriteAllBytes((Join-Path $tmp 'junk.jpg'), [byte[]](1, 2, 3))
    True 'no thumbnail from a file that is not an image' ($null -eq (New-Thumbnail (Join-Path $tmp 'junk.jpg') (Join-Path $tmp 'junk.tga')))

    # The snapshot loads in Lua as the add-on reads it (needs Python with Lupa, as the Lua harnesses do).
    $snapPath = Join-Path $tmp 'JournalSnapshot.lua'
    [IO.File]::WriteAllText($snapPath, $lua, $Utf8)
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py) {
        $check = "from lupa.lua51 import LuaRuntime; import sys; r = LuaRuntime(); ns = r.eval('{}'); f = r.eval('function(src, ns) return assert(loadstring(src))(\'JourneyMaster\', ns) end'); f(open(sys.argv[1], encoding='utf-8').read(), ns); c = ns.journalSnapshot.characters; k = list(c.keys())[0]; s = c[k].sessions; print(k + '|' + s[1].title + '|' + s[1].text.replace('\n', '/') + '|' + str(s[2].text) + '|' + s[1].shots[1].thumb + '|' + str(s[1].shots[1].w))"
        $env:PYTHONIOENCODING = 'utf-8'
        $prevEnc = [Console]::OutputEncoding
        [Console]::OutputEncoding = $Utf8
        try { $out = & python -c $check $snapPath 2>&1 } finally { [Console]::OutputEncoding = $prevEnc; Remove-Item Env:PYTHONIOENCODING }
        Check 'snapshot read by Lua' ([string]$out) ("Adra$([char]0xEB)l-Realm|He said `"end`" ]] --|Line one/Line two|None|Interface\AddOns\JourneyMaster\Thumbs\X\a|455")
    } else { Write-Host 'python not found: the Lua load check was skipped' -ForegroundColor Yellow }

    # Whole runs of the app ---------------------------------------------------------------------------------------------------
    $wow = Join-Path $tmp 'wow'
    $data = Join-Path $tmp 'data'
    $addon = Join-Path $wow 'Interface\AddOns\JourneyMaster'
    New-Item -ItemType Directory -Force $addon, (Join-Path $wow 'Logs'), (Join-Path $wow 'Screenshots') | Out-Null
    Copy-Item (Join-Path $Root 'src\JourneyMaster\JournalSnapshot.lua') $addon
    $sv = Join-Path $wow 'WTF\Account\TEST\SavedVariables\JourneyMaster.lua'
    $calls = Join-Path $tmp 'calls'
    $env:FAKE_CLAUDE_LOG = $calls
    $env:FAKE_CLAUDE_INVENT = '0'
    $shotTime = ConvertFrom-Epoch ($T + 122)
    Copy-Item $imgPath (Join-Path $wow ("Screenshots\WoWScrnShot_" + $shotTime.ToString('MMddyy_HHmmss') + '.jpg'))
    [IO.File]::Copy($logPath, (Join-Path $wow 'Logs\WoWChatLog.txt'))
    $session1 = @(
        @{ i = 1; s = 1; t = $T - 7200; k = 'login'; lvl = 26; z = 'Stormwind City'; sz = 'Trade District' },
        @{ i = 2; s = 1; t = $T - 7000; k = 'quest'; act = 'accept'; id = 223; title = 'Worgen in the Woods'; giver = 'Calor'; text = 'Bring this message to Master Carevin.'; z = 'Duskwood'; sz = 'Darkshire' },
        @{ i = 3; s = 1; t = $T - 6900; k = 'chat'; ch = 'say'; who = 'Shelly Whitemoon'; text = 'Does anyone know where the Bowyer is?'; z = 'Duskwood' },
        @{ i = 4; s = 1; t = $T - 6800; k = 'logout'; z = 'Duskwood' }
    )
    $session2 = @(
        @{ i = 5; s = 2; t = $T - 10; k = 'login'; lvl = 26; z = 'Stormwind City' },
        @{ i = 6; s = 2; t = $T; k = 'enter'; inst = 'The Stockade'; itype = 'party'; z = 'The Stockade' },
        @{ i = 7; s = 2; t = $T + 82; k = 'death'; recap = 'ok'; killer = 'Bazil Thredd'; spell = 'melee'; z = 'The Stockade' },
        @{ i = 8; s = 2; t = $T + 120; k = 'level'; level = 27; z = 'The Stockade' },
        @{ i = 9; s = 2; t = $T + 121; k = 'shot'; why = 'level'; z = 'The Stockade' },
        @{ i = 10; s = 2; t = $T + 600; k = 'leave'; inst = 'The Stockade'; itype = 'party'; z = 'Stormwind City' },
        @{ i = 11; s = 2; t = $T + 700; k = 'logout'; z = 'Stormwind City' }
    )
    $char = [ordered]@{ name = 'Baldrake Cavendell'; realm = 'Living Flame'; race = 'Human'; class = 'Warlock'; faction = 'Alliance'; level = 27; seq = 11; dropped = 0; entries = @($session1 + $session2); settings = @{ aiModel = 'opus'; aiEffort = 'low' } }
    Write-TestSV $sv @{ schema = 1; characters = @{ 'Baldrake Cavendell-LivingFlame' = $char } }
    # $run summarises every finished session (-SummariseAll, as the app did on its own); $runPlain is the app's normal run,
    # which summarises only on the game's Summarise signal.
    $run = { param([long]$Now, [string]$Running = 'no', [string[]]$More = @())
        & powershell -NoProfile -ExecutionPolicy Bypass -File $App -WowDir $wow -DataDir $data -ClaudePath $Fake -GameRunning $Running -Now $Now -LoreDir (Join-Path $tmp 'nolore') -NoExplorer -SummariseAll @More 2>&1 | Out-String }
    $runPlain = { param([long]$Now, [string]$Running = 'no', [string[]]$More = @())
        & powershell -NoProfile -ExecutionPolicy Bypass -File $App -WowDir $wow -DataDir $data -ClaudePath $Fake -GameRunning $Running -Now $Now -LoreDir (Join-Path $tmp 'nolore') -NoExplorer @More 2>&1 | Out-String }

    # The game is still running: the first session (logged out, then a later session) is summarised; the dungeon session
    # waits for the game to close.
    $out = & $run ($T + 800) 'yes'
    $charDir = Join-Path $data 'journeys\Baldrake Cavendell-LivingFlame'
    Check 'events stored' @(Get-ChildItem (Join-Path $charDir 'events') -Filter '*.jsonl').Count 1
    Check 'one session summarised while the game runs' @(Get-ChildItem (Join-Path $charDir 'sessions')).Count 1
    $firstCalls = @(Get-ChildItem $calls).Count
    Check 'one summary call and one overview call' $firstCalls 2
    $firstCall = Get-Content -Raw (Get-ChildItem $calls | Sort-Object { [int]($_.BaseName -replace '\D', '') } | Select-Object -First 1).FullName
    True 'Opus and low effort by default' ($firstCall -match '--model opus' -and $firstCall -match '--effort low')
    $snap = Read-FileText (Join-Path $addon 'JournalSnapshot.lua')
    True 'snapshot written' ($snap -match 'revision = 1,')
    True 'snapshot holds the overview' ($snap -match 'overview = "')
    True 'snapshot confirms the stored entries' ($snap -match 'confirmed = 11,')

    # The game closes soon after the logout: the session waits 30 minutes, in case the player logs back in.
    $out = & $run ($T + 900) 'no'
    Check 'a logout with the game closed waits 30 minutes' @(Get-ChildItem (Join-Path $charDir 'sessions')).Count 1

    # 30 minutes on: the dungeon session is summarised with its chat log lines.
    $out = & $run ($T + 2600) 'no'
    $files = @(Get-ChildItem (Join-Path $charDir 'sessions') | Sort-Object Name)
    Check 'two sessions summarised' $files.Count 2
    $prompt = Get-Content -Raw (Get-ChildItem $calls | Sort-Object { [int]($_.BaseName -replace '\D', '') } | Select-Object -Index $firstCalls).FullName
    True 'prompt holds the party chat from the chat log' ($prompt -match 'Seph Stormbrewer \(player\) said in party chat \(from the chat log\): "come to me"')
    True 'prompt holds the boss yell, speaker unknown' ($prompt -match '\[background\] Bazil Thredd \(an NPC, or a player outside the group\) yelled \(from the chat log\)')
    True 'prompt holds the killer' ($prompt -match 'killed by Bazil Thredd')
    True 'prompt leaves lines outside the window out' ($prompt -notmatch 'too early|too late')
    True 'prompt holds the narrator rules' ($prompt -match '--system-prompt-file')
    True 'no tools for the AI' ($prompt -match '--tools\s+--system-prompt-file')
    $md = Read-FileText $files[1].FullName
    True 'session file has a title' ($md -match '^# Session record')
    True 'session file has the header line' ($md -match 'level 26 to 27')
    True 'session file links the screenshot' ($md -match '!\[Level up, \d\d:\d\d\]\(\.\./screenshots/2026-11-12_\d{6}-level\.jpg\)')
    True 'prompt marks the picture' ($prompt -match '\d\d:\d\d \[picture 1: Level up\]')
    True 'the placed picture is in the account, not at the end' ($md -notmatch '## Screenshots' -and $md -notmatch '\{\{')
    Check 'records kept beside the summaries' @(Get-ChildItem (Join-Path $charDir 'records') -Filter '*.txt').Count 2
    True 'record holds the chat log lines' ((Read-FileText (Join-Path $charDir 'records/2026-11-12-2.txt')) -match 'from the chat log')
    True 'no key events section in the prompt' ($prompt -notmatch '# Key events')
    Check 'screenshot copied' @(Get-ChildItem (Join-Path $charDir 'screenshots')).Count 1
    True 'overview written' (Test-Path (Join-Path $charDir 'overview.md'))
    $ovFile = Read-FileText (Join-Path $charDir 'overview.md')
    True 'overview has a heading for each session in order' ($ovFile -match '(?s)^# The journey of Baldrake Cavendell so far\r?\n.*## Session record\r?\n.*## Session record\r?\n')
    True 'no journal.md is written' (-not (Test-Path (Join-Path $charDir 'journal.md')))
    $snap = Read-FileText (Join-Path $addon 'JournalSnapshot.lua')
    True 'snapshot revision 2' ($snap -match 'revision = 2,')
    True 'the overview holds one picture of the session' ((Read-FileText (Join-Path $charDir 'overview.md')) -match '!\[Level up, \d\d:\d\d\]\(screenshots/2026-11-12_\d{6}-level\.jpg\)')
    True 'the snapshot lists the overview picture' ($snap -match 'overviewShots = \{ \{ name = ')
    $thumbs = @(Get-ChildItem (Join-Path $addon 'Thumbs') -Recurse -Filter '*.tga')
    Check 'thumbnail made in the add-on folder' $thumbs.Count 1
    Check 'thumbnail folder named safely' $thumbs[0].Directory.Name 'Baldrake_Cavendell-LivingFlame'
    True 'snapshot lists the thumbnail' ($snap -match 'shots = \{ \{ name = ')

    # The game's buttons reach the app through the chat log: only what was added since the app's last look is read.
    $gameLog = Join-Path $wow 'Logs\WoWChatLog.txt'
    $from = (Get-Item $gameLog).Length
    $stampNow = (ConvertFrom-Epoch ($T + 2650)).ToString('M/d HH:mm:ss.fff') + '  '
    $added = @(
        ($stampNow + 'JMS:9-1:OPEN:2:Baldrake Cavendell-LivingFlame'),
        ($stampNow + 'JMS:9-1:OPEN:2:Baldrake Cavendell-LivingFlame'),
        ($stampNow + 'JMP:9-1:00001:' + ('.' * 186)),
        ($stampNow + 'Mallory says: JMS:9-2:OPEN:1:Baldrake Cavendell-LivingFlame'),
        ($stampNow + 'JMS:9-3:END:3:Baldrake Cavendell-LivingFlame'),
        ($stampNow + 'JMS:9-4:OPEN:1:Nobody-Realm'),
        ($stampNow + 'JMS:9-5:SET:model=sonnet:Baldrake Cavendell-LivingFlame'),
        ($stampNow + 'JMS:9-6:SET:effort=turbo:Baldrake Cavendell-LivingFlame')
    )
    [IO.File]::AppendAllText($gameLog, ($added -join "`r`n") + "`r`n", $Utf8)
    $out = & $run ($T + 2660) 'no' @('-SignalsFrom', "$from")
    Check 'open signal answered once, with the screenshot' ([regex]::Matches($out, 'opening .*screenshots\\2026-11-12_\d{6}-level\.jpg, as asked').Count) 1
    True 'a player saying a signal opens nothing' ($out -notmatch 'opening .*Screenshots, as asked')
    True 'finish signal noted' ($out -match 'session 3 finished in the game')
    True 'unknown character reported' ($out -match 'Nobody-Realm, a character the app has no record of')
    True 'model change from the game taken' ($out -match 'AI model set to sonnet')
    True 'unknown effort refused' ($out -match 'unknown AI setting effort=turbo')
    $out = & $run ($T + 2670) 'no'
    True 'old signals not acted on by a later run' ($out -notmatch 'as asked in the game')

    # A player's edit to a session file is kept and shown in the snapshot; a rerun changes nothing and calls no AI.
    $edited = (Read-FileText $files[0].FullName) + "`nAdded by hand.`n"
    [IO.File]::WriteAllText($files[0].FullName, $edited, $Utf8)
    $before = @(Get-ChildItem $calls).Count
    $out = & $run ($T + 2700) 'no'
    Check 'rerun calls no AI' @(Get-ChildItem $calls).Count $before
    Check 'edited file untouched' (Read-FileText $files[0].FullName) $edited

    # Phase 4: a long session is summarised in parts, and an invented name is asked for again.
    $env:FAKE_CLAUDE_INVENT = '1'
    $long = @(@{ i = 12; s = 3; t = $T + 5000; k = 'login'; lvl = 27; z = 'Elwynn Forest' })
    for ($n = 0; $n -lt 40; $n++) { $long += @{ i = 13 + $n; s = 3; t = $T + 5010 + $n * 10; k = 'chat'; ch = 'say'; who = 'Shelly Whitemoon'; text = "Line number $n of a long evening in Goldshire."; z = 'Elwynn Forest' } }
    $long += @{ i = 53; s = 3; t = $T + 5500; k = 'end'; z = 'Elwynn Forest' } # finished by the player: summarised at once
    $char.entries = @($session1 + $session2 + $long)
    $char.seq = 53
    Write-TestSV $sv @{ schema = 1; characters = @{ 'Baldrake Cavendell-LivingFlame' = $char } }
    $before = @(Get-ChildItem $calls).Count
    $out = & $run ($T + 6000) 'no' @('-MaxPromptChars', '1200', '-NoOverview')
    $new =@(Get-ChildItem $calls | Sort-Object { [int]($_.BaseName -replace '\D', '') } | Select-Object -Skip $before)
    True 'long session in several parts' ($new.Count -ge 4)
    True 'the model chosen in the game is used, and the old saved file does not undo it' ((Get-Content -Raw $new[0].FullName) -match '--model sonnet')
    $texts = @($new | ForEach-Object { Get-Content -Raw $_.FullName })
    True 'a later part carries the account so far' (@($texts | Where-Object { $_ -match 'this is piece 2' -and $_ -match 'The account so far' }).Count -ge 1)
    True 'a reply is not asked for again' (@($texts | Where-Object { $_ -match '# Correction' }).Count -eq 0)
    $files = @(Get-ChildItem (Join-Path $charDir 'sessions') | Sort-Object Name)
    Check 'third session file' $files.Count 3
    $md3 = Read-FileText $files[2].FullName
    True 'parts joined in order' ($md3.IndexOf('Line number 0 ') -lt $md3.LastIndexOf('Line number'))
    $state = (Read-FileText (Join-Path $data 'state.json')) | ConvertFrom-Json
    Check 'state records the parts' ([int]$state.Characters.'Baldrake Cavendell-LivingFlame'.Sessions.'3'.Parts -gt 1) $true

    # The snapshot keeps the newest sessions in full and older ones by title only.
    $out = & $run ($T + 6100) 'no' @('-FullSessions', '1')
    # Nothing new, so no snapshot is written; force one by a new entry.
    $char.entries = @($session1 + $session2 + $long + @(@{ i = 54; s = 4; t = $T + 9000; k = 'login'; z = 'Elwynn Forest' }))
    $char.seq = 54
    Write-TestSV $sv @{ schema = 1; characters = @{ 'Baldrake Cavendell-LivingFlame' = $char } }
    $out = & $run ($T + 9001) 'yes' @('-FullSessions', '1')
    $snap = Read-FileText (Join-Path $addon 'JournalSnapshot.lua')
    Check 'texts in the snapshot' ([regex]::Matches($snap, 'text = ').Count) 1
    # A session listed by title only has no thumbnail of its own, but the overview keeps its one picture.
    Check 'only the overview picture keeps a thumbnail' @(Get-ChildItem (Join-Path $addon 'Thumbs') -Recurse -Filter '*.tga').Count 1
    True 'the snapshot still lists the overview picture' ($snap -match 'overviewShots = \{ \{ name = ')
    True 'confirmed follows the record' ($snap -match 'confirmed = 54,')

    # Entries that arrive for a session already summarised are reported, not silently left out.
    $char.entries = @($session1 + $session2 + $long + @(@{ i = 54; s = 4; t = $T + 9000; k = 'login'; z = 'Elwynn Forest' },
        @{ i = 55; s = 3; t = $T + 9200; k = 'note'; text = 'late'; z = 'Elwynn Forest' }))
    $char.seq = 55
    Write-TestSV $sv @{ schema = 1; characters = @{ 'Baldrake Cavendell-LivingFlame' = $char } }
    $out = & $run ($T + 9300) 'yes'
    True 'late entries for a summarised session reported' ($out -match '1 entries arrived after session 3 was summarised')

    # Nothing is summarised on its own: session 4 (logged in, game closed long ago) waits for the game's Summarise button,
    # which reaches the app as a SUMMARISE signal.
    $sessionsBefore = @(Get-ChildItem (Join-Path $charDir 'sessions')).Count
    $before = @(Get-ChildItem $calls).Count
    $out = & $runPlain ($T + 90000) 'no'
    Check 'a plain run summarises nothing' @(Get-ChildItem (Join-Path $charDir 'sessions')).Count $sessionsBefore
    Check 'a plain run calls no AI' @(Get-ChildItem $calls).Count $before
    $from = (Get-Item $gameLog).Length
    $stampNow = (ConvertFrom-Epoch ($T + 90100)).ToString('M/d HH:mm:ss.fff') + '  '
    [IO.File]::AppendAllText($gameLog, (@(($stampNow + 'JMS:9-7:SUMMARISE:99:Baldrake Cavendell-LivingFlame'), ($stampNow + 'JMS:9-8:SUMMARISE:4:Baldrake Cavendell-LivingFlame')) -join "`r`n") + "`r`n", $Utf8)
    $out = & $runPlain ($T + 90200) 'yes' @('-SignalsFrom', "$from")
    True 'a request for a session the file does not hold is reported' ($out -match 'session 99, which the saved file does not hold')
    True 'a request for a session not finished is refused' ($out -match 'session 4 is not finished')
    Check 'and nothing is summarised' @(Get-ChildItem (Join-Path $charDir 'sessions')).Count $sessionsBefore
    # The player finishes session 4 (an end entry); the same request now succeeds.
    $char.entries = @($session1 + $session2 + $long + @(@{ i = 54; s = 4; t = $T + 9000; k = 'login'; z = 'Elwynn Forest' },
        @{ i = 55; s = 3; t = $T + 9200; k = 'note'; text = 'late'; z = 'Elwynn Forest' }, @{ i = 56; s = 4; t = $T + 9400; k = 'end'; z = 'Elwynn Forest' }))
    $char.seq = 56
    Write-TestSV $sv @{ schema = 1; characters = @{ 'Baldrake Cavendell-LivingFlame' = $char } }
    $out = & $runPlain ($T + 90250) 'yes' @('-SignalsFrom', "$from")
    True 'the finished session is summarised' ($out -match 'summarising session 4, as asked in the game' -and $out -match 'summarised session 4')
    Check 'the requested session has its file' @(Get-ChildItem (Join-Path $charDir 'sessions')).Count ($sessionsBefore + 1)
    Check 'one summary call and one overview call for it' (@(Get-ChildItem $calls).Count - $before) 2
    $out = & $runPlain ($T + 90300) 'yes' @('-SignalsFrom', "$from")
    True 'a repeated request is answered without a summary' ($out -match 'session 4 is already summarised')
    Check 'and calls no AI' (@(Get-ChildItem $calls).Count - $before) 2

    # The overview is checked: one with an invented name is asked for once more, and the corrected one is kept.
    $env:FAKE_CLAUDE_OVERVIEW_FAULT = '1'
    $char.entries = @($char.entries) + @(@{ i = 57; s = 5; t = $T + 95000; k = 'login'; z = 'Elwynn Forest' }, @{ i = 58; s = 5; t = $T + 95100; k = 'end'; z = 'Elwynn Forest' })
    $char.seq = 58
    Write-TestSV $sv @{ schema = 1; characters = @{ 'Baldrake Cavendell-LivingFlame' = $char } }
    $from = (Get-Item $gameLog).Length
    [IO.File]::AppendAllText($gameLog, ((ConvertFrom-Epoch ($T + 95200)).ToString('M/d HH:mm:ss.fff') + '  JMS:9-9:SUMMARISE:5:Baldrake Cavendell-LivingFlame') + "`r`n", $Utf8)
    $before = @(Get-ChildItem $calls).Count
    $out = & $runPlain ($T + 95300) 'yes' @('-SignalsFrom', "$from")
    True 'a faulty overview is reported' ($out -match 'the overview has 1 fault; asking the AI once more')
    Check 'a summary call, an overview call and one more overview call' (@(Get-ChildItem $calls).Count - $before) 3
    $lastCall = Get-Content -Raw (Get-ChildItem $calls | Sort-Object { [int]($_.BaseName -replace '\D', '') } | Select-Object -Last 1).FullName
    True 'the second call names the fault and holds the first reply' ($lastCall -match '# Correction' -and $lastCall -match 'the entries do not hold: Mordecai, Vandermeer' -and $lastCall -match 'Mordecai Vandermeer watched\.')
    True 'the corrected overview is kept' ((Read-FileText (Join-Path $charDir 'overview.md')) -notmatch 'Mordecai')
    True 'no fault is left' ($out -notmatch 'overview fault left')
} finally {
    Remove-Item Env:FAKE_CLAUDE_OVERVIEW_FAULT -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CLAUDE_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CLAUDE_INVENT -ErrorAction SilentlyContinue
    if ($failures -eq 0) { Remove-Item -Recurse -Force $tmp } else { Write-Host "Test files kept in $tmp" }
}

if ($failures -gt 0) { Write-Host "$failures checks failed" -ForegroundColor Red; exit 1 }
Write-Host 'app harness: all checks passed' -ForegroundColor Green
