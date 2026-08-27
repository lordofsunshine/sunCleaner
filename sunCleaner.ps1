<#
.SYNOPSIS
    sunCleaner - all-in-one Windows maintenance suite
#>

#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$NoElevate,
    [switch]$Plain,
    [switch]$InstallSchedule,
    [switch]$RemoveSchedule,
    [switch]$ScheduledClean,
    [switch]$ScheduledScan,
    [string]$ReportPath
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$script:Category = $null
$script:Include = @()
$script:Exclude = @()
$script:IncludeDangerous = $false
$script:Conservative = $false
$script:CurrentUserOnly = $false
$script:Drives = $null
$script:DryRun = $false
$script:Unattended = $false
$script:NoRestorePoint = $false
$script:SkipOptimization = $false
$script:MaxAgeDays = 0
$script:LogPath = "$env:TEMP\sunCleaner.log"
$script:Area = $null
$script:BackupDir = "$env:ProgramData\sunCleaner\backups"
$script:ScanOnly = $false
$script:FixAll = $false
$script:IncludeHeavy = $false

$root = $PSScriptRoot
. (Join-Path $root 'src/Core/Common.ps1')
. (Join-Path $root 'src/Core/UI.ps1')
Initialize-UiTheme -Plain:$Plain

$steps = @(
    @{ Path=(Join-Path $root 'src/Features/Schedule.ps1') },
    @{ Path=(Join-Path $root 'src/Engines/Clean.ps1') },
    @{ Path=(Join-Path $root 'src/Engines/Optimize.ps1') },
    @{ Path=(Join-Path $root 'src/Engines/Repair.ps1') },
    @{ Path=(Join-Path $root 'src/Features/Network.ps1') },
    @{ Path=(Join-Path $root 'src/Features/Startup.ps1') },
    @{ Path=(Join-Path $root 'src/Menu/Main.ps1') }
)
if ([Console]::IsInputRedirected) {
    foreach ($s in $steps) { try { . $s.Path } catch {} }
} else {
    try { [Console]::CursorVisible = $false } catch {}
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $pct = [int](($i+1)/$steps.Count*100)
        $name = Split-Path $steps[$i].Path -Leaf
        Show-SunSplashStep -Name $name -Index $i -Total $steps.Count -Percent $pct
        try { . $steps[$i].Path } catch { Write-WsLog "failed $name : $_" 'Warning' }
        Start-Sleep -Milliseconds 120
    }
    try { [Console]::CursorVisible = $true } catch {}
    try { Clear-Host } catch {}
    $r0 = @(0..7 | ForEach-Object { @('|','/','-','\')[($_) % 4] })
    $pal = $script:SunPalette; $gold=$pal.Amber; $white=$pal.White; $dim=$pal.Dim; $rst=$pal.Reset
    Write-Host ""
    Write-Host "  $gold     $($r0[7])  $($r0[0])  $($r0[1])$rst"
    Write-Host "  $white      .---. $rst"
    Write-Host "  $gold  $($r0[6])$($r0[6])$white (     )$gold $($r0[2])$($r0[2])$rst"
    Write-Host "  $white      '---' $rst"
    Write-Host "  $gold     $($r0[5])  $($r0[4])  $($r0[3])$rst"
    Write-Host ""
    Write-Host "  $white  sunCleaner  $dim v$(Get-SunCleanerVersion)  -- solar care for Windows$rst"
    Write-Host "  $dim  single-file  *  3-color  *  safe$rst"
    Write-Host "  $gold  ------------------------------$rst"
    Write-Host ""
    Start-Sleep -Milliseconds 400
}

if (-not (Test-AdminPrivileges)) {
    if ($NoElevate) { Write-WsLog 'Not running as Administrator - most actions will fail.' 'Warning' }
    else {
        Write-WsLog 'Requesting administrator privileges...' 'Step'
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
            exit 0
        } catch { Write-WsLog 'Elevation cancelled. Re-run as Administrator, or use -NoElevate.' 'Error'; exit 1 }
    }
}

if ($InstallSchedule) { Install-SunCleanerSchedule -Root $root -LogAction { param($m,$l) Write-WsLog $m $l } | Out-Null; exit 0 }
if ($RemoveSchedule) { Remove-SunCleanerSchedule -LogAction { param($m,$l) Write-WsLog $m $l } | Out-Null; exit 0 }
if ($ScheduledClean) {
    $script:StartTime = Get-Date; $script:Stats = New-Object System.Collections.Generic.List[object]
    $script:TotalBytes=0; $script:TotalFiles=0; $script:TotalErrors=0; $script:RestorePointMade=$false
    $script:Category=$null; $script:Include=$null; $script:Exclude=$null; $script:IncludeDangerous=$false; $script:Conservative=$false
    $script:CurrentUserOnly=$false; $script:Drives=$null; $script:DryRun=$false; $script:Unattended=$true; $script:NoRestorePoint=$true; $script:SkipOptimization=$true
    $script:MaxAgeDays=0; $script:LogPath="$env:TEMP\sunCleaner-sched-clean.log"
    if (-not $ReportPath) { $ReportPath = "$env:ProgramData\sunCleaner\reports\cleanup.json" }
    $script:ReportPath = $ReportPath
    Start-SunCleanerCleanup; exit 0
}
if ($ScheduledScan) {
    $script:StartTime=Get-Date; $script:Results=New-Object System.Collections.Generic.List[object]
    $script:Fixed=0; $script:FixErrors=0; $script:RebootNeeded=$false; $script:RestorePointMade=$false
    $script:Category=$null; $script:Include=$null; $script:Exclude=$null; $script:ScanOnly=$true; $script:FixAll=$false; $script:IncludeHeavy=$false
    $script:Conservative=$false; $script:DryRun=$false; $script:Unattended=$true; $script:NoRestorePoint=$false
    $script:LogPath="$env:TEMP\sunCleaner-sched-scan.log"
    if (-not $ReportPath) { $ReportPath = "$env:ProgramData\sunCleaner\reports\repair.json" }
    $script:ReportPath = $ReportPath
    Start-SunCleanerRepairInner; exit 0
}

if ($MyInvocation.InvocationName -ne '.' ) { Show-MainMenu }
