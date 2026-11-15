<#
Shows Claude's output live, in its own console window: follows a text file and writes what is added to it, part
lines included (Get-Content -Wait shows only whole lines). JourneyMaster.ps1 opens this window when it asks the AI for
a summary or an overview. The window closes itself when the app that opened it stops.
Kept ASCII-only: Windows PowerShell 5.1 reads a script without a byte-order mark as ANSI.
#>
param(
    [Parameter(Mandatory)][string]$Path,
    [int]$ParentId = 0
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
try { $Host.UI.RawUI.WindowTitle = 'JourneyMaster - Claude output' } catch { }
Write-Host "Claude's output while JourneyMaster summarises. Each call is also saved in $(Split-Path -Parent $Path)." -ForegroundColor DarkGray
while (-not (Test-Path -LiteralPath $Path)) { Start-Sleep -Milliseconds 300 }
$fs = New-Object IO.FileStream($Path, 'Open', 'Read', 'ReadWrite, Delete')
$reader = New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding $false))
$buf = New-Object char[] 4096
try {
    while ($true) {
        $n = $reader.Read($buf, 0, $buf.Length)
        if ($n -gt 0) { [Console]::Write((New-Object string($buf, 0, $n))); continue }
        if ($ParentId -gt 0 -and -not (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 200
    }
} finally {
    $reader.Dispose()
}
