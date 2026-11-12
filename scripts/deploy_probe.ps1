# Copies the throwaway JourneyProbe add-on into the game, or removes it again with -Remove.
# Usage: powershell -File scripts\deploy_probe.ps1 [-Remove] [-AddOns "E:\World of Warcraft\_forever_\Interface\AddOns"]
param(
    [string]$AddOns = "E:\World of Warcraft\_forever_\Interface\AddOns",
    [switch]$Remove
)
$target = Join-Path $AddOns "JourneyProbe"
if ($Remove) {
    if (Test-Path $target) { Remove-Item -Recurse -Force $target; "Removed $target" } else { "Nothing to remove at $target" }
    return
}
$source = Join-Path $PSScriptRoot "..\src\JourneyProbe"
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item -Force (Join-Path $source "*") $target
"Copied the probe to $target. Start the game, or /reload if it is already running."
