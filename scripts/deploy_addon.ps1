# Copies the JourneyMaster add-on into the game, or removes it with -Remove.
# An installed JournalSnapshot.lua is the app's (it holds your summaries), so it is never overwritten.
# Usage: powershell -File scripts\deploy_addon.ps1 [-Remove] [-AddOns "E:\World of Warcraft\_forever_\Interface\AddOns"]
param(
    [string]$AddOns = "E:\World of Warcraft\_forever_\Interface\AddOns",
    [switch]$Remove
)
$target = Join-Path $AddOns "JourneyMaster"
if ($Remove) {
    if (Test-Path $target) { Remove-Item -Recurse -Force $target; "Removed $target" } else { "Nothing to remove at $target" }
    return
}
if (-not (Test-Path $AddOns)) { "No add-on folder at $AddOns"; return }
$source = Join-Path $PSScriptRoot "..\src\JourneyMaster"
New-Item -ItemType Directory -Force $target | Out-Null
foreach ($file in Get-ChildItem -File $source) {
    $dest = Join-Path $target $file.Name
    if ($file.Name -eq 'JournalSnapshot.lua' -and (Test-Path $dest)) { continue }
    Copy-Item -Force $file.FullName $dest
}
"Copied JourneyMaster to $target. /reload in game to load the change."
