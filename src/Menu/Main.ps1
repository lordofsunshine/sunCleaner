$script:CleanReg = Get-CleanupTaskRegistry
$script:OptReg = Get-OptimizationTweakRegistry
$script:RepairReg = Get-DiagnosticCheckRegistry

$script:CleanOn = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($t in (Resolve-CleanupSelection -Registry $script:CleanReg)) { [void]$script:CleanOn.Add($t.Id) }
$script:OptOn = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($t in (Resolve-TweakSelection -Registry $script:OptReg)) { [void]$script:OptOn.Add($t.Id) }
$script:RepairOn = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($t in $script:RepairReg) { [void]$script:RepairOn.Add($t.Id) }
$script:CleanCU = $false


function Write-Banner { param([string]$Title) Write-SunBanner -Title $Title }

function Wait-Enter {
    $p = $script:SunPalette
    Write-Host ''
    Write-Host "$($p.Dim)  press Enter to continue...$($p.Reset)" -NoNewline
    [void](Read-Host)
}

function Get-SelectionParams {
    param([object[]]$Registry, [object]$OnSet)
    $on = @($Registry | Where-Object { $OnSet.Contains($_.Id) } | ForEach-Object Id)
    $off = @($Registry | Where-Object { -not $OnSet.Contains($_.Id) } | ForEach-Object Id)
    @{ Include = $on; Exclude = $off }
}

function Get-CleanupItems {
    $script:CleanReg | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Group = $_.Category; Risk = $_.Risk; Applied = $null } }
}
function Get-OptimizeItems {
    param([hashtable]$Applied)
    $script:OptReg | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Group = $_.Area; Risk = $_.Risk; Applied = $Applied[$_.Id] } }
}
function Get-RepairItems {
    $script:RepairReg | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Group = $_.Category; Risk = $_.FixRisk; Applied = $null } }
}
function Get-AppliedMap {
    $m = @{}
    foreach ($t in $script:OptReg) { $m[$t.Id] = (Test-TweakApplied -Tweak $t) }
    $m
}

function Invoke-CleanupUnified {
    param([bool]$Preview)
    $params = Get-SelectionParams -Registry $script:CleanReg -OnSet $script:CleanOn
    if (-not $params.Include.Count) { Write-WsLog 'nothing selected.' 'Warning'; return }
    $script:Include = $params.Include; $script:Exclude = $params.Exclude; $script:CurrentUserOnly = $script:CleanCU; $script:DryRun = $Preview
    $was = $global:WhatIfPreference; if ($Preview) { $global:WhatIfPreference = $true }
    $script:StartTime = Get-Date; $script:Stats = New-Object System.Collections.Generic.List[object]
    $script:TotalBytes = [int64]0; $script:TotalFiles = 0; $script:TotalErrors = 0; $script:RestorePointMade = $false
    $script:LogPath = "$env:TEMP\sunCleaner-clean.log"; $script:ReportPath = $ReportPath
    Start-SunCleanerCleanup
    if ($Preview) { $global:WhatIfPreference = $was }
}

function Invoke-OptimizeUnified {
    param([bool]$Preview)
    $params = Get-SelectionParams -Registry $script:OptReg -OnSet $script:OptOn
    if (-not $params.Include.Count) { Write-WsLog 'nothing selected.' 'Warning'; return }
    $script:Include = $params.Include; $script:Exclude = $params.Exclude; $script:DryRun = $Preview
    $was = $global:WhatIfPreference; if ($Preview) { $global:WhatIfPreference = $true }
    $script:StartTime = Get-Date; $script:Stats = New-Object System.Collections.Generic.List[object]
    $script:Snapshots = New-Object System.Collections.Generic.List[object]
    $script:Applied = 0; $script:Skipped = 0; $script:Errors = 0; $script:RestorePointMade = $false
    $script:LogPath = "$env:TEMP\sunCleaner-opt.log"; $script:ReportPath = $ReportPath; $script:BackupDir = "$env:ProgramData\sunCleaner\backups"
    Start-SunCleanerOptimize
    if ($Preview) { $global:WhatIfPreference = $was }
}

