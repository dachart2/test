<#
.SYNOPSIS
    Removes the Assigned Access (kiosk) configuration created by
    Setup-SurfaceKiosk.ps1. The device then boots to the normal sign-in screen.

.DESCRIPTION
    Clears MDM_AssignedAccess (runs as SYSTEM via a one-shot scheduled task).
    Windows removes the auto-created kiosk account itself.
    Policies and removed apps are NOT restored; removed apps can be
    reinstalled from the Microsoft Store, policies live under
    HKLM:\SOFTWARE\Policies\Microsoft.

    Run from an elevated PowerShell, then reboot.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Please run this script in an elevated PowerShell (Run as administrator).'
    exit 1
}

$WorkDir = Join-Path $env:ProgramData 'SurfaceKiosk'
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

$clearScript = Join-Path $WorkDir 'Clear-AssignedAccess.ps1'
$resultFile  = Join-Path $WorkDir 'clear-result.txt'
$clearCode = @'
param([string]$ResultFile)
try {
    $obj = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_AssignedAccess' -ErrorAction Stop
    $obj.Configuration = $null
    Set-CimInstance -CimInstance $obj -ErrorAction Stop
    'OK' | Set-Content -Path $ResultFile -Encoding ASCII
} catch {
    ('ERROR: ' + $_.Exception.Message) | Set-Content -Path $ResultFile -Encoding ASCII
}
'@
Set-Content -Path $clearScript -Value $clearCode -Encoding ASCII

if (-not $PSCmdlet.ShouldProcess('MDM_AssignedAccess', 'Clear kiosk configuration as SYSTEM')) { exit 0 }

Remove-Item $resultFile -ErrorAction SilentlyContinue
$taskName = 'SurfaceKiosk-ClearAssignedAccess'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$clearScript`" -ResultFile `"$resultFile`""
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $taskPrincipal -Force | Out-Null
try {
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-Path $resultFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
} finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

if (-not (Test-Path $resultFile)) { Write-Error 'Timed out.'; exit 1 }
$result = (Get-Content $resultFile -Raw).Trim()
if ($result -ne 'OK') { Write-Error "Failed: $result"; exit 1 }

Write-Host 'Kiosk configuration removed. Please reboot.' -ForegroundColor Green
