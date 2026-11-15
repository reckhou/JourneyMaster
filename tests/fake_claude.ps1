# A stand-in for the claude command in offline tests. Reads the prompt on standard input and replies in claude's JSON
# output form (or its stream-json form, when asked). The account is made only of words from the prompt's record, so it
# is grounded.
# FAKE_CLAUDE_LOG: a folder; each call's arguments and prompt are saved there as call-<n>.txt.
# FAKE_CLAUDE_INVENT=1: the first reply of each prompt (one without a "# Correction" section) names an invented person.
# FAKE_CLAUDE_OVERVIEW_FAULT=1: the first reply to an overview prompt names an invented person; the reply to its
# correction does not.
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
    # An overview has a section for each entry, headed by the entry's title (without the line in brackets).
    if ($inRecord -and $isOverview -and $l -match '^## (.+?) \(.*\)$') { $lines += "SECTION:$($Matches[1])"; continue }
    if ($inRecord -and $l.Trim() -and $l -notmatch '^#') {
        $l = $l -replace '^\d\d:\d\d ', ''
        # A picture line becomes its marker, as the narrator rules ask.
        if ($l -match '^\[picture (\d+): ') { $l = "{{picture $($Matches[1])}}" }
        $lines += $l
    }
}
$body = ''
foreach ($l in $lines) {
    if ($l -match '^SECTION:(.*)$') { $body = $body.TrimEnd() + "`n`n## $($Matches[1])`n`n" } else { $body += $l + ' ' }
}
$body = $body.Trim()
if ($env:FAKE_CLAUDE_INVENT -eq '1' -and $prompt -notmatch '# Correction') { $body += ' Zanzibar Quillfeather watched.' }
# The record's own notes name the add-on and the chat log. A real overview must not talk about its sources, so the
# stand-in's overview does not carry those words over.
if ($isOverview) { $body = $body -replace 'the add-on', 'the game' -replace 'the chat log', 'the talk' }
if ($env:FAKE_CLAUDE_OVERVIEW_FAULT -eq '1' -and $isOverview -and $prompt -notmatch '# Correction') { $body += ' Mordecai Vandermeer watched.' }
if ($isOverview) { $text = $body } else { $text = "TITLE: Session record`n`n$body" }
$result = @{ type = 'result'; is_error = $false; result = $text; total_cost_usd = 0 } | ConvertTo-Json -Compress
# With --output-format stream-json the reply comes as events, one JSON object a line: the text in pieces, then the result.
if (($args -join ' ') -match 'stream-json') {
    $events = @(@{ type = 'system'; subtype = 'init' } | ConvertTo-Json -Compress)
    $events += @{ type = 'stream_event'; event = @{ type = 'content_block_start'; index = 0; content_block = @{ type = 'thinking'; thinking = '' } } } | ConvertTo-Json -Compress -Depth 5
    $events += @{ type = 'stream_event'; event = @{ type = 'content_block_delta'; index = 0; delta = @{ type = 'thinking_delta'; thinking = 'FAKE THINKING' } } } | ConvertTo-Json -Compress -Depth 5
    $events += @{ type = 'stream_event'; event = @{ type = 'content_block_start'; index = 1; content_block = @{ type = 'text'; text = '' } } } | ConvertTo-Json -Compress -Depth 5
    for ($i = 0; $i -lt $text.Length; $i += 40) {
        $piece = $text.Substring($i, [Math]::Min(40, $text.Length - $i))
        $events += @{ type = 'stream_event'; event = @{ type = 'content_block_delta'; index = 1; delta = @{ type = 'text_delta'; text = $piece } } } | ConvertTo-Json -Compress -Depth 5
    }
    $events += $result
    $result = ($events -join "`n") + "`n"
}
$bytes = $utf8.GetBytes($result)
$out = [Console]::OpenStandardOutput()
$out.Write($bytes, 0, $bytes.Length)
$out.Flush()
