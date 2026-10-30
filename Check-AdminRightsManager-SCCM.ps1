<#
.SYNOPSIS
    SCCM "Run Script" version: checks on the target device whether the group
    "dlg_workstations-lohr" is in the local Administrators group and lists the
    installed versions of "C-APP-AdminRightsManager-ENG".

.DESCRIPTION
    Intended for ConfigMgr: Software Library > Scripts > Create Script, then
    approve it and run it on a device via right-click > Run Script.
    The script runs locally on the device as SYSTEM, so no WinRM is needed.
    Output is plain text (Write-Output), which ConfigMgr shows in the
    "Script Status" / output window.

    Same check logic as Check-AdminRightsManager.ps1 - keep both in sync.
#>
param(
    [string]$GroupName  = 'dlg_workstations-lohr',
    [string]$AppPattern = '*AdminRightsManager*'
)

$checkBlock = {
    param($GroupName, $AppPattern)

    $errors     = @()
    $adminGroup = $null
    $members    = @()

    # --- 1. Local Administrators group --------------------------------------
    try {
        $adminSid   = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544'
        $adminGroup = $adminSid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    } catch {
        $adminGroup = 'Administrators'
        $errors += "SID lookup: $($_.Exception.Message)"
    }

    # ADSI instead of Get-LocalGroupMember, because the latter fails on
    # orphaned SIDs or Azure AD members.
    try {
        $group = [ADSI]"WinNT://$env:COMPUTERNAME/$adminGroup,group"
        foreach ($m in @($group.psbase.Invoke('Members'))) {
            try {
                $path = $m.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $m, $null)
                # WinNT://DOMAIN/Name  or  WinNT://DOMAIN/PC/Name
                $members += ($path -replace '^WinNT://', '' -replace '/', '\')
            } catch {
                $errors += "Member: $($_.Exception.Message)"
            }
        }
    } catch {
        $errors += "Admin group: $($_.Exception.Message)"
    }

    # Substring match: in the domain the group is named e.g.
    # "U_RES_DLG_WORKSTATIONS-LOHR_II_IDS". Wildcards (*, ?) passed in the
    # parameter are used as-is.
    $groupPattern = if ($GroupName -match '[\*\?]') { $GroupName } else { "*$GroupName*" }
    $found = $members | Where-Object { $_.Split('\')[-1] -like $groupPattern }

    # --- 2. Program versions ---------------------------------------------------
    # Read the registry directly via .NET: Get-ItemProperty aborts completely
    # ("Specified cast is not valid") as soon as any Uninstall entry
    # contains a corrupt value.
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
                            Status         = $null
                            Source         = "Registry ($view)"
                        }
                    }
                    $sub.Close()
                } catch { }   # ignore single corrupt entries
            }
            $root.Close(); $base.Close()
        } catch {
            $errors += "Registry ($view): $($_.Exception.Message)"
        }
    }

    # Always query Software Center / ConfigMgr client as well: packages
    # deployed via script often have no Uninstall entry.
    try {
        $apps += @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' -ErrorAction Stop |
            Where-Object { $_.FullName -like $AppPattern -or $_.Name -like $AppPattern } |
            Select-Object @{n = 'DisplayName';    e = { if ($_.FullName) { $_.FullName } else { $_.Name } } },
                          @{n = 'DisplayVersion'; e = { $_.SoftwareVersion } },
                          @{n = 'Status';         e = { $_.InstallState } },
                          @{n = 'Source';         e = { 'Software Center' } })
    } catch {
        # No ConfigMgr client installed -> not fatal, just a note
        $errors += "Software Center (applications): $($_.Exception.Message)"
    }

    # Classic SCCM packages/programs: also shown in Software Center under
    # "Installation status", but not returned by CCM_Application.
    try {
        $apps += @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Program' -ErrorAction Stop |
            Where-Object { $_.PackageName -like $AppPattern -or $_.Name -like $AppPattern } |
            Select-Object @{n = 'DisplayName';    e = { if ($_.PackageName) { $_.PackageName } else { $_.Name } } },
                          @{n = 'DisplayVersion'; e = { $_.Version } },
                          @{n = 'Status';         e = { $_.LastRunStatus } },
                          @{n = 'Source';         e = { 'Software Center (package)' } })
    } catch {
        $errors += "Software Center (packages): $($_.Exception.Message)"
    }

    # Do not list identical entries from 64-/32-bit registry twice
    $apps = @($apps | Sort-Object DisplayName, DisplayVersion, Source -Unique)

    $common = [ordered]@{
        Computer        = $env:COMPUTERNAME
        AdminGroup      = $adminGroup
        GroupIsMember   = [bool]$found
        FoundAs         = ($found -join '; ')
        AllMembers      = ($members -join '; ')
    }

    if (-not $apps) {
        $row = [ordered]@{}; foreach ($k in $common.Keys) { $row[$k] = $common[$k] }
        $row.NewestVersion = $null
        $row.Program = $null; $row.Version = $null; $row.Status = $null; $row.Source = $null
        $row.Errors  = ($errors -join ' | ')
        [pscustomobject]$row
        return
    }

    foreach ($app in $apps) {
        $v = if ($app.DisplayName -match 'version\s*:\s*([\d\.]+)') { $Matches[1] } else { $app.DisplayVersion }
        $app | Add-Member -NotePropertyName Version -NotePropertyValue $v -Force
    }

    # Determine highest version ("03.02" -> 3.2)
    $newest = $apps | Where-Object { $_.Version -as [version] } |
        Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    $common.NewestVersion = if ($newest) { $newest.Version } else { $null }

    # One row per program entry found
    foreach ($app in $apps) {
        $version = $app.Version
        $row = [ordered]@{}; foreach ($k in $common.Keys) { $row[$k] = $common[$k] }
        $row.Program  = $app.DisplayName
        $row.Version  = $version
        $row.Status   = $app.Status
        $row.Source   = $app.Source
        $row.Errors   = ($errors -join ' | ')
        [pscustomobject]$row
    }
}

$rows     = @(& $checkBlock $GroupName $AppPattern)
$first    = $rows[0]
$versions = @($rows | Where-Object { $_.Version })

$lines = @()
$lines += "Computer          : $($first.Computer)"
$lines += "Admin group       : $($first.AdminGroup)"
$lines += "DLG group member  : " + $(if ($first.GroupIsMember) { "YES ($($first.FoundAs))" } else { 'NO' })
$lines += "Members           :"
foreach ($m in ($first.AllMembers -split '; ' | Where-Object { $_ })) { $lines += "    $m" }
$lines += "Newest version    : $($first.NewestVersion)"
$lines += "Installed versions:"
if ($versions) {
    foreach ($v in $versions) { $lines += "    $($v.Version)  $($v.Status)  [$($v.Source)]" }
} else {
    $lines += '    none found'
}
if ($first.Errors) { $lines += "Errors            : $($first.Errors)" }

Write-Output ($lines -join "`n")
