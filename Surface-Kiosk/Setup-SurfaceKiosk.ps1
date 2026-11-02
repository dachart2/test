<#
.SYNOPSIS
    Turns a Surface (Windows 11 Pro, also ARM64/Snapdragon) into a browsing-only
    device: removes bloatware, disables consumer/AI/ad features and configures
    a single-app kiosk (Assigned Access) running Microsoft Edge.

.DESCRIPTION
    Steps (each can be skipped):
      1. Debloat   - removes preinstalled Store apps for all users AND from the
                     provisioning image, so new accounts (incl. the kiosk
                     account) do not get them again.
      2. Policies  - machine-wide policies: no consumer features/ads/tips,
                     no Copilot, no Recall / Click to Do (Copilot+ PC),
                     no widgets, no web search in Start, no OneDrive,
                     minimal Edge noise.
      3. Kiosk     - Assigned Access single-app kiosk with Edge. Windows
                     creates and auto-logs-on a dedicated local kiosk account
                     (no password, no admin rights). Your existing admin
                     account stays untouched.

    NOT touched on purpose: Windows Update, Microsoft Defender, firewall,
    drivers/firmware, Surface app, Microsoft Store (needed for app/framework
    updates), Edge itself.

    Must be run from an elevated PowerShell (Run as administrator) while
    logged on with the admin account. A reboot is required afterwards.

.PARAMETER StartUrl
    Page Edge opens in the kiosk.

.PARAMETER KioskType
    PublicBrowsing : Edge with address bar and tabs, InPrivate only. All data
                     (history, cookies, logins) is wiped on idle reset and on
                     sign-out. Good for "just surf".
    Fullscreen     : Digital-signage style, no address bar. Only useful if a
                     single web page should be shown.

.PARAMETER IdleResetMinutes
    Minutes of inactivity after which Edge resets the session (closes all
    tabs, wipes data, returns to StartUrl). 0 disables the reset
    (Edge itself would default to 5 minutes).

.PARAMETER KioskDisplayName
    Display name of the auto-created kiosk account on the sign-in screen.

.PARAMETER SkipDebloat
.PARAMETER SkipPolicies
.PARAMETER SkipKiosk
    Skip the respective step.

.PARAMETER WhatIf
    Show what would be done without changing anything.

.EXAMPLE
    .\Setup-SurfaceKiosk.ps1
    Full setup with defaults (account "Haustechnik", start page http://test.at,
    public browsing, reset after 15 minutes idle).

.EXAMPLE
    .\Setup-SurfaceKiosk.ps1 -StartUrl "https://www.startpage.com" -IdleResetMinutes 0

.EXAMPLE
    .\Setup-SurfaceKiosk.ps1 -SkipKiosk -WhatIf
    Only preview debloat + policies.

.NOTES
    Log file: C:\ProgramData\SurfaceKiosk\setup.log
    Undo kiosk: Remove-SurfaceKiosk.ps1 (removed apps can be reinstalled from
    the Microsoft Store).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$StartUrl = 'http://test.at',

    [ValidateSet('PublicBrowsing', 'Fullscreen')]
    [string]$KioskType = 'PublicBrowsing',

    [ValidateRange(0, 1440)]
    [int]$IdleResetMinutes = 15,

    [string]$KioskDisplayName = 'Haustechnik',

    [switch]$SkipDebloat,
    [switch]$SkipPolicies,
    [switch]$SkipKiosk
)

$ErrorActionPreference = 'Stop'
$WorkDir = Join-Path $env:ProgramData 'SurfaceKiosk'

