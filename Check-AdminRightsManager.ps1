<#
.SYNOPSIS
    Prüft, ob die Gruppe "dlg_workstations-lohr" Mitglied der lokalen
    Administratoren-Gruppe ist, und ermittelt die installierte Version von
    "C-APP-AdminRightsManager-ENG".

.DESCRIPTION
    - Die lokale Administratoren-Gruppe wird über die SID S-1-5-32-544
      gesucht, funktioniert also auf deutschen ("Administratoren") und
      englischen ("Administrators") Systemen.
    - Die Version wird aus der Registry (Uninstall-Schlüssel, 64- und 32-Bit)
      gelesen. Steht die Version im Anzeigenamen, z. B.
      "C-APP-AdminRightsManager-ENG (BRVZ-version : 03.02)", wird sie daraus
      extrahiert, sonst wird DisplayVersion verwendet.
    - Falls nichts in der Registry steht, wird zusätzlich im
      ConfigMgr-/Softwarecenter-Client (WMI root\ccm\ClientSDK) gesucht.

.PARAMETER ComputerName
    Ein oder mehrere Rechner. Standard: der lokale Rechner.
    Für Remote-Rechner muss WinRM (PowerShell Remoting) aktiv sein.

.PARAMETER ComputerListFile
    Textdatei mit einem Rechnernamen pro Zeile.

.PARAMETER CsvPath
    Optional: Ergebnis zusätzlich als CSV speichern.

.EXAMPLE
    .\Check-AdminRightsManager.ps1

.EXAMPLE
    .\Check-AdminRightsManager.ps1 -ComputerListFile .\pcs.txt -CsvPath .\ergebnis.csv
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$ComputerListFile,
    [string]$CsvPath,
    [string]$GroupName = 'dlg_workstations-lohr',
    [string]$AppPattern = '*AdminRightsManager*'
)

$checkBlock = {
    param($GroupName, $AppPattern)

    # --- 1. Lokale Administratoren-Gruppe -----------------------------------
    $adminSid   = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $adminGroup = $adminSid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]

    # ADSI statt Get-LocalGroupMember, da letzteres bei verwaisten SIDs
    # bzw. Azure-AD-Mitgliedern mit einem Fehler abbricht.
    $members = @()
    try {
        $group = [ADSI]"WinNT://$env:COMPUTERNAME/$adminGroup,group"
        foreach ($m in $group.psbase.Invoke('Members')) {
            $path = $m.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $m, $null)
            # WinNT://DOMAIN/Name  bzw.  WinNT://DOMAIN/PC/Name
            $members += ($path -replace '^WinNT://', '' -replace '/', '\')
        }
        $groupError = $null
    } catch {
        $groupError = $_.Exception.Message
    }

    $found = $members | Where-Object { $_.Split('\')[-1] -ieq $GroupName }

    # --- 2. Programmversion ---------------------------------------------------
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = Get-ItemProperty -Path $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $AppPattern }

    $source = 'Registry'
    if (-not $apps) {
        # Fallback: Softwarecenter / ConfigMgr-Client
        try {
            $apps = Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' -ErrorAction Stop |
                Where-Object { $_.FullName -like $AppPattern -or $_.Name -like $AppPattern } |
                Select-Object @{n = 'DisplayName';    e = { if ($_.FullName) { $_.FullName } else { $_.Name } } },
                              @{n = 'DisplayVersion'; e = { $_.SoftwareVersion } },
                              @{n = 'Installed';      e = { $_.InstallState } }
            $source = 'Softwarecenter'
        } catch { $apps = $null }
    }

    $appName = $null; $appVersion = $null
    if ($apps) {
        $app     = @($apps)[0]
        $appName = $app.DisplayName
        if ($appName -match 'version\s*:\s*([\d\.]+)') {
            $appVersion = $Matches[1]
        } else {
            $appVersion = $app.DisplayVersion
        }
        if ($source -eq 'Softwarecenter' -and $app.Installed -and $app.Installed -ne 'Installed') {
            $appVersion = "$appVersion (Status: $($app.Installed))"
        }
    }

    [pscustomobject]@{
        Computer          = $env:COMPUTERNAME
        AdminGruppe       = $adminGroup
        GruppeEnthalten   = [bool]$found
        GefundenAls       = ($found -join '; ')
        Fehler            = $groupError
        Programm          = $appName
        Version           = $appVersion
        Quelle            = if ($apps) { $source } else { $null }
    }
}

if ($ComputerListFile) {
    $ComputerName = Get-Content $ComputerListFile | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }
}

$results = foreach ($pc in $ComputerName) {
    try {
        if ($pc -ieq $env:COMPUTERNAME -or $pc -in @('localhost', '.')) {
            & $checkBlock $GroupName $AppPattern
        } else {
            Invoke-Command -ComputerName $pc -ScriptBlock $checkBlock -ArgumentList $GroupName, $AppPattern -ErrorAction Stop |
                Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName
        }
    } catch {
        [pscustomobject]@{
            Computer = $pc; AdminGruppe = $null; GruppeEnthalten = $null; GefundenAls = $null
            Fehler = $_.Exception.Message; Programm = $null; Version = $null; Quelle = $null
        }
    }
}

$results | Format-List

if ($CsvPath) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Delimiter ';' -Encoding UTF8
    Write-Host "Ergebnis gespeichert: $CsvPath"
}
