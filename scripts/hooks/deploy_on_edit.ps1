# Claude Code PostToolUse hook: after an edit to a file under src\JourneyProbe, copies the add-on into the game.
# It reads the hook's JSON from standard input and does nothing for edits elsewhere.
$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
$path = $payload.tool_input.file_path
if (-not $path) { exit 0 }
if ($path -notmatch '[\\/]src[\\/]JourneyProbe[\\/]') { exit 0 }
& (Join-Path $PSScriptRoot "..\deploy_probe.ps1")
exit 0
