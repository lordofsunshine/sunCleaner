
<#
.SYNOPSIS
    Scheduled-task installer for sunCleaner recurring maintenance.
#>

$script:sunCleanerTaskPath = '\sunCleaner\'

#   returns one spec per scheduled task. No registration, no I/O.
function Get-sunCleanerScheduleSpec {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ReportDir = "$env:ProgramData\sunCleaner\reports"
    )
    $common = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File'

    [pscustomobject]@{
        Name        = 'sunCleaner Weekly Cleanup'
        TaskPath    = $script:sunCleanerTaskPath
        Description = 'sunCleaner: weekly unattended disk cleanup (no restore point, no slow SFC/DISM).'
        Execute     = 'powershell.exe'
        Argument    = ('{0} "{1}" -ScheduledClean -ReportPath "{2}"' -f
                        $common, (Join-Path $Root 'sunCleaner.ps1'), (Join-Path $ReportDir 'cleanup.json'))
        Cadence     = 'Weekly'
        Day         = 'Sunday'
        Time        = '03:00'
    }

    [pscustomobject]@{
        Name        = 'sunCleaner Monthly Health Scan'
        TaskPath    = $script:sunCleanerTaskPath
        Description = 'sunCleaner: monthly read-only health scan (changes nothing, writes a JSON report).'
        Execute     = 'powershell.exe'
        Argument    = ('{0} "{1}" -ScheduledScan -ReportPath "{2}"' -f
                        $common, (Join-Path $Root 'sunCleaner.ps1'), (Join-Path $ReportDir 'repair.json'))
        Cadence     = 'Monthly'
        Day         = 1
        Time        = '03:30'
    }
}

#   weekly via the cmdlet; monthly via the CIM class (New-ScheduledTaskTrigger
#   has no -Monthly). DaysOfMonth and MonthsOfYear are bitmasks.
function New-sunCleanerTrigger {
    param([Parameter(Mandatory)]$Spec)
    $at = [datetime]::ParseExact($Spec.Time, 'HH:mm', $null)
    switch ($Spec.Cadence) {
        'Weekly' {
            return New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Spec.Day -At $at
        }
        'Monthly' {
            # new-ScheduledTaskTrigger has no -Monthly, so build the CIM trigger.
            # mSFT_TaskMonthlyTrigger: DaysOfMonth and MonthOfYear (singular) are
            # bitmasks; MonthOfYear MUST be set or the task never fires.
            $cls = Get-CimClass -ClassName MSFT_TaskMonthlyTrigger `
                -Namespace 'Root/Microsoft/Windows/TaskScheduler'
            $t = New-CimInstance -CimClass $cls -ClientOnly
            $t.DaysOfMonth   = 1 -shl ([int]$Spec.Day - 1)  # day 1 -> bit 0 -> 1
            $t.MonthOfYear   = 0xFFF                          # all 12 months
            $t.StartBoundary = $at.ToString('yyyy-MM-ddTHH:mm:ss')
            $t.Enabled       = $true
            return $t
        }
        default { throw "Unknown cadence: $($Spec.Cadence)" }
    }
}

function Install-sunCleanerSchedule {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ReportDir = "$env:ProgramData\sunCleaner\reports",
        [scriptblock]$LogAction = { param($m, $l) Write-Host $m }
    )
    if (-not (Test-Path $ReportDir)) {
        New-Item -ItemType Directory -Path $ReportDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    $ok = 0
    foreach ($spec in (Get-sunCleanerScheduleSpec -Root $Root -ReportDir $ReportDir)) {
        try {
            $action  = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument
            $trigger = New-sunCleanerTrigger -Spec $spec
            Register-ScheduledTask -TaskName $spec.Name -TaskPath $spec.TaskPath `
                -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                -Description $spec.Description -Force -ErrorAction Stop | Out-Null
            & $LogAction ("Registered: {0} ({1})" -f $spec.Name, $spec.Cadence) 'Success'
            $ok++
        }
        catch {
            & $LogAction ("Failed to register '{0}': {1}" -f $spec.Name, $_.Exception.Message) 'Error'
        }
    }
    & $LogAction ("Scheduled tasks installed: {0}. Reports go to {1}" -f $ok, $ReportDir) 'Info'
    return $ok
}

function Remove-sunCleanerSchedule {
    param(
        [string]$Root = $PSScriptRoot,
        [scriptblock]$LogAction = { param($m, $l) Write-Host $m }
    )
    $removed = 0
    foreach ($spec in (Get-sunCleanerScheduleSpec -Root $Root)) {
        try {
            $existing = Get-ScheduledTask -TaskName $spec.Name -TaskPath $spec.TaskPath -ErrorAction SilentlyContinue
            if ($existing) {
                Unregister-ScheduledTask -TaskName $spec.Name -TaskPath $spec.TaskPath -Confirm:$false -ErrorAction Stop
                & $LogAction ("Removed: {0}" -f $spec.Name) 'Success'
                $removed++
            }
            else {
                & $LogAction ("Not present: {0}" -f $spec.Name) 'Info'
            }
        }
        catch {
            & $LogAction ("Failed to remove '{0}': {1}" -f $spec.Name, $_.Exception.Message) 'Warning'
        }
    }
    & $LogAction ("Scheduled tasks removed: {0}" -f $removed) 'Info'
    return $removed
}
