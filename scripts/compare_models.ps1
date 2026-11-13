<#
.SYNOPSIS
Summarises one real session with one AI model and effort, using the app's own prompt, and saves the result for comparison.

.DESCRIPTION
Reads the permanent record of a character (data\journeys\<character>\events), builds the record, the narrator rules and the
prompt exactly as the app does and calls the claude command once with the given model and effort. It writes
<OutDir>\<Label>.json (timing, cost, word count) and <Label>.md (the title and the account). It never changes the real journal, state or session files.
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
    [string]$ClaudePath
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
$prompt = New-SummaryPrompt $header $lines $lore
$rulesFile = Join-Path $WorkDir 'rules.md'
[IO.File]::WriteAllText($rulesFile, $rules, $Utf8)

$sw = [Diagnostics.Stopwatch]::StartNew()
$argList = @('-p', '--model', $Model, '--effort', $Effort, '--output-format', 'json', '--safe-mode', '--tools', '', '--system-prompt-file', $rulesFile)
$r = Invoke-ClaudeCli -ClaudePath $ClaudePath -Arguments $argList -WorkDir $WorkDir -Prompt $prompt
$secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
$reply = $null
if ($r.is_error -or -not $r.result) {
    Write-Host "[$Label] the AI call failed: $($r.result)" -ForegroundColor Yellow
} else {
    $reply = ConvertFrom-SummaryReply ([string]$r.result)
}
$cost = if ($r.PSObject.Properties['total_cost_usd']) { [double]$r.total_cost_usd } else { $null }
$models = if ($r.PSObject.Properties['modelUsage']) { ($r.modelUsage.PSObject.Properties.Name -join ', ') } else { '' }
$summary = [pscustomobject]@{
    Label = $Label; Model = $Model; Effort = $Effort; Character = $Character; Session = $Session
    PromptChars = $prompt.Length; RecordLines = $lines.Count; Seconds = $secs; CostUsd = $cost; Models = $models
    Words = $(if ($reply) { ($reply.Body -split '\s+').Count } else { 0 })
    Title = $(if ($reply) { $reply.Title } else { '' })
}
[IO.File]::WriteAllText((Join-Path $OutDir "$Label.json"), ($summary | ConvertTo-Json -Depth 6), $Utf8)
if ($reply) { [IO.File]::WriteAllText((Join-Path $OutDir "$Label.md"), "# $($reply.Title)`n`n$($reply.Body)`n", $Utf8) }
Write-Host "[$Label] done in $secs s, cost $cost, $($summary.Words) words." -ForegroundColor Green