# ---------------------------------------------------------------------------
# Apps to remove (wildcards allowed). Deliberately a removal list, not an
# allow list: anything unknown (drivers, Surface/Qualcomm components,
# frameworks) is left alone.
# ---------------------------------------------------------------------------
$AppsToRemove = @(
    # News / weather / search / tips
    'Microsoft.BingNews'
    'Microsoft.BingWeather'
    'Microsoft.BingSearch'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.WindowsFeedbackHub'
    'MicrosoftWindows.Client.WebExperience'   # Widgets
    'Microsoft.StartExperiencesApp'

    # AI / Copilot
    'Microsoft.Copilot'
    'Microsoft.Windows.Ai.Copilot.Provider'
    'Microsoft.549981C3F5F10'                 # Cortana

    # Office / communication / cloud promos
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.OutlookForWindows'
    'microsoft.windowscommunicationsapps'     # old Mail & Calendar
    'Microsoft.People'
    'Microsoft.Todos'
    'Microsoft.Office.OneNote'
    'Microsoft.SkypeApp'
    'MicrosoftTeams'
    'MSTeams'
    'Microsoft.YourPhone'                     # Phone Link
    'MicrosoftWindows.CrossDevice'
    'Microsoft.PowerAutomateDesktop'
    'Microsoft.Windows.DevHome'
    'Clipchamp.Clipchamp'

    # Media / games
    'Microsoft.ZuneMusic'
    'Microsoft.ZuneVideo'
    'Microsoft.GamingApp'
    'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.Xbox.TCUI'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MixedReality.Portal'

    # Misc
    'Microsoft.WindowsMaps'
    'Microsoft.WindowsAlarms'
    'Microsoft.WindowsSoundRecorder'
    'Microsoft.MicrosoftStickyNotes'
    'Microsoft.Wallet'

    # Third-party promos (only present if already installed)
    '*SpotifyMusic*'
    '*Disney*'
    '*LinkedInforWindows*'
    '*TikTok*'
    '*Instagram*'
    '*Facebook*'
    '*CandyCrush*'
)

# Safety net: never remove these, even if a pattern above would match.
$ProtectedApps = @(
    'Microsoft.MicrosoftEdge*'
    'Microsoft.WindowsStore'
    'Microsoft.StorePurchaseApp'
    'Microsoft.DesktopAppInstaller'           # winget
    'Microsoft.SecHealthUI'                   # Defender UI
    'Microsoft.VCLibs*'
    'Microsoft.UI.Xaml*'
    'Microsoft.NET.*'
    'Microsoft.WindowsAppRuntime*'
    'Microsoft.SurfaceHub'                    # Surface app
    '*Qualcomm*'
    'Microsoft.Windows.ShellExperienceHost'
    'Microsoft.Windows.StartMenuExperienceHost'
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Test-Protected([string]$Name) {
    foreach ($p in $ProtectedApps) { if ($Name -like $p) { return $true } }
    return $false
}

function Set-RegValue {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] $Value,
        [ValidateSet('DWord', 'String')] [string]$Type = 'DWord'
    )
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set to $Value")) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Host "  [reg] $Path\$Name = $Value"
    }
}

function Get-EdgePath {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Please run this script in an elevated PowerShell (Run as administrator).'
    exit 1
}

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
Write-Host "OS:    $($os.Caption) (build $build, $env:PROCESSOR_ARCHITECTURE)"
if ($build -lt 22000) {
    Write-Error 'This script is meant for Windows 11.'
    exit 1
}
if (-not $SkipKiosk -and $os.Caption -notmatch 'Pro|Enterprise|Education') {
    Write-Error 'Assigned Access (kiosk) requires Windows 11 Pro, Enterprise or Education. Use -SkipKiosk to only debloat.'
    exit 1
}

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
Start-Transcript -Path (Join-Path $WorkDir 'setup.log') -Append | Out-Null

