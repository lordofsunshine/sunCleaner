<#
.SYNOPSIS
    Shared library for the sunCleaner engines (cleanup / optimize / repair).
#>

function Test-AdminPrivileges {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function Test-WhatIfMode { [bool]$WhatIfPreference }

function Format-FileSize {
    param([long]$Size)
    if     ($Size -ge 1TB) { '{0:N2} TB' -f ($Size / 1TB) }
    elseif ($Size -ge 1GB) { '{0:N2} GB' -f ($Size / 1GB) }
    elseif ($Size -ge 1MB) { '{0:N2} MB' -f ($Size / 1MB) }
    elseif ($Size -ge 1KB) { '{0:N2} KB' -f ($Size / 1KB) }
    else                   { "$Size B" }
}

$script:SunPalette = @{
    Amber = "$([char]27)[38;2;255;182;39m"
    AmberDim = "$([char]27)[38;2;180;130;30m"
    White = "$([char]27)[38;2;255;244;230m"
    Coral = "$([char]27)[38;2;255;107;53m"
    CoralDim = "$([char]27)[38;2;200;80;40m"
    Dim   = "$([char]27)[38;2;130;125;115m"
    Bold  = "$([char]27)[1m"
    Reset = "$([char]27)[0m"
}

function Write-WsLog {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Debug','Step','WhatIf','Safety')]
        [string]$Level = 'Info',
        [string]$LogPath
    )
    $p = $script:SunPalette
    $tag = switch ($Level) {
        'Success' { "$($p.Amber)  +$($p.Reset)" }
        'Warning' { "$($p.Coral)  !$($p.Reset)" }
        'Error'   { "$($p.Coral)  x$($p.Reset)" }
        'Step'    { "$($p.Amber) ->$($p.Reset)" }
        'WhatIf'  { "$($p.Dim)  ~$($p.Reset)" }
        'Safety'  { "$($p.Coral)  #$($p.Reset)" }
        'Debug'   { "$($p.Dim)   $($p.Reset)" }
        default   { "$($p.Dim)  i$($p.Reset)" }
    }
    $coloredMessage = switch ($Level) {
        'Success' { "$($p.Amber)${Message}$($p.Reset)" }
        'Warning' { "$($p.Coral)${Message}$($p.Reset)" }
        'Error'   { "$($p.Coral)$($p.Bold)${Message}$($p.Reset)" }
        'Step'    { "$($p.Amber)$($p.Bold)${Message}$($p.Reset)" }
        'WhatIf'  { "$($p.Dim)${Message}$($p.Reset)" }
        'Safety'  { "$($p.Coral)${Message}$($p.Reset)" }
        'Debug'   { "$($p.Dim)${Message}$($p.Reset)" }
        default   { "$($p.White)${Message}$($p.Reset)" }
    }
    if ($Level -ne 'Debug' -or $VerbosePreference -ne 'SilentlyContinue') {
        Write-Host "$tag $coloredMessage"
    }
    if ($LogPath) {
        $stamp = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
        try { Add-Content -Path $LogPath -Value $stamp -ErrorAction SilentlyContinue -WhatIf:$false } catch { }
    }
}

function New-SunCleanerRestorePoint {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$LogAction
    )
    if (Test-WhatIfMode) {
        & $LogAction '[WhatIf] would create a System Restore point' 'WhatIf'
        return 'WhatIf'
    }
    & $LogAction 'Creating System Restore point...' 'Safety'
    try {
        $rk = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        New-ItemProperty -Path $rk -Name 'SystemRestorePointCreationFrequency' `
            -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $Description `
            -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        & $LogAction 'System Restore point created' 'Success'
        return 'Created'
    }
    catch {
        & $LogAction "Restore point not created: $($_.Exception.Message)" 'Warning'
        & $LogAction 'Continuing without a restore point (System Protection may be off).' 'Warning'
        return 'Failed'
    }
}

function Get-SunCleanerVersion { '1.0.0' }

function Write-SunCleanerReport {
    param(
        [string]$ReportPath,
        [Parameter(Mandatory)][ValidateSet('Cleanup', 'Optimize', 'Repair')][string]$Engine,
        [hashtable]$Summary = @{},
        $Items = @(),
        [bool]$RestorePoint,
        [datetime]$StartTime,
        [scriptblock]$LogAction
    )
    if (-not $ReportPath) { return }
    $itemArr = if ($null -eq $Items) { @() } else { [object[]]$Items }
    $report = [ordered]@{
        Tool         = 'sunCleaner'
        Version      = (Get-SunCleanerVersion)
        Engine       = $Engine
        Host         = $env:COMPUTERNAME
        Timestamp    = (Get-Date).ToString('s')
        Mode         = if (Test-WhatIfMode) { 'DryRun' } else { 'Live' }
        RestorePoint = [bool]$RestorePoint
        DurationSec  = if ($StartTime) { [math]::Round(((Get-Date) - $StartTime).TotalSeconds, 1) } else { $null }
        Summary      = $Summary
        Items        = $itemArr
    }
    try {
        ($report | ConvertTo-Json -Depth 6) | Set-Content -Path $ReportPath -Encoding UTF8 -WhatIf:$false
        if ($LogAction) { & $LogAction "JSON report written: $ReportPath" 'Info' }
    }
    catch {
        if ($LogAction) { & $LogAction "Could not write report: $($_.Exception.Message)" 'Warning' }
    }
}

