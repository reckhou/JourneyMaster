# A stand-in for the claude command in offline tests. Reads the prompt on standard input and replies in claude's JSON
# output form. The account is made only of words from the prompt's record, so it is grounded.
# FAKE_CLAUDE_LOG: a folder; each call's arguments and prompt are saved there as call-<n>.txt.
# FAKE_CLAUDE_INVENT=1: the first reply of each prompt (one without a "# Correction" section) names an invented person.
# Kept ASCII-only.
$utf8 = New-Object Text.UTF8Encoding $false
$stdin = New-Object IO.StreamReader([Console]::OpenStandardInput(), $utf8)
$prompt = $stdin.ReadToEnd()
if ($env:FAKE_CLAUDE_LOG) {
    if (-not (Test-Path $env:FAKE_CLAUDE_LOG)) { New-Item -ItemType Directory -Force $env:FAKE_CLAUDE_LOG | Out-Null }
    $n = @(Get-ChildItem $env:FAKE_CLAUDE_LOG -Filter 'call-*.txt').Count + 1
    [IO.File]::WriteAllText((Join-Path $env:FAKE_CLAUDE_LOG "call-$n.txt"), (($args -join ' ') + "`n----`n" + $prompt), $utf8)
}
$isOverview = $prompt -match '(?m)^# Entries|^# New entries'
$lines = @()
$inRecord = $false
foreach ($l in ($prompt -replace "`r", '') -split "`n") {
    if ($l -match '^# Record' -or $l -match '^# Entries' -or $l -match '^# New entries') { $inRecord = $true; continue }
    if ($l -match '^# Correction') { break }
    if ($inRecord -and $l.Trim() -and $l -notmatch '^#') { $lines += ($l -replace '^\d\d:\d\d ', '') }
}
$body = ($lines | Select-Object -First 6) -join ' '
if ($env:FAKE_CLAUDE_INVENT -eq '1' -and $prompt -notmatch '# Correction') { $body += ' Zanzibar Quillfeather watched.' }
if ($isOverview) { $text = $body } else { $text = "TITLE: Session record`n`n$body" }
$result = @{ type = 'result'; is_error = $false; result = $text; total_cost_usd = 0 } | ConvertTo-Json -Compress
$bytes = $utf8.GetBytes($result)
$out = [Console]::OpenStandardOutput()
$out.Write($bytes, 0, $bytes.Length)
$out.Flush()