try {
    # -----------------------------------------------------------------------
    # 1. Debloat
    # -----------------------------------------------------------------------
    if (-not $SkipDebloat) {
        Write-Step 'Removing preinstalled apps'

        $installed   = Get-AppxPackage -AllUsers
        $provisioned = Get-AppxProvisionedPackage -Online

        foreach ($pattern in $AppsToRemove) {
            foreach ($pkg in ($installed | Where-Object { $_.Name -like $pattern })) {
                if (Test-Protected $pkg.Name) { continue }
                if ($PSCmdlet.ShouldProcess($pkg.PackageFullName, 'Remove-AppxPackage -AllUsers')) {
                    try {
                        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                        Write-Host "  [app] removed   $($pkg.Name)"
                    } catch {
                        Write-Warning "  could not remove $($pkg.Name): $($_.Exception.Message)"
                    }
                }
            }
            foreach ($prov in ($provisioned | Where-Object { $_.DisplayName -like $pattern })) {
                if (Test-Protected $prov.DisplayName) { continue }
                if ($PSCmdlet.ShouldProcess($prov.PackageName, 'Remove-AppxProvisionedPackage')) {
                    try {
                        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                        Write-Host "  [app] deprovisioned $($prov.DisplayName)"
                    } catch {
                        Write-Warning "  could not deprovision $($prov.DisplayName): $($_.Exception.Message)"
                    }
                }
            }
        }

        # Recall (only exists on Copilot+ PCs such as Snapdragon X Surfaces)
        Write-Step 'Disabling Recall (if present)'
        try {
            $recall = Get-WindowsOptionalFeature -Online -FeatureName 'Recall' -ErrorAction Stop
            if ($recall.State -ne 'Disabled' -and $recall.State -ne 'DisabledWithPayloadRemoved') {
                if ($PSCmdlet.ShouldProcess('Recall', 'Disable-WindowsOptionalFeature')) {
                    Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -NoRestart -ErrorAction Stop | Out-Null
                    Write-Host '  Recall disabled (reboot required).'
                }
            } else {
                Write-Host '  Recall already disabled.'
            }
        } catch {
            Write-Host '  Recall feature not present on this device.'
        }

        # OneDrive (per-user install in Windows 11) - policy below blocks it anyway
        Write-Step 'Uninstalling OneDrive (current admin user)'
        $oneDriveSetup = @(
            "$env:SystemRoot\System32\OneDriveSetup.exe",
            "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($oneDriveSetup) {
            if ($PSCmdlet.ShouldProcess('OneDrive', 'Uninstall')) {
                Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Process -FilePath $oneDriveSetup -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue
                Write-Host '  OneDrive uninstall started.'
            }
        } else {
            Write-Host '  OneDriveSetup.exe not found - skipping (policy will still block OneDrive).'
        }
    }

    # -----------------------------------------------------------------------
    # 2. Policies (machine-wide, apply to every account incl. kiosk)
    # -----------------------------------------------------------------------
    if (-not $SkipPolicies) {
        Write-Step 'Setting policies'
        $pol = 'HKLM:\SOFTWARE\Policies\Microsoft'

        # Consumer features, suggested apps, tips, ads
        Set-RegValue "$pol\Windows\CloudContent" 'DisableWindowsConsumerFeatures' 1
        Set-RegValue "$pol\Windows\CloudContent" 'DisableConsumerAccountStateContent' 1
        Set-RegValue "$pol\Windows\CloudContent" 'DisableSoftLanding' 1
        Set-RegValue "$pol\Windows\CloudContent" 'DisableCloudOptimizedContent' 1
        Set-RegValue "$pol\Windows\AdvertisingInfo" 'DisabledByGroupPolicy' 1

        # Telemetry: 1 = "Required" (lowest level honoured by Pro)
        Set-RegValue "$pol\Windows\DataCollection" 'AllowTelemetry' 1
        Set-RegValue "$pol\Windows\DataCollection" 'DoNotShowFeedbackNotifications' 1

        # Copilot, Recall, Click to Do
        Set-RegValue "$pol\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1
        Set-RegValue "$pol\Windows\WindowsAI" 'AllowRecallEnablement' 0
        Set-RegValue "$pol\Windows\WindowsAI" 'DisableAIDataAnalysis' 1
        Set-RegValue "$pol\Windows\WindowsAI" 'DisableClickToDo' 1

        # Widgets, web results in Start search, Cortana
        Set-RegValue "$pol\Dsh" 'AllowNewsAndInterests' 0
        Set-RegValue "$pol\Windows\Windows Search" 'AllowCortana' 0
        Set-RegValue "$pol\Windows\Windows Search" 'DisableWebSearch' 1
        Set-RegValue "$pol\Windows\Windows Search" 'ConnectedSearchUseWeb' 0
        Set-RegValue "$pol\Windows\Explorer" 'DisableSearchBoxSuggestions' 1

        # OneDrive, Game DVR
        Set-RegValue "$pol\Windows\OneDrive" 'DisableFileSyncNGSC' 1
        Set-RegValue "$pol\Windows\GameDVR" 'AllowGameDVR' 0

        # Edge: no first-run wizard, no shopping/sidebar/recommendation noise
        $edge = "$pol\Edge"
        Set-RegValue $edge 'HideFirstRunExperience' 1
        Set-RegValue $edge 'EdgeShoppingAssistantEnabled' 0
        Set-RegValue $edge 'HubsSidebarEnabled' 0
        Set-RegValue $edge 'ShowRecommendationsEnabled' 0
        Set-RegValue $edge 'SpotlightExperiencesAndRecommendationsEnabled' 0
        Set-RegValue $edge 'PersonalizationReportingEnabled' 0
        Set-RegValue $edge 'EdgeCollectionsEnabled' 0
        Set-RegValue $edge 'ShowMicrosoftRewards' 0
        Set-RegValue $edge 'NewTabPageContentEnabled' 0
        Set-RegValue $edge 'NewTabPageQuickLinksEnabled' 0
        Set-RegValue $edge 'NewTabPageHideDefaultTopSites' 1
        Set-RegValue $edge 'DiagnosticData' 0
    }

    # -----------------------------------------------------------------------
    # 3. Kiosk (Assigned Access, single-app Edge)
    # -----------------------------------------------------------------------
    if (-not $SkipKiosk) {
        Write-Step 'Configuring Edge kiosk (Assigned Access)'

        $edgePath = Get-EdgePath
        if (-not $edgePath) { throw 'msedge.exe not found. Edge is required for the kiosk.' }
        Write-Host "  Edge: $edgePath"

        $edgeType = if ($KioskType -eq 'PublicBrowsing') { 'public-browsing' } else { 'fullscreen' }
        # Always pass the timeout: Edge's own default is 5 minutes, 0 = never reset
        $edgeArgs = "--kiosk $StartUrl --edge-kiosk-type=$edgeType --kiosk-idle-timeout-minutes=$IdleResetMinutes --no-first-run"

        $profileId = '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
        $esc = [System.Security.SecurityElement]

        $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<AssignedAccessConfiguration
    xmlns="http://schemas.microsoft.com/AssignedAccess/2017/config"
    xmlns:rs5="http://schemas.microsoft.com/AssignedAccess/201810/config"
    xmlns:v4="http://schemas.microsoft.com/AssignedAccess/2021/config">
  <Profiles>
    <Profile Id="$profileId">
      <KioskModeApp v4:ClassicAppPath="$($esc::Escape($edgePath))" v4:ClassicAppArguments="$($esc::Escape($edgeArgs))" />
    </Profile>
  </Profiles>
  <Configs>
    <Config>
      <AutoLogonAccount rs5:DisplayName="$($esc::Escape($KioskDisplayName))" />
      <DefaultProfile Id="$profileId" />
    </Config>
  </Configs>
</AssignedAccessConfiguration>
"@
        $xmlPath = Join-Path $WorkDir 'AssignedAccess.xml'
        [System.IO.File]::WriteAllText($xmlPath, $xml, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  Config written to $xmlPath"

        # The MDM bridge (MDM_AssignedAccess) only accepts calls from SYSTEM,
        # so the actual apply runs in a one-shot scheduled task as SYSTEM.
        $applyScript = Join-Path $WorkDir 'Apply-AssignedAccess.ps1'
        $resultFile  = Join-Path $WorkDir 'apply-result.txt'
        $applyCode = @'
param([string]$XmlPath, [string]$ResultFile)
try {
    $xml = [System.IO.File]::ReadAllText($XmlPath)
    $obj = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_AssignedAccess' -ErrorAction Stop
    $obj.Configuration = [System.Net.WebUtility]::HtmlEncode($xml)
    Set-CimInstance -CimInstance $obj -ErrorAction Stop
    'OK' | Set-Content -Path $ResultFile -Encoding ASCII
} catch {
    ('ERROR: ' + $_.Exception.Message) | Set-Content -Path $ResultFile -Encoding ASCII
}
'@
        Set-Content -Path $applyScript -Value $applyCode -Encoding ASCII

        if ($PSCmdlet.ShouldProcess('MDM_AssignedAccess', 'Apply kiosk configuration as SYSTEM')) {
            Remove-Item $resultFile -ErrorAction SilentlyContinue
            $taskName = 'SurfaceKiosk-ApplyAssignedAccess'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$applyScript`" -XmlPath `"$xmlPath`" -ResultFile `"$resultFile`""
            $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $taskName -Action $action -Principal $taskPrincipal -Force | Out-Null
            try {
                Start-ScheduledTask -TaskName $taskName
                $deadline = (Get-Date).AddMinutes(3)
                while (-not (Test-Path $resultFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            } finally {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            }

            if (-not (Test-Path $resultFile)) { throw 'Applying the kiosk configuration timed out.' }
            $result = (Get-Content $resultFile -Raw).Trim()
            if ($result -ne 'OK') { throw "Applying the kiosk configuration failed: $result" }
            Write-Host "  Kiosk configured. Account '$KioskDisplayName' will sign in automatically." -ForegroundColor Green
        }
    }

    Write-Step 'Done'
    Write-Host 'Please REBOOT the Surface now.' -ForegroundColor Yellow
    if (-not $SkipKiosk) {
        Write-Host 'To reach the admin account later: press Ctrl+Alt+Del in the kiosk,'
        Write-Host 'choose "Sign out", then hold SHIFT while the sign-in screen appears'
        Write-Host '(this skips the automatic kiosk logon) and pick your admin account.'
    }
}
catch {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
