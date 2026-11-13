# Claude Code PostToolUse hook: after an edit to a file under src\JourneyMaster, copies the add-on into the game
# (scripts\deploy_addon.ps1, which never overwrites the app's JournalSnapshot.lua there).
# It reads the hook's JSON from standard input and does nothing for edits elsewhere. The Phase 0 probe is no longer
# deployed: it was removed from the game when Phase 0 closed.
$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
$path = $payload.tool_input.file_path
if (-not $path) { exit 0 }
if ($path -notmatch '[\\/]src[\\/]JourneyMaster[\\/]') { exit 0 }
& (Join-Path $PSScriptRoot "..\deploy_addon.ps1") | Out-Null
exit 0