function Show-CleanupScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Preview  - dry run' }
        [pscustomobject]@{ Label = 'Run cleanup' }
        [pscustomobject]@{ Label = 'Choose tasks' }
        [pscustomobject]@{ Label = 'Toggle scope  - all users / current user' }
        [pscustomobject]@{ Label = 'Reset to defaults' }
    )
    while ($true) {
        $onCount = @($script:CleanReg | Where-Object { $script:CleanOn.Contains($_.Id) }).Count
        $danger = @($script:CleanReg | Where-Object { $script:CleanOn.Contains($_.Id) -and $_.Risk -eq 'Dangerous' }).Count
        $scope = if ($script:CleanCU) { 'current user' } else { 'all users' }
        $status = @("Selected $onCount / $($script:CleanReg.Count)  - scope: $scope")
        if ($danger) { $status += "$danger dangerous - confirmation required" }
        switch (Show-Menu -Title 'Disk cleanup' -Items $items -StatusLines $status) {
            0 { try { Clear-Host } catch {}; Invoke-CleanupUnified -Preview $true; Wait-Enter }
            1 { try { Clear-Host } catch {}; Invoke-CleanupUnified -Preview $false; Wait-Enter }
            2 { Show-Checklist -Title 'Cleanup tasks' -Items (Get-CleanupItems) -OnSet $script:CleanOn }
            3 { $script:CleanCU = -not $script:CleanCU }
            4 { $script:CleanOn.Clear(); foreach ($t in (Resolve-CleanupSelection -Registry $script:CleanReg)) { [void]$script:CleanOn.Add($t.Id) } }
            $null { return }
        }
    }
}

function Show-OptimizeScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Preview  - dry run' }
        [pscustomobject]@{ Label = 'Apply tweaks' }
        [pscustomobject]@{ Label = 'Choose tweaks' }
        [pscustomobject]@{ Label = 'Undo last run' }
        [pscustomobject]@{ Label = 'Reset to defaults' }
    )
    while ($true) {
        $onCount = @($script:OptReg | Where-Object { $script:OptOn.Contains($_.Id) }).Count
        $status = @("Selected $onCount / $($script:OptReg.Count)", 'backed up - Undo to revert')
        switch (Show-Menu -Title 'Windows optimization' -Items $items -StatusLines $status) {
            0 { try { Clear-Host } catch {}; Invoke-OptimizeUnified -Preview $true; Wait-Enter }
            1 { try { Clear-Host } catch {}; Invoke-OptimizeUnified -Preview $false; Wait-Enter }
            2 {
                $applied = Get-AppliedMap
                Show-Checklist -Title 'Optimization tweaks' -Items (Get-OptimizeItems -Applied $applied) -OnSet $script:OptOn
            }
            3 { try { Clear-Host } catch {}; Start-SunCleanerUndo; Wait-Enter }
            4 { $script:OptOn.Clear(); foreach ($t in (Resolve-TweakSelection -Registry $script:OptReg)) { [void]$script:OptOn.Add($t.Id) } }
            $null { return }
        }
    }
}

function Show-TroubleshootScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Scan and repair  - choose what to fix' }
        [pscustomobject]@{ Label = 'Scan only  - diagnose' }
        [pscustomobject]@{ Label = 'Auto-fix safe  - Safe + Moderate' }
        [pscustomobject]@{ Label = 'Auto-fix all  - include heavy' }
    )
    $status = @('read-only scan first', 'restore point before repair')
    while ($true) {
        switch (Show-Menu -Title 'Troubleshoot' -Items $items -StatusLines $status) {
            0 { try { Clear-Host } catch {}; Invoke-SunRepairMode -Mode Interactive; Wait-Enter }
            1 { try { Clear-Host } catch {}; Invoke-SunRepairMode -Mode ScanOnly; Wait-Enter }
            2 { try { Clear-Host } catch {}; Invoke-SunRepairMode -Mode FixSafe; Wait-Enter }
            3 { try { Clear-Host } catch {}; Invoke-SunRepairMode -Mode FixAll; Wait-Enter }
            $null { return }
        }
    }
}

