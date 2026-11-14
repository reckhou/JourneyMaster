<#
.SYNOPSIS
Writes a character's journey overview with one AI model and effort, as the app does, and saves the result for comparison.

.DESCRIPTION
Reads the character's session files (data\journeys\<character>\sessions), builds the overview rules and prompt exactly as
the app's Update-Overview does (the whole overview, never a continuation), and calls the claude command with the given
model and effort. Like the app, it checks the reply (a section for each session under its title, no name or number the
summaries do not hold, no talk about its sources) and asks once more when it finds faults, keeping the reply with fewer.
It writes <OutDir>\<Label>.md (the overview, with its pictures) and <Label>.json (timing, cost, faults left). It never
changes the real journal, state or overview.
Example:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\compare_overview.ps1 -Label opus-high -Model opus -Effort high -Skip 1,2
Kept ASCII-only: Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
#>
param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][string]$Effort,
    [string]$Character = 'Baldrake-CAMWOWEU4Realm10RP',
    [string]$Skip = '',   # session numbers to leave out, comma-separated (for example ones deleted in the game the app has not handled yet)
    [string]$DataDir,
    [string]$OutDir,
    [string]$ClaudePath,
    [string]$ExtraRules    # a text file added after the overview rules (a rule change under test)
)
$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $DataDir) { $DataDir = Join-Path $Here '..\data' }
if (-not $OutDir) { $OutDir = Join-Path $Here '..\private-local\compare\overview' }
Import-Module (Join-Path $Here '..\src\App\JourneyMasterApp.psm1') -Force
$Utf8 = New-Object Text.UTF8Encoding $false
$DataDir = [IO.Path]::GetFullPath($DataDir)
$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force $OutDir | Out-Null
if (-not $ClaudePath) { $ClaudePath = (Get-Command claude -ErrorAction Stop | Select-Object -First 1).Source }
# A private empty working directory per run, so parallel runs do not clash.
$WorkDir = Join-Path $OutDir "cwd-$Label"
New-Item -ItemType Directory -Force $WorkDir | Out-Null

$state = (Read-FileText (Join-Path $DataDir 'state.json')) | ConvertFrom-Json
# A string, not [long[]]: powershell -File passes "1,2" as one string, which [long] would read as 12.
$SkipList = @($Skip -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [long]$_ })
$c = $state.Characters.$Character
if (-not $c) { throw "No character $Character in state.json" }
$sessionsDir = Join-Path $DataDir "journeys\$($c.Folder)\sessions"

# The session documents, oldest first, as the app's Get-SessionDocs gives them.
$docs = @(foreach ($p in $c.Sessions.PSObject.Properties) {
    if ($SkipList -contains [long]$p.Name) { continue }
    $s = $p.Value
    $path = Join-Path $sessionsDir $s.File
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $doc = Read-SessionMarkdown (Read-FileText $path)
    [pscustomobject]@{ Number = [long]$p.Name; S = $s; Title = $(if ($doc.Title) { $doc.Title } else { $s.Title }); Line = $doc.Line; Body = $doc.Body }
}) | Sort-Object { [long]$_.S.First }
if ($docs.Count -eq 0) { throw 'No session files to write an overview from' }

