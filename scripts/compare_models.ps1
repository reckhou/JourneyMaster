<#
.SYNOPSIS
Summarises one real session with one AI model and effort, using the app's own prompt and checks, and saves the result for comparison.

.DESCRIPTION
Reads the permanent record of a character (data\journeys\<character>\events), builds the record, the narrator rules and the
prompt exactly as the app does, calls the claude command with the given model and effort, and checks the reply the same way
the app does (names not in the record, key facts left out, talk about sources). It writes <OutDir>\<Label>.json (timings,
cost, checks) and <Label>.md (the title and the account). It never changes the real journal, state or session files.
Example:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\compare_models.ps1 -Label opus-low -Model opus -Effort low
Kept ASCII-only: Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
#>
param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][string]$Effort,
    [string]$Character = 'Baldrake-CAMWOWEU4Realm10RP',
    [long]$Session = 6,
    [string]$DataDir,
    [string]$OutDir,
    [string]$LoreDir,
    [string]$ClaudePath,
    [int]$Attempts = 1
)
$ErrorActionPreference = 'Stop'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $DataDir) { $DataDir = Join-Path $Here '..\data' }
if (-not $OutDir) { $OutDir = Join-Path $Here '..\private-local\compare' }
Import-Module (Join-Path $Here '..\src\App\JourneyMasterApp.psm1') -Force
$Utf8 = New-Object Text.UTF8Encoding $false
$DataDir = [IO.Path]::GetFullPath($DataDir)
$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force $OutDir | Out-Null
if (-not $LoreDir) {
    $guess = [IO.Path]::GetFullPath((Join-Path $Here '..\..\wow-forever-rp-profile\references\lore'))
    if (Test-Path -LiteralPath $guess) { $LoreDir = $guess }
}
if (-not $ClaudePath) { $ClaudePath = (Get-Command claude -ErrorAction Stop | Select-Object -First 1).Source }
# An empty working directory for the AI, as the app does, but a private one per run so parallel runs do not clash.
$WorkDir = Join-Path $OutDir "cwd-$Label"
New-Item -ItemType Directory -Force $WorkDir | Out-Null

$state = (Read-FileText (Join-Path $DataDir 'state.json')) | ConvertFrom-Json
$c = $state.Characters.$Character
$player = [string]$c.Name
$entries = Read-EventEntries (Join-Path $DataDir "journeys\$Character\events")
$sess = @(Get-Sessions $entries) | Where-Object { $_.S -eq $Session } | Select-Object -First 1
if (-not $sess) { throw "Session $Session not found for $Character" }
$windows = @(Get-InstanceWindows $sess)
if ($windows.Count -gt 0) { Write-Host "Note: the session has $($windows.Count) dungeon windows; their chat log lines are not merged here." -ForegroundColor Yellow }

$facts = Get-SessionFacts $sess $c.Level
$header = Format-RecordHeader ([pscustomobject]@{ Name = $player; Race = $c.Race; Class = $c.Class; Faction = $c.Faction; Sex = $c.Sex }) $sess $facts
$lines = @(Format-RecordLines $sess.Entries $player | ForEach-Object { "$($_.Time) $($_.Text)" })
$lore = Get-LoreText $LoreDir $facts.Zones $facts.Subzones
$rules = Get-NarratorRules
$keyFacts = @(Get-KeyFacts $sess.Entries $player)
$prompt = New-SummaryPrompt $header $lines $lore 1 1 '' @($keyFacts | ForEach-Object { $_.What })
$source = $header + "`n" + ($lines -join "`n") + "`n" + $lore + "`n$player"
$rulesFile = Join-Path $WorkDir 'rules.md'
[IO.File]::WriteAllText($rulesFile, $rules, $Utf8)

$best = $null
$attemptLog = @()
$ask = $prompt
$sw = [Diagnostics.Stopwatch]::StartNew()
for ($a = 1; $a -le $Attempts; $a++) {
    $t0 = $sw.Elapsed.TotalSeconds
    $argList = @('-p', '--model', $Model, '--effort', $Effort, '--output-format', 'json', '--safe-mode', '--tools', '', '--system-prompt-file', $rulesFile)
    $r = Invoke-ClaudeCli -ClaudePath $ClaudePath -Arguments $argList -WorkDir $WorkDir -Prompt $ask
    $secs = [Math]::Round($sw.Elapsed.TotalSeconds - $t0, 1)
    if ($r.is_error -or -not $r.result) {
        Write-Host "[$Label] attempt $a failed: $($r.result)" -ForegroundColor Yellow
        $attemptLog += [pscustomobject]@{ Attempt = $a; Seconds = $secs; Error = [string]$r.result }
        continue
    }
    $reply = ConvertFrom-SummaryReply ([string]$r.result)
    $missing = @(Test-Grounded ($reply.Title + "`n" + $reply.Body) $source)
    $lost = @(Test-Coverage ($reply.Title + "`n" + $reply.Body) $keyFacts)
    $meta = @(Test-SourceMentions $reply.Body)
    $score = $missing.Count + $lost.Count + $meta.Count
    $cost = if ($r.PSObject.Properties['total_cost_usd']) { [double]$r.total_cost_usd } else { $null }
    $models = if ($r.PSObject.Properties['modelUsage']) { ($r.modelUsage.PSObject.Properties.Name -join ', ') } else { '' }
    $attemptLog += [pscustomobject]@{ Attempt = $a; Seconds = $secs; CostUsd = $cost; Models = $models; Score = $score; Missing = $missing; Lost = $lost; Meta = $meta }
    Write-Host "[$Label] attempt $a : $secs s, cost $cost, not in record: $($missing -join ', '); left out: $($lost -join '; '); sources: $($meta -join ', ')" -ForegroundColor Cyan
    if (-not $best -or $score -lt $best.Score) { $best = [pscustomobject]@{ Title = $reply.Title; Body = $reply.Body; Score = $score; Missing = $missing; Lost = $lost; Meta = $meta } }
    if ($score -eq 0) { break }
    $fix = @()
    if ($meta.Count -gt 0) { $fix += 'Your previous reply talked about its sources (' + ($meta -join ', ') + '). Write only about the events, as a novel.' }
    if ($missing.Count -gt 0) { $fix += 'Your previous reply named things the record does not hold: ' + ($missing -join ', ') + '. Use only what the record holds.' }
    if ($lost.Count -gt 0) { $fix += 'Your previous reply left out these events, which must be in the account: ' + ($lost -join '; ') + '.' }
    $ask = $prompt + "`n`n# Correction`n" + ($fix -join "`n") + "`nWrite the account again."
}
$summary = [pscustomobject]@{
    Label = $Label; Model = $Model; Effort = $Effort; Character = $Character; Session = $Session
    PromptChars = $prompt.Length; RecordLines = $lines.Count; TotalSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    Attempts = $attemptLog; Words = $(if ($best) { ($best.Body -split '\s+').Count } else { 0 })
    Title = $(if ($best) { $best.Title } else { '' })
}
[IO.File]::WriteAllText((Join-Path $OutDir "$Label.json"), ($summary | ConvertTo-Json -Depth 6), $Utf8)
if ($best) { [IO.File]::WriteAllText((Join-Path $OutDir "$Label.md"), "# $($best.Title)`n`n$($best.Body)`n", $Utf8) }
Write-Host "[$Label] done in $($summary.TotalSeconds) s, $($summary.Words) words." -ForegroundColor Green
