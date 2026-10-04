#Requires -RunAsAdministrator
param([Parameter(Mandatory=$true)][string]$ConfigDir)
$ErrorActionPreference = 'Stop'
function Check-Native { if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE)" } }
$Python = (Get-Command python.exe -ErrorAction Stop).Source
# A SYSTEM task must never execute a Python interpreter writable by ordinary users.
if (-not $Python.StartsWith($env:ProgramFiles + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Install 64-bit Python 3.11+ for all users under Program Files, add it to PATH, then reopen Administrator PowerShell.'
}
$Root = Join-Path $env:ProgramData 'PowerBridge'
if (Test-Path $Root) { throw 'Already installed. See README for update/uninstall instructions.' }
$Source = Join-Path $PSScriptRoot '..\companion'
$ConfigDir = (Resolve-Path $ConfigDir).Path
foreach ($Name in @('config.json','cert.pem','key.pem')) {
    if (-not (Test-Path (Join-Path $ConfigDir $Name))) { throw "Missing $Name" }
}
New-Item -ItemType Directory $Root | Out-Null
& icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
Check-Native
foreach ($Name in @('server.py','platform_ops.py')) { Copy-Item (Join-Path $Source $Name) $Root }
foreach ($Name in @('config.json','cert.pem','key.pem')) { Copy-Item (Join-Path $ConfigDir $Name) $Root }
$Arguments = '"' + (Join-Path $Root 'server.py') + '" --config "' + (Join-Path $Root 'config.json') + '"'
$Action = New-ScheduledTaskAction -Execute $Python -Argument $Arguments -WorkingDirectory $Root
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'PowerBridge' -Action $Action -Trigger $Trigger -Settings $Settings -User 'SYSTEM' -RunLevel Highest | Out-Null
$Config = Get-Content (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
New-NetFirewallRule -DisplayName 'PowerBridge LAN' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Config.port -RemoteAddress LocalSubnet -Profile Private | Out-Null
Start-ScheduledTask -TaskName 'PowerBridge'
Write-Host 'Installed. Private LAN firewall access enabled. Revoke copies of pairing.json when no longer needed.'