function Show-ToolsScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Network      - dns, reset, adapters' }
        [pscustomobject]@{ Label = 'Startup      - manage boot apps' }
        [pscustomobject]@{ Label = 'Schedule     - auto-start tasks' }
    )
    while ($true) {
        switch (Show-Menu -Title 'Tools' -Items $items) {
            0 { Show-NetworkScreen }
            1 { Show-StartupScreen }
            2 { Show-ScheduleScreen }
            $null { return }
        }
    }
}

function Show-SafetyScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Undo last optimization' }
        [pscustomobject]@{ Label = 'Create restore point' }
    )
    while ($true) {
        switch (Show-Menu -Title 'Safety' -Items $items) {
            0 { try { Clear-Host } catch {}; Write-SunBanner -Title 'Undo'; Start-SunCleanerUndo; Wait-Enter }
            1 { try { Clear-Host } catch {}; Write-SunBanner -Title 'Restore point'; New-SunCleanerRestorePoint -Description "sunCleaner manual $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -LogAction { param($m,$l) Write-WsLog $m $l } | Out-Null; Wait-Enter }
            $null { return }
        }
    }
}

function Show-ScheduleScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Install  - weekly cleanup + monthly scan' }
        [pscustomobject]@{ Label = 'Remove  - delete tasks' }
        [pscustomobject]@{ Label = 'Show status' }
    )
    $status = @('runs as SYSTEM', 'reports to %ProgramData%\sunCleaner\reports')
    while ($true) {
        switch (Show-Menu -Title 'Schedule' -Items $items -StatusLines $status) {
            0 { try { Clear-Host } catch {}; Write-SunBanner -Title 'Installing schedule'; Install-SunCleanerSchedule -Root $PSScriptRoot -LogAction { param($m,$l) Write-WsLog $m $l } | Out-Null; Wait-Enter }
            1 { try { Clear-Host } catch {}; Write-SunBanner -Title 'Removing schedule'; Remove-SunCleanerSchedule -LogAction { param($m,$l) Write-WsLog $m $l } | Out-Null; Wait-Enter }
            2 {
                try { Clear-Host } catch {}
                Write-SunBanner -Title 'Schedule status'
                $specs = Get-SunCleanerScheduleSpec -Root $PSScriptRoot
                foreach ($s in $specs) {
                    $t = Get-ScheduledTask -TaskName $s.Name -TaskPath $s.TaskPath -ErrorAction SilentlyContinue
                    if ($t) { Write-WsLog "  $($s.Name) - $($t.State) [$($s.Cadence)]" 'Success' } else { Write-WsLog "  $($s.Name) - not installed" 'Warning' }
                }
                Wait-Enter
            }
            $null { return }
        }
    }
}

function Show-ManageScreen {
    $cats = @(
        [pscustomobject]@{ Label = 'Disk cleanup   - 69 tasks' }
        [pscustomobject]@{ Label = 'Optimization   - 61 tweaks' }
        [pscustomobject]@{ Label = 'Repair checks  - 28 checks' }
    )
    while ($true) {
        $idx = Show-Menu -Title 'Manage tweaks' -Items $cats -StatusLines @('toggle on/off - affects next run', 'Space toggle, a all, n none, Enter save')
        if ($null -eq $idx) { return }
        switch ($idx) {
            0 { Show-Checklist -Title 'Manage - cleanup' -Items (Get-CleanupItems) -OnSet $script:CleanOn }
            1 {
                $applied = Get-AppliedMap
                Show-Checklist -Title 'Manage - optimization' -Items (Get-OptimizeItems -Applied $applied) -OnSet $script:OptOn
            }
            2 { Show-Checklist -Title 'Manage - repair' -Items (Get-RepairItems) -OnSet $script:RepairOn }
        }
    }
}

