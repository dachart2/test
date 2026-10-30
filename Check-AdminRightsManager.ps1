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

    $errors     = @()
    $adminGroup = $null
    $members    = @()

    # --- 1. Lokale Administratoren-Gruppe -----------------------------------
    try {
        $adminSid   = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544'
        $adminGroup = $adminSid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    } catch {
        $adminGroup = 'Administratoren'
        $errors += "SID-Aufloesung: $($_.Exception.Message)"
    }

    # ADSI statt Get-LocalGroupMember, da letzteres bei verwaisten SIDs
    # bzw. Azure-AD-Mitgliedern mit einem Fehler abbricht.
    try {
        $group = [ADSI]"WinNT://$env:COMPUTERNAME/$adminGroup,group"
        foreach ($m in @($group.psbase.Invoke('Members'))) {
            try {
                $path = $m.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $m, $null)
                # WinNT://DOMAIN/Name  bzw.  WinNT://DOMAIN/PC/Name
                $members += ($path -replace '^WinNT://', '' -replace '/', '\')
            } catch {
                $errors += "Mitglied: $($_.Exception.Message)"
            }
        }
    } catch {
        $errors += "Admin-Gruppe: $($_.Exception.Message)"
    }

    $found = $members | Where-Object { $_.Split('\')[-1] -ieq $GroupName }

    # --- 2. Programmversion ---------------------------------------------------
    # Registry direkt per .NET lesen: Get-ItemProperty bricht komplett ab
    # ("Die angegebene Umwandlung ist ungueltig"), sobald irgendein
    # Uninstall-Eintrag einen beschaedigten Wert enthaelt.
    $apps = @()
    foreach ($view in 'Registry64', 'Registry32') {
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
            $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $root) { continue }
            foreach ($subName in $root.GetSubKeyNames()) {
                try {
                    $sub  = $root.OpenSubKey($subName)
                    $name = [string]$sub.GetValue('DisplayName')
                    if ($name -like $AppPattern) {
                        $apps += [pscustomobject]@{
                            DisplayName    = $name
                            DisplayVersion = [string]$sub.GetValue('DisplayVersion')
                        }
                    }
                    $sub.Close()
                } catch { }   # einzelne kaputte Eintraege ignorieren
            }
            $root.Close(); $base.Close()
        } catch {
            $errors += "Registry ($view): $($_.Exception.Message)"
        }
    }

    $source = 'Registry'
    if (-not $apps) {
        # Fallback: Softwarecenter / ConfigMgr-Client
        try {
            $apps = @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' -ErrorAction Stop |
                Where-Object { $_.FullName -like $AppPattern -or $_.Name -like $AppPattern } |
                Select-Object @{n = 'DisplayName';    e = { if ($_.FullName) { $_.FullName } else { $_.Name } } },
                              @{n = 'DisplayVersion'; e = { $_.SoftwareVersion } },
                              @{n = 'Installed';      e = { $_.InstallState } })
            $source = 'Softwarecenter'
        } catch {
            $errors += "Softwarecenter: $($_.Exception.Message)"
        }
    }

    $appName = $null; $appVersion = $null
    if ($apps) {
        $app     = $apps[0]
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
        AlleMitglieder    = ($members -join '; ')
        Programm          = $appName
        Version           = $appVersion
        Quelle            = if ($apps) { $source } else { $null }
        Fehler            = ($errors -join ' | ')
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
            AlleMitglieder = $null; Programm = $null; Version = $null; Quelle = $null
            Fehler = "$($_.Exception.Message) [Zeile $($_.InvocationInfo.ScriptLineNumber)]"
        }
    }
}

$results | Format-List

if ($CsvPath) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Delimiter ';' -Encoding UTF8
    Write-Host "Ergebnis gespeichert: $CsvPath"
}
