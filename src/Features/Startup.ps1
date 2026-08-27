function Get-StartupApps {
    $keys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run')
    $out = @()
    foreach ($k in $keys) {
        if (-not (Test-Path $k)) { continue }
        $props = (Get-ItemProperty $k -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -is [byte[]] }
        foreach ($p in $props) {
            $enabled = $p.Value[0] -eq 2
            $out += [pscustomobject]@{ Name = $p.Name; Path = $k; Enabled = $enabled }
        }
    }
    $out
}

function Set-StartupState {
    param([string]$Path, [string]$Name, [bool]$Enabled)
    $val = if ($Enabled) { [byte[]](0x02,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00) } else { [byte[]](0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00) }
    try { Set-ItemProperty -Path $Path -Name $Name -Value $val -ErrorAction Stop; return $true } catch { return $false }
}

function Show-StartupScreen {
    while ($true) {
        $apps = @(Get-StartupApps)
        $enabled = @($apps | Where-Object Enabled)
        $status = @("$($enabled.Count)/$($apps.Count) enabled - toggle to trim boot time")
        $items = $apps | ForEach-Object {
            $state = if ($_.Enabled) { 'on ' } else { 'off' }
            [pscustomobject]@{ Label = "$state $($_.Name)" }
        }
        if (-not $items) { $items = @([pscustomobject]@{ Label = '(no startup entries found)' }) }
        # use checklist for toggling
        $onSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($a in ($apps | Where-Object Enabled)) { [void]$onSet.Add($a.Name) }
        # map to checklist items
        $chkItems = $apps | ForEach-Object { [pscustomobject]@{ Id = $_.Name; Name = $_.Name; Group = 'Startup'; Risk = if ($_.Enabled) { 'Moderate' } else { 'Safe' }; Applied = $_.Enabled } }
        # show checklist, then apply diff
        $before = @($onSet | ForEach-Object { $_ })
        Show-Checklist -Title 'sunCleaner - startup' -Items $chkItems -OnSet $onSet
        # if user cancelled, onSet unchanged vs before? we always apply
        foreach ($a in $apps) {
            $shouldBeOn = $onSet.Contains($a.Name)
            if ($shouldBeOn -ne $a.Enabled) {
                $ok = Set-StartupState -Path $a.Path -Name $a.Name -Enabled $shouldBeOn
                if ($ok) { Write-WsLog "$($a.Name) -> $(if ($shouldBeOn){'enabled'}else{'disabled'})" 'Success' }
                else { Write-WsLog "failed $($a.Name)" 'Error' }
            }
        }
        $choice = Read-Host '  press Enter to refresh, or type q to go back'
        if ($choice -eq 'q') { return }
    }
}