function Invoke-FullRun {
    Write-SunBanner -Title 'Full run' -Subtitle 'restore point first, tweaks backed up'
    $p = $script:SunPalette
    Write-Host "  Runs selected cleanup + optimization." -ForegroundColor Yellow
    Write-Host ''
    Write-Host "$($p.Amber)  Type 'yes' to proceed:$($p.Reset) " -NoNewline
    if ((Read-Host).Trim() -notmatch '^(y|yes)$') { Write-Host '  cancelled.' -ForegroundColor Gray; Wait-Enter; return }
    try { Clear-Host } catch {}
    Invoke-CleanupUnified -Preview $false
    Invoke-OptimizeUnified -Preview $false
    Wait-Enter
}

function Show-MainMenu {
    $items = @(
        [pscustomobject]@{ Label = 'Disk cleanup        - reclaim space' }
        [pscustomobject]@{ Label = 'Optimize Windows    - performance / privacy' }
        [pscustomobject]@{ Label = 'Troubleshoot        - scan and repair' }
        [pscustomobject]@{ Label = 'Full run            - cleanup + optimization' }
        [pscustomobject]@{ Label = 'Tools               - network / startup / schedule' }
        [pscustomobject]@{ Label = 'Manage tweaks       - choose what is active' }
        [pscustomobject]@{ Label = 'Safety              - undo / restore point' }
    )
    while ($true) {
        $p = $script:SunPalette
        $admin = if (Test-AdminPrivileges) { "admin: yes" } else { "admin: NO" }
        $status = @("lordofsunshine/sunCleaner", $admin, 'arrows + Enter / Esc back')
        switch (Show-Menu -Title "sunCleaner" -Items $items -StatusLines $status -Footer 'Up/Down move  Enter select  Esc quit') {
            0 { Show-CleanupScreen }
            1 { Show-OptimizeScreen }
            2 { Show-TroubleshootScreen }
            3 { Invoke-FullRun }
            4 { Show-ToolsScreen }
            5 { Show-ManageScreen }
            6 { Show-SafetyScreen }
            $null { try { Clear-Host } catch {}; Write-Host "  $($p.Amber)bye - keep it sunny$($p.Reset)"; return }
        }
    }
}

function Invoke-SunRepairMode {
    param([ValidateSet('Interactive','ScanOnly','FixSafe','FixAll')][string]$Mode = 'Interactive')
    $script:StartTime = Get-Date; $script:Results = New-Object System.Collections.Generic.List[object]
    $script:Fixed = 0; $script:FixErrors = 0; $script:RebootNeeded = $false; $script:RestorePointMade = $false
    $script:LogPath = "$env:TEMP\sunCleaner-repair.log"; $script:ReportPath = $ReportPath
    $script:Category = $null; $script:Include = $null; $script:Exclude = $null
    # respect managed repair set - if user disabled some checks via Manage, exclude them
    $managedOff = @($script:RepairReg | Where-Object { -not $script:RepairOn.Contains($_.Id) } | ForEach-Object Id)
    if ($managedOff) { $script:Exclude = $managedOff }
    $script:Conservative = $false; $script:DryRun = $false; $script:NoRestorePoint = $false
    switch ($Mode) {
        'ScanOnly' { $script:ScanOnly = $true; $script:FixAll = $false; $script:IncludeHeavy = $false; $script:Unattended = $false }
        'FixSafe'  { $script:ScanOnly = $false; $script:FixAll = $true; $script:IncludeHeavy = $false; $script:Unattended = $true }
        'FixAll'   { $script:ScanOnly = $false; $script:FixAll = $true; $script:IncludeHeavy = $true; $script:Unattended = $true }
        default    { $script:ScanOnly = $false; $script:FixAll = $false; $script:IncludeHeavy = $false; $script:Unattended = $false }
    }
    try { Clear-Host } catch {}
    Start-SunCleanerRepairInner
}