$entries = @(); $pictures = @(); $n = 0
foreach ($d in $docs) {
    $n++
    $pick = Select-OverviewShot @(Get-SessionShots $d.Body)
    if ($pick) { $pictures += [pscustomobject]@{ N = $n; Path = "screenshots/$($pick.Name)"; Caption = $pick.Caption } }
    $entries += [pscustomobject]@{ Title = $d.Title; Line = $d.Line; Body = (Get-OverviewEntryBody $d.Body $(if ($pick) { $pick.Name } else { '' }) $n) }
}
$rules = Get-OverviewRules
if ($ExtraRules) { $rules = $rules.TrimEnd() + "`n`n" + (Read-FileText ([IO.Path]::GetFullPath($ExtraRules))).Trim() + "`n" }
$prompt = New-OverviewPrompt ([string]$c.Name) $entries ''
$rulesFile = Join-Path $WorkDir 'rules.md'
[IO.File]::WriteAllText($rulesFile, $rules, $Utf8)
[IO.File]::WriteAllText((Join-Path $OutDir 'prompt.txt'), $prompt, $Utf8)
$argList = @('-p', '--model', $Model, '--effort', $Effort, '--output-format', 'json', '--safe-mode', '--tools', '', '--system-prompt-file', $rulesFile)
function Get-Cost($r) { if ($r -and $r.PSObject.Properties['total_cost_usd']) { [double]$r.total_cost_usd } else { 0 } }

$sw = [Diagnostics.Stopwatch]::StartNew()
$titles = @($entries | ForEach-Object { [string]$_.Title })
$r = Invoke-ClaudeCli -ClaudePath $ClaudePath -Arguments $argList -WorkDir $WorkDir -Prompt $prompt
$cost = Get-Cost $r
$models = if ($r.PSObject.Properties['modelUsage']) { ($r.modelUsage.PSObject.Properties.Name -join ', ') } else { '' }
$attempts = 1
$text = if ($r.is_error -or -not $r.result) { '' } else { ConvertFrom-OverviewReply ([string]$r.result) }
if (-not $text) { throw "[$Label] the AI call failed: $($r.result)" }
$faults = @(Test-Overview $text $titles $prompt)
$firstFaults = @($faults)
if ($faults.Count -gt 0) {
    $attempts = 2
    $r2 = Invoke-ClaudeCli -ClaudePath $ClaudePath -Arguments $argList -WorkDir $WorkDir -Prompt (New-OverviewCorrection $prompt $text $faults)
    $cost += Get-Cost $r2
    $text2 = if ($r2.is_error -or -not $r2.result) { '' } else { ConvertFrom-OverviewReply ([string]$r2.result) }
    if ($text2) {
        $faults2 = @(Test-Overview $text2 $titles $prompt)
        if ($faults2.Count -le $faults.Count) { $text = $text2; $faults = $faults2 }
    }
}
$secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
$text = Add-OverviewPictures $text $pictures $entries.Count
$from = (ConvertFrom-Epoch $docs[0].S.First).ToString('d MMMM yyyy')
$to = (ConvertFrom-Epoch $docs[-1].S.Last).ToString('d MMMM yyyy')
$span = "$($docs.Count) session$(if ($docs.Count -ne 1) { 's' }), " + $(if ($from -eq $to) { $from } else { "$from to $to" })
# Picture paths are relative to the character's folder in the real overview; here they point back to it.
$text = $text -replace '\]\(screenshots/', "](../../../data/journeys/$($c.Folder)/screenshots/"
[IO.File]::WriteAllText((Join-Path $OutDir "$Label.md"), "# The journey of $($c.Name) so far`n`n*$span*`n`n$($text.Trim())`n", $Utf8)
$summary = [pscustomobject]@{
    Label = $Label; Model = $Model; Effort = $Effort; Character = $Character; Sessions = @($docs | ForEach-Object { $_.Number })
    ExtraRules = $(if ($ExtraRules) { [IO.Path]::GetFileName($ExtraRules) } else { '' })
    PromptChars = $prompt.Length; Seconds = $secs; CostUsd = $cost; Models = $models; Attempts = $attempts
    Words = ($text -split '\s+').Count; FirstFaults = $firstFaults; FaultsLeft = $faults
}
[IO.File]::WriteAllText((Join-Path $OutDir "$Label.json"), ($summary | ConvertTo-Json -Depth 6), $Utf8)
Write-Host "[$Label] done in $secs s, $attempts attempt(s), cost $cost, $($summary.Words) words, $($faults.Count) fault(s) left." -ForegroundColor Green
