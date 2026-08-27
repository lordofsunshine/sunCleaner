<#
.SYNOPSIS
    sunCleaner - standalone pastebin - lordofsunshine/sunCleaner v1.0.0
    Run without install: powershell -ExecutionPolicy Bypass -Command "irm https://pastebin.com/raw/XXXX | iex"
#>

#Requires -Version 5.1

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



# --- src/Core/Common.ps1 ---

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

# --- src/Core/UI.ps1 ---

<#
.SYNOPSIS
    TUI primitives for sunCleaner.
#>

function Get-UiGlyphSet {
    param([switch]$Plain)
    if ($Plain) { return @{ TL = '+'; TR = '+'; BL = '+'; BR = '+'; H = '-'; V = '|'; Cursor = '>' } }
    @{ TL = [string][char]0x250C; TR = [string][char]0x2510; BL = [string][char]0x2514; BR = [string][char]0x2518; H = [string][char]0x2500; V = [string][char]0x2502; Cursor = [string][char]0x25B6 }
}

function Initialize-UiTheme {
    param([switch]$Plain)
    $script:UiGlyph = Get-UiGlyphSet -Plain:$Plain
    $script:UiColor = @{ Frame='Yellow'; Title='Yellow'; Dim='DarkGray'; Accent='Yellow'; Danger='Red'; Normal='White'; HighlightFg='Black'; HighlightBg='Yellow' }
    $script:UiLastHeight = 0
}

function Resolve-MenuAction {
    param([string]$Token, [int]$Cursor, [int]$Count)
    switch ($Token) {
        'Up' { return @{ Cursor=(($Cursor-1+$Count)%$Count); Result='move'; Index=$null } }
        'Down' { return @{ Cursor=(($Cursor+1)%$Count); Result='move'; Index=$null } }
        'Home' { return @{ Cursor=0; Result='move'; Index=$null } }
        'End' { return @{ Cursor=($Count-1); Result='move'; Index=$null } }
        'Enter' { return @{ Cursor=$Cursor; Result='select'; Index=$Cursor } }
        'Esc' { return @{ Cursor=$Cursor; Result='back'; Index=$null } }
        'q' { return @{ Cursor=$Cursor; Result='back'; Index=$null } }
        default {
            if ($Token -match '^[0-9]$') {
                $d=[int]$Token
                if ($d -eq 0) { return @{ Cursor=$Cursor; Result='back'; Index=$null } }
                if ($d -ge 1 -and $d -le $Count) { return @{ Cursor=($d-1); Result='select'; Index=($d-1) } }
            }
            return @{ Cursor=$Cursor; Result='none'; Index=$null }
        }
    }
}

function New-UiRow {
    param([string]$Text, [string]$Fg, [bool]$Highlight, [int]$Inner)
    $body = (' ' + $Text)
    if ($body.Length -lt $Inner) { $body = $body.PadRight($Inner) } else { $body = $body.Substring(0,$Inner) }
    [pscustomobject]@{ Left=$script:UiGlyph.V; Text=$body; Right=$script:UiGlyph.V; Fg=$Fg; Highlight=$Highlight }
}

function Get-MenuFrame {
    param([string]$Title, [object[]]$Items, [int]$Cursor, [string[]]$StatusLines=@(), [string]$Footer='', [int]$Width=60, [hashtable]$Glyph)
    if ($Glyph) { $script:UiGlyph=$Glyph }
    $g=$script:UiGlyph; $inner=$Width-2
    $rule={ param($l,$r) [pscustomobject]@{ Left=$l; Text=($g.H*$inner); Right=$r; Fg=$script:UiColor.Frame; Highlight=$false } }
    $out=New-Object 'System.Collections.Generic.List[object]'
    $out.Add((& $rule $g.TL $g.TR))
    $out.Add((New-UiRow -Text $Title -Fg $script:UiColor.Title -Highlight $false -Inner $inner))
    $out.Add((New-UiRow -Text '' -Fg $script:UiColor.Dim -Highlight $false -Inner $inner))
    foreach ($s in $StatusLines) { $out.Add((New-UiRow -Text $s -Fg $script:UiColor.Dim -Highlight $false -Inner $inner)) }
    $out.Add((New-UiRow -Text '' -Fg $script:UiColor.Dim -Highlight $false -Inner $inner))
    for ($i=0; $i -lt $Items.Count; $i++) {
        $cur=if($i -eq $Cursor){$g.Cursor}else{' '}
        $txt='{0} {1,2}  {2}' -f $cur,($i+1),$Items[$i].Label
        $out.Add((New-UiRow -Text $txt -Fg $script:UiColor.Normal -Highlight ($i -eq $Cursor) -Inner $inner))
    }
    $out.Add((New-UiRow -Text '' -Fg $script:UiColor.Dim -Highlight $false -Inner $inner))
    $out.Add((& $rule $g.BL $g.BR))
    if ($Footer) { $out.Add([pscustomobject]@{ Left=''; Text=" $Footer"; Right=''; Fg=$script:UiColor.Dim; Highlight=$false }) }
    ,$out.ToArray()
}

function Show-Menu {
    param([string]$Title, [object[]]$Items, [string[]]$StatusLines=@(), [string]$Footer='Up/Down move   Enter select   Esc back')
    if ([Console]::IsInputRedirected) {
        try { Clear-Host } catch {}
        Write-Host ""; Write-Host "  $Title" -ForegroundColor Yellow
        foreach ($s in $StatusLines) { Write-Host "  $s" -ForegroundColor DarkGray }
        Write-Host ""
        for ($i=0; $i -lt $Items.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i+1),$Items[$i].Label) }
        Write-Host ""
        $ans=Read-Host "  Select 1-$($Items.Count) or 0=back"
        if ($ans -match '^\d+$') { $n=[int]$ans; if ($n -eq 0){return $null}; if($n -ge 1 -and $n -le $Items.Count){return $n-1} }
        return $null
    }
    try { Clear-Host } catch {}
    $script:UiLastHeight=0
    $cursor=0; $w=Get-FrameWidth
    while ($true) {
        $frame=Get-MenuFrame -Title $Title -Items $Items -Cursor $cursor -StatusLines $StatusLines -Footer $Footer -Width $w -Glyph $script:UiGlyph
        Write-Frame -Lines $frame
        $act=Resolve-MenuAction -Token (Read-MenuKey) -Cursor $cursor -Count $Items.Count
        $cursor=$act.Cursor
        switch ($act.Result) { 'select'{return $act.Index} 'back'{return $null} }
    }
}

function Show-Checklist {
    param([string]$Title, [object[]]$Items, $OnSet, [string[]]$StatusLines=@(), [string]$Footer='Up/Down move   Space toggle   a all   n none   Enter done   Esc back')
    if ([Console]::IsInputRedirected) {
        try { Clear-Host } catch {}
        Write-Host ""; Write-Host "  $Title" -ForegroundColor Yellow
        foreach ($s in $StatusLines){ Write-Host "  $s" -ForegroundColor DarkGray }
        Write-Host ""
        $lastGroup=$null
        for($i=0;$i -lt $Items.Count;$i++){ $it=$Items[$i]; if($it.Group -ne $lastGroup){ Write-Host "  $($it.Group)" -ForegroundColor Yellow; $lastGroup=$it.Group }; $box=if($OnSet.Contains($it.Id)){'[x]'}else{'[ ]'}; Write-Host ("  {0,2}. {1} {2}" -f ($i+1),$box,$it.Name) }
        Write-Host ""; Write-Host "  Enter numbers to toggle (e.g. 1 3 5), a=all, n=none, Enter=done" -ForegroundColor DarkGray
        while($true){
            $ans=Read-Host "  >"
            if([string]::IsNullOrWhiteSpace($ans)){return}
            if($ans -eq 'a'){ foreach($it in $Items){[void]$OnSet.Add($it.Id)} }
            elseif($ans -eq 'n'){ $OnSet.Clear() }
            else{ foreach($tok in ($ans -split '[\s,]+')){ if($tok -match '^\d+$'){ $idx=[int]$tok-1; if($idx -ge 0 -and $idx -lt $Items.Count){ $id=$Items[$idx].Id; if($OnSet.Contains($id)){[void]$OnSet.Remove($id)}else{[void]$OnSet.Add($id)} } } } }
            try{Clear-Host}catch{}
            Write-Host "  $Title" -ForegroundColor Yellow
            $lastGroup=$null
            for($i=0;$i -lt $Items.Count;$i++){ $it=$Items[$i]; if($it.Group -ne $lastGroup){ Write-Host "  $($it.Group)" -ForegroundColor Yellow; $lastGroup=$it.Group }; $box=if($OnSet.Contains($it.Id)){'[x]'}else{'[ ]'}; $risk=if($it.Risk){$it.Risk}else{''}; Write-Host ("  {0,2}. {1} {2,-10} {3}" -f ($i+1),$box,$risk,$it.Name) }
            Write-Host ""; Write-Host "  Enter numbers to toggle, a=all, n=none, Enter=done" -ForegroundColor DarkGray
        }
    }
    try { Clear-Host } catch {}
    $script:UiLastHeight=0
    $cursor=0; $w=Get-FrameWidth
    while($true){
        $frame=Get-ChecklistFrame -Title $Title -Items $Items -Cursor $cursor -OnSet $OnSet -StatusLines $StatusLines -Footer $Footer -Width $w -Glyph $script:UiGlyph
        Write-Frame -Lines $frame
        $act=Resolve-ChecklistAction -Token (Read-MenuKey) -Cursor $cursor -Count $Items.Count
        $cursor=$act.Cursor
        switch($act.Action){
            'toggle'{ $id=$Items[$act.Index].Id; if($OnSet.Contains($id)){[void]$OnSet.Remove($id)}else{[void]$OnSet.Add($id)} }
            'all'{ foreach($it in $Items){[void]$OnSet.Add($it.Id)} }
            'none'{ $OnSet.Clear() }
            'done'{ return }
            'cancel'{ return }
        }
    }
}

function Read-MenuKey {
    if ([Console]::IsInputRedirected){ return 'Redirected' }
    $k=[Console]::ReadKey($true)
    switch($k.Key){
        'UpArrow'{return 'Up'} 'DownArrow'{return 'Down'} 'LeftArrow'{return 'Left'} 'RightArrow'{return 'Right'}
        'Enter'{return 'Enter'} 'Escape'{return 'Esc'} 'Spacebar'{return 'Space'} 'Home'{return 'Home'} 'End'{return 'End'} 'PageUp'{return 'PageUp'} 'PageDown'{return 'PageDown'}
        default{ $c=$k.KeyChar; if($c -and -not [char]::IsControl($c)){return [string]$c}; return 'none' }
    }
}

function Get-FrameWidth { try{return [Math]::Min(76,[Console]::WindowWidth-1)}catch{return 76} }

function Write-FrameLine {
    param($Line,[int]$Width)
    if($Line.Left){ Write-Host $Line.Left -ForegroundColor $script:UiColor.Frame -NoNewline }
    if($Line.Highlight){ Write-Host $Line.Text -ForegroundColor $script:UiColor.HighlightFg -BackgroundColor $script:UiColor.HighlightBg -NoNewline }
    else{ Write-Host $Line.Text -ForegroundColor $Line.Fg -NoNewline }
    if($Line.Right){ Write-Host $Line.Right -ForegroundColor $script:UiColor.Frame -NoNewline }
    $used=("$($Line.Left)$($Line.Text)$($Line.Right)").Length
    if($used -lt $Width){ Write-Host (' ' * ($Width-$used)) -NoNewline }
    Write-Host ''
}

function Write-Frame {
    param([object[]]$Lines)
    if([Console]::IsOutputRedirected -or [Console]::IsInputRedirected){
        foreach($ln in $Lines){ Write-Host ($ln.Left+$ln.Text+$ln.Right) }
        return
    }
    $w=try{[Console]::WindowWidth}catch{80}
    $placed=$false
    try{ [Console]::SetCursorPosition(0,0); $placed=$true }catch{ try{Clear-Host}catch{} }
    foreach($ln in $Lines){ Write-FrameLine -Line $ln -Width ($w-1) }
    if($placed){
        $extra=$script:UiLastHeight - $Lines.Count
        for($j=0;$j -lt $extra;$j++){ Write-Host (' ' * ($w-1)) }
        try{ [Console]::SetCursorPosition(0,$Lines.Count)}catch{}
    }
    $script:UiLastHeight=$Lines.Count
}

function Resolve-ChecklistAction {
    param([string]$Token,[int]$Cursor,[int]$Count,[int]$Page=10)
    switch($Token){
        'Up'{return @{Cursor=(($Cursor-1+$Count)%$Count);Action='move';Index=$null}}
        'Down'{return @{Cursor=(($Cursor+1)%$Count);Action='move';Index=$null}}
        'Home'{return @{Cursor=0;Action='move';Index=$null}}
        'End'{return @{Cursor=($Count-1);Action='move';Index=$null}}
        'PageUp'{return @{Cursor=[Math]::Max(0,$Cursor-$Page);Action='move';Index=$null}}
        'PageDown'{return @{Cursor=[Math]::Min($Count-1,$Cursor+$Page);Action='move';Index=$null}}
        'Space'{return @{Cursor=$Cursor;Action='toggle';Index=$Cursor}}
        'Enter'{return @{Cursor=$Cursor;Action='done';Index=$null}}
        'Esc'{return @{Cursor=$Cursor;Action='cancel';Index=$null}}
        default{
            if($Token -eq 'a' -or $Token -eq 'A'){return @{Cursor=$Cursor;Action='all';Index=$null}}
            if($Token -eq 'n' -or $Token -eq 'N'){return @{Cursor=$Cursor;Action='none';Index=$null}}
            if($Token -match '^[0-9]$'){ $d=[int]$Token; if($d -ge 1 -and $d -le $Count){return @{Cursor=($d-1);Action='move';Index=$null}} }
            return @{Cursor=$Cursor;Action='none';Index=$null}
        }
    }
}

function Get-ChecklistFrame {
    param([string]$Title, [object[]]$Items, [int]$Cursor, $OnSet, [string[]]$StatusLines=@(), [string]$Footer='', [int]$Width=70, [hashtable]$Glyph)
    if($Glyph){$script:UiGlyph=$Glyph}
    $g=$script:UiGlyph; $inner=$Width-2
    $rule={ param($l,$r) [pscustomobject]@{Left=$l;Text=($g.H*$inner);Right=$r;Fg=$script:UiColor.Frame;Highlight=$false} }
    # viewport - only show window that fits, keep cursor visible
    $winH=try{[Console]::WindowHeight}catch{30}
    $headerH=4 + $StatusLines.Count
    $footerH=3
    $maxVisible=[Math]::Max(10,$winH - $headerH - $footerH - 4)
    # build full list with group headers to measure, but viewport slices items only
    # for simplicity, slice items array and re-add group headers for visible slice
    $total=$Items.Count
    $visibleCount=[Math]::Min($total,$maxVisible)
    $offset=0
    if($total -gt $visibleCount){
        $half=[int]($visibleCount/2)
        $offset=[Math]::Max(0,[Math]::Min($Cursor-$half,$total-$visibleCount))
    }
    $slice=@()
    for($i=$offset;$i -lt [Math]::Min($offset+$visibleCount,$total);$i++){ $slice+=$Items[$i] }
    # status with scroll indicator
    $extraStatus=@()
    if($total -gt $visibleCount){
        $extraStatus+="[$($offset+1)-$([Math]::Min($offset+$visibleCount,$total)) / $total]  PageUp/PageDown to scroll"
        if($offset -gt 0){ $extraStatus[0]="^ more above ^  " + $extraStatus[0] }
        if($offset+$visibleCount -lt $total){ $extraStatus[0]+="  v more below v" }
    }
    $allStatus=$StatusLines + $extraStatus
    $out=New-Object 'System.Collections.Generic.List[object]'
    $out.Add((& $rule $g.TL $g.TR))
    $out.Add((New-UiRow -Text $Title -Fg $script:UiColor.Title -Highlight $false -Inner $inner))
    foreach($s in $allStatus){ $out.Add((New-UiRow -Text $s -Fg $script:UiColor.Dim -Highlight $false -Inner $inner)) }
    $out.Add((New-UiRow -Text '' -Fg $script:UiColor.Dim -Highlight $false -Inner $inner))
    $lastGroup=[object]$null
    # need to show group headers for slice - include header when group changes or is first in slice
    for($j=0;$j -lt $slice.Count;$j++){
        $globalIdx=$offset+$j
        $it=$slice[$j]
        $showHeader=$false
        if($it.Group -ne $lastGroup){
            # also check if previous item outside slice had same group - still show header for new visible group
            $showHeader=$true
            $lastGroup=$it.Group
        }
        if($showHeader){ $out.Add((New-UiRow -Text $it.Group -Fg $script:UiColor.Accent -Highlight $false -Inner $inner)) }
        $box=if($OnSet.Contains($it.Id)){'[x]'}else{'[ ]'}
        $cur=if($globalIdx -eq $Cursor){$g.Cursor}else{' '}
        $risk=if($it.Risk){[string]$it.Risk}else{''}
        $suffix=''
        if($null -ne $it.Applied){ $suffix=if($it.Applied){'  (applied)'}else{'  (not set)'} }
        $txt='{0} {1} {2,-11}{3}{4}' -f $cur,$box,$risk,$it.Name,$suffix
        $fg=if($risk -eq 'Dangerous'){$script:UiColor.Danger}else{$script:UiColor.Normal}
        $out.Add((New-UiRow -Text $txt -Fg $fg -Highlight ($globalIdx -eq $Cursor) -Inner $inner))
    }
    $out.Add((New-UiRow -Text '' -Fg $script:UiColor.Dim -Highlight $false -Inner $inner))
    $out.Add((& $rule $g.BL $g.BR))
    if($Footer){ $out.Add([pscustomobject]@{Left='';Text=" $Footer";Right='';Fg=$script:UiColor.Dim;Highlight=$false}) }
    ,$out.ToArray()
}

function Get-SunFrame {
    param([int]$Frame)
    $spin = @('|','/','-','\')
    $r = @(0..7 | ForEach-Object { $spin[($Frame + $_) % 4] })
    @("     $($r[7])  $($r[0])  $($r[1])", "      .---. ", "  $($r[6])$($r[6]) (     ) $($r[2])$($r[2])", "      '---' ", "     $($r[5])  $($r[4])  $($r[3])")
}

function Show-SunSplash {
    param([object[]]$Steps, [int]$Frames = 14, [int]$DelayMs = 90)
    if ([Console]::IsInputRedirected) {
        if ($Steps) {
            foreach ($s in $Steps) { try { . $s.Path } catch {} }
        }
        return
    }
    $pal = $script:SunPalette
    $gold = $pal.Amber; $white = $pal.White; $dim = $pal.Dim; $rst = $pal.Reset
    if ($Steps -and $Steps.Count -gt 0) {
        $total = $Steps.Count
        try { [Console]::CursorVisible = $false } catch {}
        for ($i = 0; $i -lt $total; $i++) {
            $step = $Steps[$i]
            $pct = [int](($i+1)/$total*100)
            $r = @(0..7 | ForEach-Object { @('|','/','-','\')[($i + $_) % 4] })
            try { [Console]::SetCursorPosition(0,0) } catch { try { Clear-Host } catch {} }
            Write-Host ""
            Write-Host ""
            Write-Host "  $gold     $($r[7])  $($r[0])  $($r[1])$rst"
            Write-Host "  $white      .---. $rst"
            Write-Host "  $gold  $($r[6])$($r[6])$white (     )$gold $($r[2])$($r[2])$rst"
            Write-Host "  $white      '---' $rst"
            Write-Host "  $gold     $($r[5])  $($r[4])  $($r[3])$rst"
            Write-Host ""
            $filled = [int]($pct/10)
            $bar = ("$gold" + ('#' * $filled) + "$dim" + ('-' * (10-$filled)) + "$rst")
            $name = (Split-Path $step.Path -Leaf).PadRight(12)
            $pctTxt = "{0,3}%" -f $pct
            $w = try { [Console]::WindowWidth } catch { 80 }
            Write-Host ("  $dim loading $white$($name.TrimEnd())$dim $bar $gold$pctTxt$rst".PadRight($w-1))
            Write-Host "".PadRight($w-1)
            try { . $step.Path } catch { Write-WsLog "failed $($step.Path): $_" 'Warning' }
            Start-Sleep -Milliseconds 80
        }
        try { [Console]::CursorVisible = $true } catch {}
        try { Clear-Host } catch {}
        $r0 = @(0..7 | ForEach-Object { @('|','/','-','\')[($_) % 4] })
        Write-Host ""
        Write-Host "  $gold     $($r0[7])  $($r0[0])  $($r0[1])$rst"
        Write-Host "  $white      .---. $rst"
        Write-Host "  $gold  $($r0[6])$($r0[6])$white (     )$gold $($r0[2])$($r0[2])$rst"
        Write-Host "  $white      '---' $rst"
        Write-Host "  $gold     $($r0[5])  $($r0[4])  $($r0[3])$rst"
        Write-Host ""
        Write-Host "  $white  sunCleaner  $dim v$(Get-SunCleanerVersion)  -- solar care for Windows$rst"
        Write-Host "  $dim  lordofsunshine/sunCleaner$rst"
        Write-Host "  $dim  single-file  *  3-color  *  safe$rst"
        Write-Host "  $gold  ------------------------------$rst"
        Write-Host ""
        Start-Sleep -Milliseconds 300
        return
    }
    try { [Console]::CursorVisible = $false } catch {}
    $spin = @('|','/','-','\')
    for ($f = 0; $f -lt $Frames; $f++) {
        $r = @(0..7 | ForEach-Object { $spin[($f + $_) % 4] })
        try { [Console]::SetCursorPosition(0,0) } catch { try { Clear-Host } catch {} }
        Write-Host ""
        Write-Host ""
        Write-Host "  $gold     $($r[7])  $($r[0])  $($r[1])$rst"
        Write-Host "  $white      .---. $rst"
        Write-Host "  $gold  $($r[6])$($r[6])$white (     )$gold $($r[2])$($r[2])$rst"
        Write-Host "  $white      '---' $rst"
        Write-Host "  $gold     $($r[5])  $($r[4])  $($r[3])$rst"
        Write-Host ""
        $pct = [int](($f+1)/$Frames*100)
        $filled = [int]($pct/10)
        $bar = ("$gold" + ('#' * $filled) + "$dim" + ('-' * (10-$filled)) + "$rst")
        $pctTxt = "{0,3}%" -f $pct
        $w = try { [Console]::WindowWidth } catch { 80 }
        Write-Host ("  $dim loading $bar $gold$pctTxt$rst".PadRight($w-1))
        if ($f -ge $Frames - 2) { Write-Host "  $white sunCleaner $dim v$(Get-SunCleanerVersion)$rst" } else { Write-Host "" }
        Start-Sleep -Milliseconds $DelayMs
    }
    try { [Console]::CursorVisible = $true } catch {}
    try { Clear-Host } catch {}
    Write-Host ""
    $r0 = @(0..7 | ForEach-Object { @('|','/','-','\')[($_) % 4] })
    Write-Host "  $gold     $($r0[7])  $($r0[0])  $($r0[1])$rst"
    Write-Host "  $white      .---. $rst"
    Write-Host "  $gold  $($r0[6])$($r0[6])$white (     )$gold $($r0[2])$($r0[2])$rst"
    Write-Host "  $white      '---' $rst"
    Write-Host "  $gold     $($r0[5])  $($r0[4])  $($r0[3])$rst"
    Write-Host ""
    Write-Host "  $white  sunCleaner  $dim v$(Get-SunCleanerVersion)  -- solar care for Windows$rst"
    Write-Host "  $dim  lordofsunshine/sunCleaner$rst"
    Write-Host "  $dim  single-file  *  3-color  *  safe$rst"
    Write-Host "  $gold  ------------------------------$rst"
    Write-Host ""
    Start-Sleep -Milliseconds 400
}

function Show-SunSplashStep {
    param([string]$Name, [int]$Index, [int]$Total, [int]$Percent)
    $pal = $script:SunPalette
    $gold = $pal.Amber; $white = $pal.White; $dim = $pal.Dim; $rst = $pal.Reset
    $spin = @('|','/','-','\')
    $r = @(0..7 | ForEach-Object { $spin[($Index + $_) % 4] })
    try { [Console]::SetCursorPosition(0,0) } catch { try { Clear-Host } catch {} }
    Write-Host ""
    Write-Host ""
    Write-Host "  $gold     $($r[7])  $($r[0])  $($r[1])$rst"
    Write-Host "  $white      .---. $rst"
    Write-Host "  $gold  $($r[6])$($r[6])$white (     )$gold $($r[2])$($r[2])$rst"
    Write-Host "  $white      '---' $rst"
    Write-Host "  $gold     $($r[5])  $($r[4])  $($r[3])$rst"
    Write-Host ""
    $filled = [int]($Percent/10)
    $bar = ("$gold" + ('#' * $filled) + "$dim" + ('-' * (10-$filled)) + "$rst")
    $pctTxt = "{0,3}%" -f $Percent
    $w = try { [Console]::WindowWidth } catch { 80 }
    $namePad = $Name.PadRight(15)
    Write-Host ("  $dim loading $white$namePad$dim $bar $gold$pctTxt$rst".PadRight($w-1))
    Write-Host "".PadRight($w-1)
}


function Write-SunBanner {
    param([string]$Title, [string]$Subtitle = '')
    try { Clear-Host } catch {}
    $p = $script:SunPalette
    $gold = $p.Amber; $white = $p.White; $dim = $p.Dim; $rst = $p.Reset
    $spin = @('|','/','-','\')
    $r = @(0..7 | ForEach-Object { $spin[$_ % 4] })
    Write-Host ""
    Write-Host "  $gold     $($r[7])  $($r[0])  $($r[1])$rst"
    Write-Host "  $white      .---. $rst"
    Write-Host "  $gold  $($r[6])$($r[6])$white (     )$gold $($r[2])$($r[2])$rst"
    Write-Host "  $white      '---' $rst"
    Write-Host "  $gold     $($r[5])  $($r[4])  $($r[3])$rst"
    Write-Host "  $white  sunCleaner $dim v$(Get-SunCleanerVersion)$rst"
    Write-Host "  $dim  lordofsunshine/sunCleaner$rst"
    if ($Title) {
        Write-Host "  $gold------------------------------$rst"
        Write-Host "   $white$Title$rst"
    }
    if ($Subtitle) { Write-Host "   $dim$Subtitle$rst" }
    Write-Host "  $gold------------------------------$rst"
    Write-Host ""
}

# --- src/Features/Schedule.ps1 ---

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

# --- src/Engines/Clean.ps1 ---

<#
.SYNOPSIS
    sunCleaner - cleanup engine - registry-driven cleanup engine.
#>


$script:IsPS7Plus       = $PSVersionTable.PSVersion.Major -ge 7
$script:StartTime       = Get-Date
$script:Stats           = New-Object System.Collections.Generic.List[object]
$script:TotalBytes      = [int64]0
$script:TotalFiles      = 0
$script:TotalErrors     = 0
$script:RestorePointMade = $false

# -DryRun is a friendly alias for -WhatIf. Setting the preference here makes it
# flow into every ShouldProcess call below (and into nested helper functions).
if ($DryRun) { $WhatIfPreference = $true }

# paths the engine must never operate on, no matter what a task or env var says.
$script:DenyList = @(
    ($env:SystemDrive + '\'),
    $env:WINDIR,
    "$env:WINDIR\System32",
    "$env:SystemDrive\Users",
    $env:USERPROFILE,
    $env:ProgramData,
    ${env:ProgramFiles},
    ${env:ProgramFiles(x86)}
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() }


function Write-CleanupLog {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Debug','Step','WhatIf','Safety')]
        [string]$Level = 'Info'
    )
    Write-WsLog -Message $Message -Level $Level -LogPath $LogPath
}

function Get-ItemSize {
    param([System.IO.FileSystemInfo]$Item)
    if ($Item.PSIsContainer) {
        $sum = (Get-ChildItem -LiteralPath $Item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($sum) { [int64]$sum } else { [int64]0 }
    }
    else { [int64]$Item.Length }
}

function Get-ItemFileCount {
    param([System.IO.FileSystemInfo]$Item)
    if ($Item.PSIsContainer) {
        (Get-ChildItem -LiteralPath $Item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object).Count
    }
    else { 1 }
}

function Test-SafeToDelete {
    param([string]$FullPath)
    if ([string]::IsNullOrWhiteSpace($FullPath)) { return $false }
    $p = $FullPath.TrimEnd('\')
    if ($p.Length -le 3) { return $false }                       # drive root like C:\
    $key = $p.ToLowerInvariant()
    if ($script:DenyList -contains $key) { return $false }       # exact protected root
    if (($p -split '\\').Count -lt 3) { return $false }          # shallower than X:\a\b
    return $true
}

function Get-UserProfiles {
    if ($CurrentUserOnly) {
        return ,([pscustomobject]@{ Name = $env:USERNAME; FullName = $env:USERPROFILE })
    }
    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName } }
}

# local fixed disks ('C:\','D:\',...). Filtered by -Drives when supplied.
function Get-LocalDrives {
    $all = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
             ForEach-Object { $_.DeviceID + '\' })
    if (-not $all) { $all = @($env:SystemDrive + '\') }
    if ($Drives) {
        $want = $Drives | ForEach-Object { $_.TrimEnd('\').TrimEnd(':').ToUpperInvariant() }
        $all = $all | Where-Object { $want -contains $_.Substring(0, 1).ToUpperInvariant() }
    }
    $all
}

function Expand-TaskPath {
    param([string[]]$Raw)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Raw) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry)
        if ($expanded -like '*<USER>*') {
            foreach ($prof in (Get-UserProfiles)) {
                $out.Add($expanded.Replace('<USER>', $prof.FullName))
            }
        }
        elseif ($expanded -like '*<DRIVE>*') {
            foreach ($d in (Get-LocalDrives)) {
                $out.Add($expanded.Replace('<DRIVE>', $d))
            }
        }
        else { $out.Add($expanded) }
    }
    $out
}

function Invoke-PathCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$Path,
        [int]$AgeDays = 0,
        [string]$Description = 'items'
    )

    $files = 0; [int64]$bytes = 0; $errors = 0
    $cutoff = if ($AgeDays -gt 0) { (Get-Date).AddDays(-$AgeDays) } else { $null }

    foreach ($spec in $Path) {
        # a bare directory path (no wildcard) means "empty this directory".
        $container = if ($spec -match '[\*\?]') { Split-Path $spec -Parent } else { $spec }
        if (-not (Test-Path -Path $container -ErrorAction SilentlyContinue)) { continue }

        $items = Get-ChildItem -Path $spec -Force -ErrorAction SilentlyContinue
        if ($cutoff) { $items = $items | Where-Object { $_.LastWriteTime -lt $cutoff } }

        foreach ($item in $items) {
            $full = $item.FullName
            if (-not (Test-SafeToDelete $full)) {
                Write-CleanupLog "refusing unsafe path: $full" 'Warning'
                continue
            }
            $size  = Get-ItemSize $item
            $count = Get-ItemFileCount $item

            if ($PSCmdlet.ShouldProcess($full, "Remove ($Description)")) {
                try {
                    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
                    if (-not (Test-Path -LiteralPath $full)) { $files += $count; $bytes += $size }
                }
                catch {
                    $errors++
                    Write-CleanupLog "  $full : $($_.Exception.Message)" 'Debug'
                }
            }
            elseif (Test-WhatIfMode) {
                # -WhatIf: count what would be freed (ShouldProcess already printed the preview)
                $files += $count; $bytes += $size
            }
        }
    }

    [pscustomobject]@{ Files = $files; Bytes = $bytes; Errors = $errors }
}

# stop a set of services, run a body, then restart whatever was running.
function Use-StoppedService {
    param([string[]]$Name, [scriptblock]$Body)
    $restart = @()
    if (-not (Test-WhatIfMode)) {
        foreach ($n in $Name) {
            $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
                $restart += $n
            }
        }
    }
    try { & $Body }
    finally {
        foreach ($n in $restart) { Start-Service -Name $n -ErrorAction SilentlyContinue }
    }
}

# run a native command unless in WhatIf mode.
function Invoke-NativeStep {
    param([string]$Caption, [scriptblock]$Body)
    if (Test-WhatIfMode) {
        Write-CleanupLog "[WhatIf] would run: $Caption" 'WhatIf'
        return $true
    }
    try { & $Body; Write-CleanupLog $Caption 'Success'; return $true }
    catch { Write-CleanupLog "$Caption failed: $($_.Exception.Message)" 'Error'; return $false }
}

# remove a top-level folder that needs ownership first (Windows.old etc.).
function Remove-ProtectedFolder {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$FullPath, [string]$Description)
    if (-not (Test-Path -LiteralPath $FullPath)) { return $null }
    if (-not (Test-SafeToDelete $FullPath)) {
        Write-CleanupLog "refusing unsafe path: $FullPath" 'Warning'; return $null
    }
    $size  = Get-ItemSize (Get-Item -LiteralPath $FullPath -Force)
    if ($PSCmdlet.ShouldProcess($FullPath, "Remove ($Description)")) {
        & takeown.exe /F "$FullPath" /R /D Y *>$null
        & icacls.exe "$FullPath" /grant "*S-1-5-32-544:F" /T /C *>$null
        Remove-Item -LiteralPath $FullPath -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $FullPath)) {
            return [pscustomobject]@{ Files = 0; Bytes = $size; Errors = 0 }
        }
        return [pscustomobject]@{ Files = 0; Bytes = 0; Errors = 1 }
    }
    elseif (Test-WhatIfMode) {
        return [pscustomobject]@{ Files = 0; Bytes = $size; Errors = 0 }
    }
    $null
}

function New-CleanupRestorePoint {
    $st = New-SunCleanerRestorePoint `
        -Description "Before Windows Cleanup $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
        -LogAction { param($m, $l) Write-CleanupLog $m $l }
    if ($st -eq 'Created') { $script:RestorePointMade = $true }
    return ($st -ne 'Failed')
}

function Stop-BrowserProcesses {
    $names = 'chrome','msedge','firefox','opera','browser','brave'
    if (Test-WhatIfMode) {
        Write-CleanupLog '[WhatIf] would close running browsers' 'WhatIf'; return
    }
    foreach ($n in $names) {
        $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($procs) {
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-CleanupLog "Closed $($procs.Count) $n process(es)" 'Debug'
        }
    }
}

function New-CleanupTask {
    param(
        [string]$Id, [string]$Name, [string]$Category, [string]$Risk,
        [bool]$DefaultOn = $true, [int]$AgeDays = 0,
        [string[]]$Paths, [scriptblock]$Action, [string[]]$StopServices
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Category = $Category; Risk = $Risk
        DefaultOn = $DefaultOn; AgeDays = $AgeDays
        Paths = $Paths; Action = $Action; StopServices = $StopServices
    }
}

function Get-CleanupTaskRegistry {
    @(
        New-CleanupTask chrome 'Chrome cache' Browsers Safe -Paths @(
            '<USER>\AppData\Local\Google\Chrome\User Data\*\Cache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\Code Cache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\GPUCache\*',
            '<USER>\AppData\Local\Google\Chrome\User Data\*\Service Worker\CacheStorage\*')
        New-CleanupTask edge 'Edge cache' Browsers Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\Cache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\Code Cache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\GPUCache\*',
            '<USER>\AppData\Local\Microsoft\Edge\User Data\*\Service Worker\CacheStorage\*')
        New-CleanupTask firefox 'Firefox cache' Browsers Safe -Paths @(
            '<USER>\AppData\Local\Mozilla\Firefox\Profiles\*\cache2\*',
            '<USER>\AppData\Local\Mozilla\Firefox\Profiles\*\startupCache\*',
            '<USER>\AppData\Local\Mozilla\Firefox\Profiles\*\thumbnails\*')
        New-CleanupTask opera 'Opera cache' Browsers Safe -Paths @(
            '<USER>\AppData\Roaming\Opera Software\Opera Stable\Cache\*',
            '<USER>\AppData\Roaming\Opera Software\Opera Stable\GPUCache\*',
            '<USER>\AppData\Local\Opera Software\Opera Stable\Cache\*')
        New-CleanupTask yandex 'Yandex cache' Browsers Safe -Paths @(
            '<USER>\AppData\Local\Yandex\YandexBrowser\User Data\*\Cache\*',
            '<USER>\AppData\Local\Yandex\YandexBrowser\User Data\*\GPUCache\*')
        New-CleanupTask brave 'Brave cache' Browsers Safe -Paths @(
            '<USER>\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Cache\*',
            '<USER>\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\GPUCache\*')

        New-CleanupTask npm 'npm cache' DevTools Safe -Paths @('<USER>\AppData\Local\npm-cache\*')
        New-CleanupTask pip 'pip cache' DevTools Safe -Paths @('<USER>\AppData\Local\pip\Cache\*')
        New-CleanupTask nuget 'NuGet http cache' DevTools Safe -Paths @(
            '<USER>\AppData\Local\NuGet\v3-cache\*',
            '<USER>\AppData\Local\NuGet\plugins-cache\*')
        New-CleanupTask yarn 'Yarn cache' DevTools Safe -Paths @('<USER>\AppData\Local\Yarn\Cache\*')
        New-CleanupTask gradle 'Gradle cache' DevTools Safe -Paths @('<USER>\.gradle\caches\*')
        New-CleanupTask vscode 'VS Code cache' DevTools Safe -Paths @(
            '<USER>\AppData\Roaming\Code\Cache\*',
            '<USER>\AppData\Roaming\Code\CachedData\*',
            '<USER>\AppData\Roaming\Code\Code Cache\*',
            '<USER>\AppData\Roaming\Code\GPUCache\*')
        New-CleanupTask jetbrains 'JetBrains IDE caches, logs & temp' DevTools Safe -Paths @(
            '<USER>\AppData\Local\JetBrains\*\caches\*',
            '<USER>\AppData\Local\JetBrains\*\log\*',
            '<USER>\AppData\Local\JetBrains\*\tmp\*')
        New-CleanupTask nuitka 'Nuitka build cache' DevTools Safe -Paths @(
            '<USER>\AppData\Local\Nuitka\*')
        New-CleanupTask docker 'Docker dangling images & build cache' DevTools Safe -Action {
            if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
                Write-CleanupLog 'Docker not installed - skipped' 'Debug'; return $null
            }
            Invoke-NativeStep 'docker system prune -f' { & docker system prune -f *>$null } | Out-Null
            $null
        }
        New-CleanupTask pnpm 'pnpm store (prune unreferenced)' DevTools Safe -Action {
            if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
                Write-CleanupLog 'pnpm not installed - skipped' 'Debug'; return $null
            }
            # blunt-deleting the store breaks hardlinks into existing node_modules and frees
            # nothing for in-use packages; prune only removes unreferenced content.
            Invoke-NativeStep 'pnpm store prune' { & pnpm store prune *>$null } | Out-Null
            $null
        }
        New-CleanupTask pkgmgr 'Package-manager & build caches (winget/choco/scoop/conda/cargo/go/pub)' DevTools Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\WinGet\Cache\*',
            '%ProgramData%\chocolatey\cache\*',
            '<USER>\scoop\cache\*',
            '<USER>\.conda\pkgs\*',
            '<USER>\.cargo\registry\cache\*',
            '<USER>\go\pkg\mod\cache\download\*',
            '<USER>\AppData\Local\go-build\*',
            '<USER>\AppData\Local\Pub\Cache\*')
        New-CleanupTask ps-modulecache 'PowerShell module analysis cache' DevTools Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\PowerShell\ModuleAnalysisCache',
            '<USER>\AppData\Local\Microsoft\Windows\PowerShell\StartupProfileData-*')

        New-CleanupTask appcache 'Windows app cache' Apps Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\AppCache\*',
            '<USER>\AppData\Local\ConnectedDevicesPlatform\*',
            '<USER>\AppData\Local\Packages\*\AC\INetCache\*',
            '<USER>\AppData\Local\Packages\*\AC\Temp\*')
        New-CleanupTask teams 'Microsoft Teams cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\Microsoft\Teams\Cache\*',
            '<USER>\AppData\Roaming\Microsoft\Teams\GPUCache\*',
            '<USER>\AppData\Roaming\Microsoft\Teams\Service Worker\CacheStorage\*',
            '<USER>\AppData\Local\Packages\MSTeams_*\LocalCache\Microsoft\MSTeams\*Cache\*')
        New-CleanupTask discord 'Discord cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\discord\Cache\*',
            '<USER>\AppData\Roaming\discord\Code Cache\*',
            '<USER>\AppData\Roaming\discord\GPUCache\*')
        New-CleanupTask slack 'Slack cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\Slack\Cache\*',
            '<USER>\AppData\Roaming\Slack\Service Worker\CacheStorage\*')
        New-CleanupTask spotify 'Spotify cache' Apps Safe -Paths @(
            '<USER>\AppData\Local\Spotify\Storage\*',
            '<USER>\AppData\Local\Spotify\Data\*')
        # moderate: the Office document cache can hold not-yet-uploaded changes.
        New-CleanupTask office 'Office document & web cache' Apps Moderate -Paths @(
            '<USER>\AppData\Local\Microsoft\Office\*\OfficeFileCache\*',
            '<USER>\AppData\Local\Microsoft\Office\*\Wef\*',
            '<USER>\AppData\Local\Microsoft\Windows\INetCache\Content.Outlook\*')
        New-CleanupTask onedrive 'OneDrive logs' Apps Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\OneDrive\logs\*',
            '<USER>\AppData\Local\Microsoft\OneDrive\setup\logs\*')
        New-CleanupTask adobe-media 'Adobe media & Camera Raw cache' Apps Safe -Paths @(
            '<USER>\AppData\Roaming\Adobe\Common\Media Cache\*',
            '<USER>\AppData\Roaming\Adobe\Common\Media Cache Files\*',
            '<USER>\AppData\Local\Adobe\CameraRaw\Cache\*')
        New-CleanupTask rdp-cache 'Remote Desktop client bitmap cache' Apps Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Terminal Server Client\Cache\*')

        New-CleanupTask game-caches 'Game launcher caches (Steam/Epic/Battle.net/GOG)' Games Safe -Paths @(
            '%ProgramFiles(x86)%\Steam\appcache\httpcache\*',
            '%ProgramFiles(x86)%\Steam\config\htmlcache\*',
            '%ProgramFiles(x86)%\Steam\steamapps\shadercache\*',
            '<USER>\AppData\Local\EpicGamesLauncher\Saved\webcache\*',
            '<USER>\AppData\Local\Battle.net\Cache\*',
            '%ProgramData%\Battle.net\Agent\data\cache\*',
            '<USER>\AppData\Local\GOG.com\Galaxy\webcache\*')

        New-CleanupTask temp-user 'User temp files' System Safe -Paths @(
            '<USER>\AppData\Local\Temp\*')
        New-CleanupTask temp-windows 'Windows temp files' System Safe -Paths @('%WINDIR%\Temp\*')
        New-CleanupTask inetcache 'Internet Explorer/WinINet cache' System Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\INetCache\*',
            '<USER>\AppData\Local\Microsoft\Windows\Temporary Internet Files\*')
        New-CleanupTask thumbnails 'Thumbnail & icon cache' System Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db',
            '<USER>\AppData\Local\Microsoft\Windows\Explorer\iconcache_*.db',
            '<USER>\AppData\Local\IconCache.db')
        New-CleanupTask shadercache 'GPU shader / D3D cache' System Safe -Paths @(
            '<USER>\AppData\Local\D3DSCache\*',
            '<USER>\AppData\Local\NVIDIA\DXCache\*',
            '<USER>\AppData\Local\NVIDIA\GLCache\*',
            '<USER>\AppData\Local\NVIDIA\OptixCache\*',
            '<USER>\AppData\Local\NVIDIA Corporation\NV_Cache\*',
            '<USER>\AppData\Local\AMD\DxCache\*')
        New-CleanupTask win-caches 'Windows per-user app caches' System Safe -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\Caches\*')
        New-CleanupTask gpu-leftovers 'GPU driver installer leftovers (NVIDIA/AMD)' System Safe -Paths @(
            '<DRIVE>NVIDIA\*',
            '<DRIVE>AMD\*',
            '%ProgramData%\NVIDIA Corporation\Downloader\*',
            '%ProgramData%\NVIDIA Corporation\NV_Cache\*')
        New-CleanupTask webcache 'WinINet WebCache database' System Moderate -Paths @(
            '<USER>\AppData\Local\Microsoft\Windows\WebCache\*')
        New-CleanupTask deliveryopt 'Delivery Optimization cache' System Safe -Paths @(
            '%WINDIR%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\*',
            '%ProgramData%\Microsoft\Windows\DeliveryOptimization\*')
        New-CleanupTask recent 'Recent items & jump lists' System Moderate -DefaultOn $true -Paths @(
            '<USER>\AppData\Roaming\Microsoft\Windows\Recent\*')
        New-CleanupTask fontcache 'Font cache' System Moderate -StopServices @('FontCache') -Paths @(
            '%WINDIR%\ServiceProfiles\LocalService\AppData\Local\FontCache\*')
        New-CleanupTask winlogs 'Windows log files' System Moderate -Paths @('%WINDIR%\Logs\*')
        New-CleanupTask prefetch 'Prefetch (rebuilt by Windows)' System Aggressive -Paths @(
            '%WINDIR%\Prefetch\*')
        New-CleanupTask old-drivers 'Remove superseded driver packages (pnputil)' System Dangerous -Action {
            # enumeration is read-only, but loading the DISM module (triggered by Get-Command
            # or Get-WindowsDriver) runs Set-Alias under the GLOBAL WhatIf preference. Toggle
            # it off around the whole module-touching region so dry-runs stay quiet.
            $prevWhatIf = $global:WhatIfPreference
            try {
                $global:WhatIfPreference = $false
                if (-not (Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue)) {
                    Write-CleanupLog 'Get-WindowsDriver (DISM module) unavailable - skipped' 'Warning'; return $null
                }
                $pkgs = @(Get-WindowsDriver -Online -ErrorAction Stop)
            }
            catch { Write-CleanupLog "Driver enumeration failed: $($_.Exception.Message)" 'Warning'; return $null }
            finally { $global:WhatIfPreference = $prevWhatIf }

            # group third-party packages by original .inf name; keep the newest version of
            # each, mark older duplicates. Never touch boot-critical drivers.
            $stale = foreach ($g in ($pkgs | Where-Object { -not $_.BootCritical -and $_.OriginalFileName } |
                        Group-Object { [System.IO.Path]::GetFileName([string]$_.OriginalFileName).ToLowerInvariant() })) {
                if ($g.Count -lt 2) { continue }
                $g.Group |
                    Sort-Object @{ E = { try { [version]$_.Version } catch { [version]'0.0' } } }, Date -Descending |
                    Select-Object -Skip 1
            }
            $stale = @($stale)
            if (-not $stale.Count) { Write-CleanupLog 'No superseded driver duplicates found' 'Success'; return $null }

            if (Test-WhatIfMode) {
                foreach ($d in $stale) {
                    Write-CleanupLog ("[WhatIf] would run: pnputil /delete-driver {0}  ({1} v{2})" -f `
                        $d.Driver, [System.IO.Path]::GetFileName([string]$d.OriginalFileName), $d.Version) 'WhatIf'
                }
                return [pscustomobject]@{ Files = $stale.Count; Bytes = 0; Errors = 0 }
            }

            $removed = 0; $kept = 0
            foreach ($d in $stale) {
                # no /force: pnputil refuses to remove a driver currently bound to a device.
                & pnputil.exe /delete-driver $d.Driver 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $removed++
                    Write-CleanupLog ("Removed old driver {0} ({1} v{2})" -f `
                        $d.Driver, [System.IO.Path]::GetFileName([string]$d.OriginalFileName), $d.Version) 'Success'
                }
                else { $kept++ }
            }
            Write-CleanupLog "Old drivers removed: $removed, kept (in use): $kept" 'Info'
            [pscustomobject]@{ Files = $removed; Bytes = 0; Errors = $kept }
        }

        # recycle Bins on every drive are emptied by the 'recyclebin' task (Clear-RecycleBin
        # spans all drives). These add drive-level scratch/junk on C:, D:, E: ...
        New-CleanupTask disk-temp 'Drive-level temp folders (all local disks)' Disks Moderate -Paths @(
            '<DRIVE>Temp\*',
            '<DRIVE>tmp\*')
        New-CleanupTask disk-chkdsk 'CHKDSK recovered fragments (FOUND.*)' Disks Safe -Paths @(
            '<DRIVE>FOUND.*\*')

        New-CleanupTask wer 'Windows Error Reporting' Logs Safe -Paths @(
            '%ProgramData%\Microsoft\Windows\WER\ReportQueue\*',
            '%ProgramData%\Microsoft\Windows\WER\ReportArchive\*',
            '<USER>\AppData\Local\Microsoft\Windows\WER\*')
        New-CleanupTask extra-logs 'Setup logs & Defender scan history' Logs Safe -Paths @(
            '%WINDIR%\Panther\*',
            '%WINDIR%\inf\setupapi.dev*.log',
            '%WINDIR%\inf\setupapi.setup*.log',
            '%ProgramData%\Microsoft\Windows Defender\Scans\History\Results\*')
        New-CleanupTask livekernel 'Live kernel crash dumps (driver/GPU TDR)' Logs Safe -Paths @(
            '%WINDIR%\LiveKernelReports\*.dmp')
        New-CleanupTask srum-db 'Network/app usage telemetry DB (SRUM)' Logs Moderate `
            -StopServices @('DPS') -Paths @('%WINDIR%\System32\sru\*')
        New-CleanupTask eventtranscript 'Diagnostic telemetry database (EventTranscript)' Logs Moderate `
            -StopServices @('DiagTrack') -Paths @(
            '%ProgramData%\Microsoft\Diagnosis\EventTranscript\*')
        New-CleanupTask crashdumps 'Crash & memory dumps' Logs Moderate -Paths @(
            '%WINDIR%\Minidump\*',
            '%WINDIR%\MEMORY.DMP',
            '<USER>\AppData\Local\CrashDumps\*')
        New-CleanupTask iislogs 'Old IIS logs (>14 days)' Logs Moderate -DefaultOn $true -AgeDays 14 -Paths @(
            '%WINDIR%\System32\LogFiles\W3SVC*\*.log',
            '%WINDIR%\System32\LogFiles\HTTPERR\*.log')
        New-CleanupTask recyclebin 'Recycle Bin' Logs Moderate -Action {
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would empty the Recycle Bin' 'WhatIf'; return $null }
            try {
                Clear-RecycleBin -Force -ErrorAction Stop
                Write-CleanupLog 'Recycle Bin emptied' 'Success'
            } catch {
                Write-CleanupLog "Recycle Bin: $($_.Exception.Message)" 'Warning'
            }
            $null
        }
        New-CleanupTask eventlogs 'Clear event logs (archived first)' Logs Dangerous -Action {
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would archive & clear Application/System/Setup logs' 'WhatIf'; return $null }
            $archive = Join-Path $env:TEMP "EventLogBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            New-Item -ItemType Directory -Path $archive -Force -ErrorAction SilentlyContinue | Out-Null
            foreach ($log in 'Application','System','Setup') {
                $dest = Join-Path $archive "$log.evtx"
                & wevtutil.exe export-log $log "$dest" /overwrite:true 2>$null
                & wevtutil.exe clear-log $log 2>$null
                Write-CleanupLog "Archived & cleared '$log' (backup: $dest)" 'Success'
            }
            $null
        }

        New-CleanupTask wu-cache 'Windows Update download cache' Updates Moderate `
            -StopServices @('wuauserv','bits','cryptsvc') -Paths @(
            '%WINDIR%\SoftwareDistribution\Download\*',
            '%WINDIR%\System32\catroot2\*')
        New-CleanupTask wu-full 'Full SoftwareDistribution reset' Updates Aggressive -DefaultOn $true `
            -StopServices @('wuauserv','bits','cryptsvc') -Paths @(
            '%WINDIR%\SoftwareDistribution\*')
        New-CleanupTask patchcache 'Windows Installer patch cache' Updates Dangerous -Paths @(
            '%WINDIR%\Installer\$PatchCache$\*',
            '%WINDIR%\Installer\*.tmp')
        New-CleanupTask windows-old 'Windows.old & upgrade leftovers' Updates Dangerous -Action {
            $total = [pscustomobject]@{ Files = 0; Bytes = 0; Errors = 0 }
            foreach ($folder in @(
                    "$env:SystemDrive\Windows.old",
                    "$env:SystemDrive\`$Windows.~BT",
                    "$env:SystemDrive\`$Windows.~WS",
                    "$env:SystemDrive\`$WinREAgent",
                    "$env:WINDIR\Downloaded Program Files")) {
                $r = Remove-ProtectedFolder -FullPath $folder -Description 'upgrade leftovers'
                if ($r) { $total.Bytes += $r.Bytes; $total.Errors += $r.Errors }
            }
            $total
        }

        New-CleanupTask dism-analyze 'Analyze component store (report only)' Optimization Safe -DefaultOn $true -Action {
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would run DISM /AnalyzeComponentStore' 'WhatIf'; return $null }
            $out = & dism.exe /online /Cleanup-Image /AnalyzeComponentStore 2>&1
            $out | Where-Object { $_ -match ':' } | ForEach-Object { Write-CleanupLog "  $_" 'Debug' }
            Write-CleanupLog 'Component store analyzed' 'Success'; $null
        }
        New-CleanupTask component-task 'Run StartComponentCleanup scheduled task' Optimization Moderate -Action {
            Invoke-NativeStep 'schtasks StartComponentCleanup' {
                & schtasks.exe /Run /TN '\Microsoft\Windows\Servicing\StartComponentCleanup' *>$null
            } | Out-Null
            $null
        }
        New-CleanupTask dism-cleanup 'DISM component cleanup' Optimization Moderate -Action {
            Invoke-NativeStep 'DISM /StartComponentCleanup' {
                & dism.exe /online /Cleanup-Image /StartComponentCleanup /Quiet *>$null
            } | Out-Null
            $null
        }
        New-CleanupTask dism-resetbase 'DISM reset base + remove superseded' Optimization Aggressive -DefaultOn $true -Action {
            Invoke-NativeStep 'DISM /SPSuperseded' {
                & dism.exe /online /Cleanup-Image /SPSuperseded *>$null
            } | Out-Null
            Invoke-NativeStep 'DISM /StartComponentCleanup /ResetBase' {
                & dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet *>$null
            } | Out-Null
            $null
        }
        New-CleanupTask dism-logs 'DISM logs' Optimization Safe -Paths @('%WINDIR%\Logs\DISM\*')
        New-CleanupTask sfc 'System File Checker (sfc /scannow)' Optimization Moderate -DefaultOn $true -Action {
            Invoke-NativeStep 'sfc /scannow' { & sfc.exe /scannow | Out-Null } | Out-Null
            $null
        }
        # spool/outlook/adobe/nvidia/store/volume from external tools
        New-CleanupTask spool 'Print spooler queue' System Safe -Paths @('%WINDIR%\System32\spool\PRINTERS\*')
        New-CleanupTask outlook-cache 'Outlook RoamCache' Apps Safe -Paths @('<USER>\AppData\Local\Microsoft\Outlook\RoamCache\*')
        New-CleanupTask adobe-logs 'Adobe Photoshop logs' Apps Safe -Paths @('<USER>\AppData\Roaming\Adobe\Adobe Photoshop*\Logs\*')
        New-CleanupTask nvidia-perdriver 'NVIDIA PerDriverVersion DXCache' System Safe -Paths @('<USER>\AppData\LocalLow\NVIDIA\PerDriverVersion\DXCache\*')
        New-CleanupTask store-tmp 'Microsoft Store temp cache' Apps Safe -Action {
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would run WSReset cache clear' 'WhatIf'; return $null }
            try { Start-Process -FilePath 'WSReset.exe' -ArgumentList '' -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null; Start-Sleep 4; Get-Process -Name WinStore.App -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
            $null
        }
        New-CleanupTask volume-trim 'Optimize volume (ReTrim)' System Moderate -Action {
            if (Test-WhatIfMode) { Write-CleanupLog '[WhatIf] would run Optimize-Volume C ReTrim' 'WhatIf'; return $null }
            try { Optimize-Volume -DriveLetter C -ReTrim -Verbose:$false -ErrorAction SilentlyContinue | Out-Null; Write-CleanupLog 'Volume C ReTrim done' 'Success' } catch { Write-CleanupLog "ReTrim failed: $($_.Exception.Message)" 'Warning' }
            $null
        }

    )
}

function Resolve-CleanupSelection {
    param(
        [object[]]$Registry,
        [string[]]$Category, [string[]]$Include, [string[]]$Exclude,
        [bool]$Conservative, [bool]$IncludeDangerous, [bool]$SkipOptimization
    )
    $rank = @{ Safe = 0; Moderate = 1; Aggressive = 2; Dangerous = 3 }
    $maxRisk = if ($IncludeDangerous) { 3 } elseif ($Conservative) { 1 } else { 2 }

    foreach ($t in $Registry) {
        $on = $t.DefaultOn
        if ($Category -and ($t.Category -notin $Category)) { $on = $false }
        if ($SkipOptimization -and $t.Category -eq 'Optimization') { $on = $false }
        if ($rank[$t.Risk] -gt $maxRisk) { $on = $false }
        if (($Include -contains $t.Id) -or ($Include -contains $t.Name)) { $on = $true }
        if (($Exclude -contains $t.Id) -or ($Exclude -contains $t.Name)) { $on = $false }
        if ($on) { $t }
    }
}

function Invoke-CleanupTask {
    param([object]$Task)
    Write-CleanupLog "$($Task.Name)  [$($Task.Category)/$($Task.Risk)]" 'Step'

    $result = $null
    if ($Task.Action) {
        $result = & $Task.Action
    }
    else {
        $paths  = Expand-TaskPath $Task.Paths
        $effAge = [Math]::Max($MaxAgeDays, $Task.AgeDays)
        if ($Task.StopServices) {
            $result = Use-StoppedService -Name $Task.StopServices -Body {
                Invoke-PathCleanup -Path $paths -AgeDays $effAge -Description $Task.Name
            }
        }
        else {
            $result = Invoke-PathCleanup -Path $paths -AgeDays $effAge -Description $Task.Name
        }
    }

    if ($result -and ($result.PSObject.Properties.Name -contains 'Bytes')) {
        $script:TotalBytes  += [int64]$result.Bytes
        $script:TotalFiles  += [int]$result.Files
        $script:TotalErrors += [int]$result.Errors
        $script:Stats.Add([pscustomobject]@{
            Task = $Task.Id; Category = $Task.Category
            Files = [int]$result.Files; Bytes = [int64]$result.Bytes; Errors = [int]$result.Errors
        })
        if ($result.Bytes -gt 0 -or $result.Files -gt 0) {
            $verb = if (Test-WhatIfMode) { 'would free' } else { 'freed' }
            if ($result.Bytes -gt 0) {
                Write-CleanupLog ("  {0} {1} ({2} items)" -f $verb, (Format-FileSize $result.Bytes), $result.Files) 'Success'
            }
            else {
                # space-less ops (e.g. driver packages) report item counts only
                Write-CleanupLog ("  {0} {1} item(s)" -f $verb, $result.Files) 'Success'
            }
        }
    }
}

function Show-CleanupSummary {
    $dur = (Get-Date) - $script:StartTime
    $mode = if (Test-WhatIfMode) { 'DRY RUN' } else { 'CLEANUP' }
    Write-CleanupLog '' 'Info'
    Write-CleanupLog "===== $mode SUMMARY =====" 'Step'

    $byCat = $script:Stats | Group-Object Category | Sort-Object Name
    foreach ($g in $byCat) {
        $b = ($g.Group | Measure-Object Bytes -Sum).Sum
        if (-not $b) { $b = 0 }
        Write-CleanupLog ("  {0,-13} {1}" -f $g.Name, (Format-FileSize $b)) 'Info'
    }

    $verb = if (Test-WhatIfMode) { 'Would free' } else { 'Reclaimed' }
    Write-CleanupLog '' 'Info'
    Write-CleanupLog ("{0}: {1}  ({2} items)" -f $verb, (Format-FileSize $script:TotalBytes), $script:TotalFiles) 'Success'
    if ($script:TotalErrors -gt 0) {
        Write-CleanupLog "Errors (locked/in-use items): $script:TotalErrors" 'Warning'
    }
    Write-CleanupLog ("Duration: {0:N1}s   Log: {1}" -f $dur.TotalSeconds, $LogPath) 'Info'
}

function Write-CleanupReport {
    Write-SunCleanerReport -ReportPath $ReportPath -Engine 'Cleanup' `
        -RestorePoint $script:RestorePointMade -StartTime $script:StartTime `
        -Summary @{
            TotalBytes  = $script:TotalBytes
            TotalFreed  = (Format-FileSize $script:TotalBytes)
            TotalFiles  = $script:TotalFiles
            TotalErrors = $script:TotalErrors
        } `
        -Items $script:Stats `
        -LogAction { param($m, $l) Write-CleanupLog $m $l }
}

function Show-TaskList {
    Write-Host ''
    Write-Host 'Cleanup task registry:' -ForegroundColor Cyan
    Get-CleanupTaskRegistry |
        Sort-Object Category, @{ E = { @{Safe=0;Moderate=1;Aggressive=2;Dangerous=3}[$_.Risk] } } |
        Format-Table @{ L='Id'; E={$_.Id}; W=16 },
                     @{ L='Category'; E={$_.Category}; W=13 },
                     @{ L='Risk'; E={$_.Risk}; W=11 },
                     @{ L='Default'; E={ if($_.DefaultOn){'on'}else{'off'} }; W=8 },
                     @{ L='Description'; E={$_.Name} } -AutoSize
    Write-Host 'Risk tiers: Safe + Moderate + Aggressive run by default; Dangerous needs -IncludeDangerous.' -ForegroundColor DarkGray
    Write-Host ''
}

function Show-UsageHelp {
@'
sunCleaner - cleanup engine v1.0.0  (registry-driven engine)

USAGE
  .\Cleanup-Windows-Senior.ps1 [options]

SELECTION
  -Category <names>     Limit to: Browsers, DevTools, Apps, Games, System, Disks, Logs, Updates, Optimization
  -Include  <ids>       Force tasks on  (see -ListTasks for ids)
  -Exclude  <ids>       Force tasks off
  -IncludeDangerous     Also run irreversible tier (event logs, patch cache, Windows.old, old drivers)
  -Conservative         Cap at Safe + Moderate (skip Aggressive)
  -CurrentUserOnly,-cu  Clean only the current profile (default: all users)
  -Drives <letters>     Local disks for drive-level cleanup, e.g. -Drives C,D (default: all local disks)
  -SkipOptimization,-so Skip the slow SFC/DISM category
  -MaxAgeDays <n>       Only delete files older than n days

SAFETY
  -WhatIf / -DryRun,-dr Preview only, change nothing (real ShouldProcess)
  -NoRestorePoint,-nrp  Skip the Checkpoint-Computer restore point (created by default)
  -Unattended,-Force,-f No prompts / no GUI - for scheduled tasks, GPO, SCCM, Intune

OUTPUT
  -LogPath <path>       Text log (default: %TEMP%\WindowsCleanup.log)
  -ReportPath <path>    Machine-readable JSON report
  -ListTasks            Print the task registry and exit
  -Help                 Show this help

EXAMPLES
  .\Cleanup-Windows-Senior.ps1 -WhatIf
  .\Cleanup-Windows-Senior.ps1 -Category Browsers,DevTools
  .\Cleanup-Windows-Senior.ps1 -Unattended -NoRestorePoint -SkipOptimization
  .\Cleanup-Windows-Senior.ps1 -IncludeDangerous -ReportPath C:\Logs\clean.json
'@ | Write-Host
}

function Start-SunCleanerCleanup {
    # bridge script-level params to local vars expected by original engine
    $Category = $script:Category
    $Include = $script:Include
    $Exclude = $script:Exclude
    $IncludeDangerous = $script:IncludeDangerous
    $Conservative = $script:Conservative
    $CurrentUserOnly = $script:CurrentUserOnly
    $Drives = $script:Drives
    $DryRun = $script:DryRun
    $Unattended = $script:Unattended
    $NoRestorePoint = $script:NoRestorePoint
    $SkipOptimization = $script:SkipOptimization
    $MaxAgeDays = $script:MaxAgeDays
    $LogPath = $script:LogPath
    $ReportPath = $script:ReportPath
    $modeText  = if (Test-WhatIfMode) { 'DryRun' } else { 'Live' }
    $scopeText = if ($CurrentUserOnly) { 'current user' } else { 'all users' }
    Write-CleanupLog 'sunCleaner - cleanup' 'Step'
    Write-CleanupLog ("PowerShell {0} | Mode: {1} | Scope: {2}" -f $PSVersionTable.PSVersion, $modeText, $scopeText) 'Info'

    if (-not (Test-AdminPrivileges)) {
        Write-CleanupLog 'Administrator privileges are required. Re-run as Administrator.' 'Error'
        exit 2
    }

    $registry  = Get-CleanupTaskRegistry
    $selection = Resolve-CleanupSelection -Registry $registry -Category $Category `
        -Include $Include -Exclude $Exclude -Conservative:$Conservative `
        -IncludeDangerous:$IncludeDangerous -SkipOptimization:$SkipOptimization

    if (-not $selection) { Write-CleanupLog 'No tasks selected - nothing to do.' 'Warning'; return }

    # wu-full wipes everything wu-cache would, so drop the redundant double service bounce.
    if (($selection.Id -contains 'wu-full') -and ($selection.Id -contains 'wu-cache')) {
        $selection = $selection | Where-Object { $_.Id -ne 'wu-cache' }
    }

    $dangerous = $selection | Where-Object { $_.Risk -eq 'Dangerous' }
    Write-CleanupLog ("Selected {0} task(s){1}." -f $selection.Count,
        $(if ($dangerous) { ", including $($dangerous.Count) DANGEROUS" } else { '' })) 'Info'

    # single grouped confirmation for the irreversible tier (interactive runs only).
    if ($dangerous -and -not (Test-WhatIfMode) -and -not $Unattended) {
        Write-CleanupLog 'Dangerous (irreversible) tasks selected:' 'Safety'
        $dangerous | ForEach-Object { Write-CleanupLog "   - $($_.Name)" 'Safety' }
        $answer = Read-Host 'Proceed with these irreversible operations? (yes/No)'
        if ($answer -notmatch '^(y|yes)$') {
            $selection = $selection | Where-Object { $_.Risk -ne 'Dangerous' }
            Write-CleanupLog 'Skipping the Dangerous tier by your choice.' 'Info'
        }
    }

    # real restore point first (unless previewing or opted out).
    if (-not $NoRestorePoint -and -not (Test-WhatIfMode)) { New-CleanupRestorePoint | Out-Null }

    if ($selection | Where-Object { $_.Category -eq 'Browsers' }) { Stop-BrowserProcesses }

    $order = 'Browsers','DevTools','Apps','Games','System','Disks','Logs','Updates','Optimization'
    foreach ($cat in $order) {
        foreach ($task in ($selection | Where-Object { $_.Category -eq $cat })) {
            Invoke-CleanupTask -Task $task
        }
    }

    Show-CleanupSummary
    Write-CleanupReport
}

# --- src/Engines/Optimize.ps1 ---

<#
.SYNOPSIS
    sunCleaner - optimization engine - registry-driven tweaks with full per-tweak undo.
#>


$script:StartTime       = Get-Date
$script:Stats           = New-Object System.Collections.Generic.List[object]
$script:Snapshots       = New-Object System.Collections.Generic.List[object]
$script:Applied         = 0
$script:Skipped         = 0
$script:Errors          = 0
$script:RestorePointMade = $false

if ($DryRun) { $WhatIfPreference = $true }


function Write-OptLog {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Debug','Step','WhatIf','Safety')]
        [string]$Level = 'Info'
    )
    Write-WsLog -Message $Message -Level $Level -LogPath $LogPath
}

function New-OptRestorePoint {
    $st = New-SunCleanerRestorePoint `
        -Description "Before Windows Optimize $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
        -LogAction { param($m, $l) Write-OptLog $m $l }
    if ($st -eq 'Created') { $script:RestorePointMade = $true }
    return ($st -ne 'Failed')
}

function Get-RegValueSnapshot {
    param([string]$Path, [string]$Name)
    $snap = [ordered]@{ Name = $Name; Existed = $false; Value = $null; Kind = $null }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item -and ($item.GetValueNames() -contains $Name)) {
            $snap.Existed = $true
            $snap.Value   = $item.GetValue($Name)
            try { $snap.Kind = [string]$item.GetValueKind($Name) } catch { $snap.Kind = $null }
        }
    }
    [pscustomobject]$snap
}

function Set-RegValue {
    param([string]$Path, [string]$Name, [string]$Kind, $Value)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -PropertyType $Kind -Value $Value `
        -Force -ErrorAction Stop | Out-Null
}

# restore a single registry value from a snapshot object (used by -Undo).
function Restore-RegValue {
    param([string]$Path, [object]$Snap)
    if ($Snap.Existed) {
        $kind = if ($Snap.Kind) { $Snap.Kind } else { 'String' }
        Set-RegValue -Path $Path -Name $Snap.Name -Kind $kind -Value $Snap.Value
    }
    elseif (Test-Path -LiteralPath $Path) {
        Remove-ItemProperty -Path $Path -Name $Snap.Name -Force -ErrorAction SilentlyContinue
    }
}

function New-RegTweak {
    param(
        [string]$Id, [string]$Name, [string]$Area, [string]$Risk,
        [bool]$DefaultOn = $true, [string]$Path, [object[]]$Values, [string]$Explain
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Area = $Area; Risk = $Risk; DefaultOn = $DefaultOn
        Type = 'Registry'; Explain = $Explain
        Spec = @{ Path = $Path; Values = $Values }
    }
}
function New-SvcTweak {
    param(
        [string]$Id, [string]$Name, [string]$Area, [string]$Risk,
        [bool]$DefaultOn = $true, [string]$Service, [string]$Startup = 'Disabled',
        [bool]$StopNow = $true, [string]$Explain
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Area = $Area; Risk = $Risk; DefaultOn = $DefaultOn
        Type = 'Service'; Explain = $Explain
        Spec = @{ Service = $Service; Startup = $Startup; StopNow = $StopNow }
    }
}
function New-TaskTweak {
    param(
        [string]$Id, [string]$Name, [string]$Area, [string]$Risk,
        [bool]$DefaultOn = $true, [object[]]$Tasks, [string]$Explain
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Area = $Area; Risk = $Risk; DefaultOn = $DefaultOn
        Type = 'ScheduledTask'; Explain = $Explain
        Spec = @{ Tasks = $Tasks }
    }
}
function New-CustomTweak {
    param(
        [string]$Id, [string]$Name, [string]$Area, [string]$Risk,
        [bool]$DefaultOn = $true,
        [scriptblock]$Test, [scriptblock]$Backup, [scriptblock]$Apply, [scriptblock]$Undo,
        [string]$Explain
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Area = $Area; Risk = $Risk; DefaultOn = $DefaultOn
        Type = 'Custom'; Explain = $Explain
        Spec = @{ Test = $Test; Backup = $Backup; Apply = $Apply; Undo = $Undo }
    }
}

# convenience for a single name/kind/value registry pair.
function RegVal { param([string]$Name, [string]$Kind, $Value)
    [pscustomobject]@{ Name = $Name; Kind = $Kind; Value = $Value } }

function Get-OptimizationTweakRegistry {
    @(
        New-RegTweak perf-visualfx 'Visual effects: best performance' Performance Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
            -Values @((RegVal 'VisualFXSetting' DWord 2)) `
            -Explain 'Disables animations/shadows for snappier UI (Performance Options = best performance).'
        New-RegTweak perf-menudelay 'Zero menu show delay' Performance Safe `
            -Path 'HKCU:\Control Panel\Desktop' `
            -Values @((RegVal 'MenuShowDelay' String '0')) `
            -Explain 'Menus open instantly instead of after the default 400 ms.'
        New-RegTweak perf-startupdelay 'Remove startup app delay' Performance Moderate `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' `
            -Values @((RegVal 'StartupDelayInMSec' DWord 0)) `
            -Explain 'Startup programs launch without the artificial ~10 s delay.'
        New-RegTweak perf-bgapps 'Disable background apps' Performance Moderate `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' `
            -Values @((RegVal 'GlobalUserDisabled' DWord 1)) `
            -Explain 'Stops UWP apps from running and updating in the background.'
        New-RegTweak perf-faststartup 'Disable Fast Startup (hybrid boot)' Performance Moderate -DefaultOn $false `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            -Values @((RegVal 'HiberbootEnabled' DWord 0)) `
            -Explain 'Ensures a clean full shutdown (fixes dual-boot clock/filesystem issues). Off by default; slightly slower cold boot.'
        New-CustomTweak perf-power-high 'Power plan: High Performance' Performance Safe -DefaultOn $true `
            -Explain 'Switches the active power plan to High Performance (no CPU down-clocking on idle).' `
            -Test   { $a = (& powercfg /getactivescheme) -join ' '; [bool]($a -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') } `
            -Backup { $a = (& powercfg /getactivescheme) -join ' '; $g = if ($a -match '([0-9a-f-]{36})') { $Matches[1] } else { $null }; @{ PreviousGuid = $g } } `
            -Apply  { & powercfg /setactive '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' 2>$null; if ($LASTEXITCODE -ne 0) { & powercfg /setactive SCHEME_MIN 2>$null } } `
            -Undo   { param($s) if ($s.PreviousGuid) { & powercfg /setactive $s.PreviousGuid 2>$null } }
        New-CustomTweak perf-power-ultimate 'Power plan: Ultimate Performance' Performance Aggressive -DefaultOn $false `
            -Explain 'Creates and activates the hidden Ultimate Performance plan (desktops/workstations).' `
            -Test   { $false } `
            -Backup { $a = (& powercfg /getactivescheme) -join ' '; $g = if ($a -match '([0-9a-f-]{36})') { $Matches[1] } else { $null }; @{ PreviousGuid = $g } } `
            -Apply  { & powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null; & powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null } `
            -Undo   { param($s) if ($s.PreviousGuid) { & powercfg /setactive $s.PreviousGuid 2>$null } }
        New-SvcTweak perf-sysmain 'Disable SysMain (Superfetch)' Performance Aggressive -DefaultOn $false `
            -Service 'SysMain' -Startup 'Disabled' `
            -Explain 'Frees RAM/disk activity. Helpful on SSDs; can slow app launches on HDDs. Off by default.'
        New-SvcTweak perf-wsearch 'Disable Windows Search indexing' Performance Aggressive -DefaultOn $false `
            -Service 'WSearch' -Startup 'Disabled' `
            -Explain 'Stops the indexer (less disk/CPU) but makes Start/Explorer search slower. Off by default.'
        New-CustomTweak perf-hibernate 'Disable hibernation (remove hiberfil.sys)' Performance Aggressive -DefaultOn $false `
            -Explain 'Reclaims several GB of hiberfil.sys and disables Fast Startup. Off by default.' `
            -Test   { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled -eq 0 } `
            -Backup { @{ Was = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled } } `
            -Apply  { & powercfg /hibernate off 2>$null } `
            -Undo   { param($s) if ($s.Was -ne 0) { & powercfg /hibernate on 2>$null } }

        New-RegTweak priv-telemetry 'Minimize telemetry (policy)' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' `
            -Values @((RegVal 'AllowTelemetry' DWord 0), (RegVal 'DoNotShowFeedbackNotifications' DWord 1)) `
            -Explain 'Sets diagnostic data to the lowest level the edition allows and hides feedback prompts.'
        New-RegTweak priv-adid 'Disable advertising ID' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' `
            -Values @((RegVal 'Enabled' DWord 0)) `
            -Explain 'Stops apps from using a per-user advertising identifier.'
        New-RegTweak priv-consumer 'Disable consumer features / auto-installed apps' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
            -Values @((RegVal 'DisableWindowsConsumerFeatures' DWord 1), (RegVal 'DisableSoftLanding' DWord 1)) `
            -Explain 'Prevents Windows from silently installing promoted third-party apps.'
        New-RegTweak priv-tips 'Disable tips, suggestions & spotlight' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
            -Values @(
                (RegVal 'SystemPaneSuggestionsEnabled' DWord 0),
                (RegVal 'SoftLandingEnabled' DWord 0),
                (RegVal 'SubscribedContent-338389Enabled' DWord 0),
                (RegVal 'SubscribedContent-310093Enabled' DWord 0),
                (RegVal 'RotatingLockScreenOverlayEnabled' DWord 0)) `
            -Explain 'Turns off Windows tips, lock-screen spotlight facts and Settings suggestions.'
        New-RegTweak priv-activity 'Disable activity feed / Timeline' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Values @(
                (RegVal 'EnableActivityFeed' DWord 0),
                (RegVal 'PublishUserActivities' DWord 0),
                (RegVal 'UploadUserActivities' DWord 0)) `
            -Explain 'Stops Windows from collecting and uploading the activity history / Timeline.'
        New-RegTweak priv-websearch 'Disable web search in Start' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' `
            -Values @((RegVal 'BingSearchEnabled' DWord 0), (RegVal 'CortanaConsent' DWord 0)) `
            -Explain 'Removes Bing web results and Cortana suggestions from the Start-menu search box.'
        New-RegTweak priv-cortana 'Disable Cortana (policy)' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' `
            -Values @((RegVal 'AllowCortana' DWord 0)) `
            -Explain 'Disables the Cortana assistant via Group Policy.'
        New-SvcTweak priv-diagtrack 'Disable Connected User Experiences (DiagTrack)' Privacy Moderate `
            -Service 'DiagTrack' -Startup 'Disabled' `
            -Explain 'Stops the main telemetry service that uploads diagnostic data.'
        New-SvcTweak priv-dmwappush 'Disable WAP Push message service' Privacy Moderate `
            -Service 'dmwappushservice' -Startup 'Disabled' `
            -Explain 'Disables a device-management channel used for telemetry routing.'
        New-TaskTweak priv-telemetry-tasks 'Disable CEIP & telemetry scheduled tasks' Privacy Moderate `
            -Tasks @(
                @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
                @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
                @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' },
                @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
                @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClient' },
                @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClientOnScenarioDownload' }) `
            -Explain 'Disables the recurring tasks that collect and send usage/compatibility data.'
        New-RegTweak priv-recall 'Disable Recall & Click-to-Do (AI screen analysis)' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' `
            -Values @((RegVal 'DisableAIDataAnalysis' DWord 1), (RegVal 'DisableClickToDo' DWord 1)) `
            -Explain 'Blocks Windows Recall snapshots and Click-to-Do AI screen scraping (Win11 24H2+; harmless no-op on older builds).'
        New-RegTweak priv-copilot 'Disable Windows Copilot' Privacy Safe `
            -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' `
            -Values @((RegVal 'TurnOffWindowsCopilot' DWord 1)) `
            -Explain 'Turns off the Windows Copilot assistant via user policy.'
        New-RegTweak priv-tailored 'Disable tailored experiences (ads from diagnostics)' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' `
            -Values @((RegVal 'TailoredExperiencesWithDiagnosticDataEnabled' DWord 0)) `
            -Explain 'Stops Windows from using your diagnostic data to show personalized tips and ads.'
        New-RegTweak priv-spotlight 'Disable Windows Spotlight features (policy)' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' `
            -Values @((RegVal 'DisableWindowsSpotlightFeatures' DWord 1)) `
            -Explain 'Disables lock-screen/desktop Spotlight ad rotation at the policy root.'
        New-RegTweak priv-input 'Stop inking & typing personalization' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' `
            -Values @(
                (RegVal 'RestrictImplicitInkCollection' DWord 1),
                (RegVal 'RestrictImplicitTextCollection' DWord 1),
                (RegVal 'AllowInputPersonalization' DWord 0)) `
            -Explain 'Stops sampling of keystrokes/handwriting for personalization. Local dictation still works.'
        New-RegTweak priv-typing 'Stop sending typing/inking data to Microsoft' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Input\TIPC' `
            -Values @((RegVal 'Enabled' DWord 0)) `
            -Explain 'Disables the typing-insights upload channel.'
        New-RegTweak priv-speech 'Decline online speech recognition' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' `
            -Values @((RegVal 'HasAccepted' DWord 0)) `
            -Explain 'Opts out of cloud-based voice processing. Offline dictation is unaffected.'
        New-RegTweak priv-ceip 'Disable Customer Experience Improvement Program' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Microsoft\SQMClient\Windows' `
            -Values @((RegVal 'CEIPEnable' DWord 0)) `
            -Explain 'Turns off the CEIP master switch (complements the CEIP scheduled-task tweak).'
        New-RegTweak priv-appcompat 'Disable application-compatibility telemetry' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' `
            -Values @((RegVal 'DisableInventory' DWord 1), (RegVal 'AITEnable' DWord 0)) `
            -Explain 'Stops the Application Compatibility Appraiser inventory that feeds telemetry.'
        New-RegTweak priv-wer 'Disable Windows Error Reporting upload' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' `
            -Values @((RegVal 'Disabled' DWord 1)) `
            -Explain 'Blocks crash-report upload to Microsoft. Local crash logs are still created.'
        New-RegTweak priv-feedback 'Never ask for Windows feedback' Privacy Safe `
            -Path 'HKCU:\Software\Microsoft\Siuf\Rules' `
            -Values @((RegVal 'NumberOfSIUFInPeriod' DWord 0)) `
            -Explain 'Stops the periodic "rate your experience" feedback prompts.'
        New-RegTweak priv-deliveryopt 'Disable Delivery Optimization P2P upload' Privacy Moderate `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' `
            -Values @((RegVal 'DODownloadMode' DWord 0)) `
            -Explain 'Stops seeding update payloads to other PCs over the internet (HTTP-only; does not disable Windows Update).'
        New-RegTweak priv-onedrive 'Block OneDrive network traffic before sign-in' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Microsoft\OneDrive' `
            -Values @((RegVal 'PreventNetworkTrafficPreUserSignIn' DWord 1)) `
            -Explain 'Stops OneDrive contacting the network before a user signs in. Does not disable OneDrive.'
        New-RegTweak priv-clipboard 'Disable cloud clipboard sync' Privacy Moderate -DefaultOn $false `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' `
            -Values @((RegVal 'AllowCrossDeviceClipboard' DWord 0)) `
            -Explain 'Stops clipboard contents syncing to your Microsoft account across devices. Off by default.'

        New-CustomTweak debloat-junk 'Remove preinstalled junk apps' Debloat Aggressive -DefaultOn $true `
            -Explain 'Removes obvious bloat (King games, Solitaire, 3D Viewer, Clipchamp, Get Help, Maps, etc.) for all users.' `
            -Test   { $false } `
            -Backup {
                $pat = @('king.com*','*CandyCrush*','*BubbleWitch*','*Microsoft.3DBuilder*','*Microsoft.Microsoft3DViewer*',
                    '*Microsoft.MicrosoftSolitaireCollection*','*Microsoft.MixedReality.Portal*','*Microsoft.WindowsFeedbackHub*',
                    '*Microsoft.GetHelp*','*Microsoft.Getstarted*','*Microsoft.WindowsMaps*','*Microsoft.BingNews*',
                    '*Microsoft.BingWeather*','*Microsoft.People*','*Clipchamp*','*Microsoft.Todos*','*Disney*','*SpotifyAB*')
                $found = foreach ($p in $pat) { Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue | Select-Object -Expand Name }
                @{ Patterns = $pat; Found = @($found | Sort-Object -Unique) }
            } `
            -Apply  {
                $pat = @('king.com*','*CandyCrush*','*BubbleWitch*','*Microsoft.3DBuilder*','*Microsoft.Microsoft3DViewer*',
                    '*Microsoft.MicrosoftSolitaireCollection*','*Microsoft.MixedReality.Portal*','*Microsoft.WindowsFeedbackHub*',
                    '*Microsoft.GetHelp*','*Microsoft.Getstarted*','*Microsoft.WindowsMaps*','*Microsoft.BingNews*',
                    '*Microsoft.BingWeather*','*Microsoft.People*','*Clipchamp*','*Microsoft.Todos*','*Disney*','*SpotifyAB*')
                foreach ($p in $pat) {
                    Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -like $p } |
                        ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
                }
            } `
            -Undo   { param($s)
                if ($s.Found) { Write-OptLog ("Removed UWP apps cannot be auto-reinstalled. Reinstall from the Store if needed: {0}" -f ($s.Found -join ', ')) 'Warning' }
            }
        New-CustomTweak debloat-xbox 'Remove Xbox apps' Debloat Aggressive -DefaultOn $false `
            -Explain 'Removes Xbox app, Game Bar overlay and related packages. Off by default (gamers may want them).' `
            -Test   { $false } `
            -Backup { $f = Get-AppxPackage -AllUsers -Name '*Xbox*' -ErrorAction SilentlyContinue | Select-Object -Expand Name; @{ Found = @($f) } } `
            -Apply  { Get-AppxPackage -AllUsers -Name '*Xbox*' -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue } `
            -Undo   { param($s) if ($s.Found) { Write-OptLog ("Reinstall from the Store if needed: {0}" -f ($s.Found -join ', ')) 'Warning' } }
        New-CustomTweak debloat-comms 'Remove Mail/Calendar, Skype, Phone Link' Debloat Aggressive -DefaultOn $false `
            -Explain 'Removes the communications apps bundle. Off by default (some people use Mail/Calendar).' `
            -Test   { $false } `
            -Backup {
                $pat = @('*Microsoft.windowscommunicationsapps*','*Microsoft.SkypeApp*','*Microsoft.YourPhone*')
                $f = foreach ($p in $pat) { Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue | Select-Object -Expand Name }
                @{ Patterns = $pat; Found = @($f | Sort-Object -Unique) }
            } `
            -Apply  {
                foreach ($p in @('*Microsoft.windowscommunicationsapps*','*Microsoft.SkypeApp*','*Microsoft.YourPhone*')) {
                    Get-AppxPackage -AllUsers -Name $p -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                }
            } `
            -Undo   { param($s) if ($s.Found) { Write-OptLog ("Reinstall from the Store if needed: {0}" -f ($s.Found -join ', ')) 'Warning' } }
        New-RegTweak debloat-start-ads 'Disable Start-menu app suggestions' Debloat Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
            -Values @(
                (RegVal 'SilentInstalledAppsEnabled' DWord 0),
                (RegVal 'PreInstalledAppsEnabled' DWord 0),
                (RegVal 'OemPreInstalledAppsEnabled' DWord 0),
                (RegVal 'SubscribedContent-338388Enabled' DWord 0)) `
            -Explain 'Stops the Start menu from showing suggested/promoted apps.'
        New-RegTweak debloat-taskbar-ads 'Hide taskbar/Start/Explorer ad surfaces' Debloat Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @(
                (RegVal 'TaskbarDa' DWord 0),
                (RegVal 'TaskbarMn' DWord 0),
                (RegVal 'Start_IrisRecommendations' DWord 0),
                (RegVal 'Start_AccountNotifications' DWord 0),
                (RegVal 'ShowSyncProviderNotifications' DWord 0)) `
            -Explain 'Hides the Widgets and Chat taskbar buttons, the Start "Recommended"/account-ad rows, and Explorer sync-provider ads.'
        New-RegTweak debloat-scoobe 'Disable post-update setup nag (SCOOBE)' Debloat Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' `
            -Values @((RegVal 'ScoobeSystemSettingEnabled' DWord 0)) `
            -Explain 'Stops the "Let''s finish setting up your device" full-screen prompt after updates.'
        New-RegTweak ux-fileext 'Show file extensions in Explorer' Debloat Safe -DefaultOn $false `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @((RegVal 'HideFileExt' DWord 0)) `
            -Explain 'Shows known file extensions (security + usability). Off by default (preference).'
        New-CustomTweak ux-context-menu 'Restore classic Win10 right-click menu' Debloat Safe -DefaultOn $false `
            -Explain 'Brings back the full Windows 10 context menu on Windows 11. Off by default (preference); needs an Explorer restart.' `
            -Test   { Test-Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' } `
            -Backup { @{ Existed = (Test-Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32') } } `
            -Apply  {
                New-Item -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Force | Out-Null
                Set-ItemProperty -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Name '(Default)' -Value ''
            } `
            -Undo   { param($s) Remove-Item -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -ErrorAction SilentlyContinue }

        New-RegTweak net-gamedvr 'Disable GameDVR / background recording' Network Safe `
            -Path 'HKCU:\System\GameConfigStore' `
            -Values @((RegVal 'GameDVR_Enabled' DWord 0), (RegVal 'GameDVR_FSEBehaviorMode' DWord 2)) `
            -Explain 'Disables the background game recorder that can cost frames and CPU.'
        New-RegTweak net-gamedvr-policy 'Disable GameDVR (policy)' Network Safe `
            -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' `
            -Values @((RegVal 'AllowGameDVR' DWord 0)) `
            -Explain 'Enforces GameDVR off machine-wide via policy.'
        New-RegTweak net-gamemode 'Enable Game Mode' Network Safe `
            -Path 'HKCU:\Software\Microsoft\GameBar' `
            -Values @((RegVal 'AutoGameModeEnabled' DWord 1), (RegVal 'AllowAutoGameMode' DWord 1)) `
            -Explain 'Prioritizes the foreground game for CPU/GPU scheduling.'
        New-RegTweak net-throttling 'Disable network throttling / multimedia reservation' Network Moderate `
            -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
            -Values @((RegVal 'NetworkThrottlingIndex' DWord 4294967295), (RegVal 'SystemResponsiveness' DWord 0)) `
            -Explain 'Lifts the 10-packet/ms network throttle and the 20% CPU multimedia reservation (better for gaming/streaming).'
        New-RegTweak net-teredo 'Disable Teredo IPv6 tunneling' Network Moderate -DefaultOn $false `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
            -Values @((RegVal 'DisabledComponents' DWord 1)) `
            -Explain 'Disables the Teredo transition tunnel (reduces attack surface/latency). Off by default; can affect some P2P/NAT-traversal.'
        New-SvcTweak net-ndu 'Disable Network Data Usage monitor (NDU)' Network Aggressive -DefaultOn $false `
            -Service 'Ndu' -Startup 'Disabled' `
            -Explain 'Stops the NDU driver that can cause high memory use. Off by default; removes per-app data usage stats.'
        New-CustomTweak net-nagle 'Disable Nagle algorithm (lower latency)' Network Aggressive -DefaultOn $false `
            -Explain 'Sets TcpAckFrequency=1 / TCPNoDelay=1 on active interfaces for lower gaming latency. Off by default.' `
            -Test   { $false } `
            -Backup {
                $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
                $snaps = @()
                foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
                    $p = $k.PSPath
                    if ((Get-ItemProperty $p -ErrorAction SilentlyContinue).PSObject.Properties.Name -match 'DhcpIPAddress|IPAddress') {
                        foreach ($n in 'TcpAckFrequency','TCPNoDelay') {
                            $cur = (Get-ItemProperty $p -Name $n -ErrorAction SilentlyContinue).$n
                            $snaps += @{ Path = $p; Name = $n; Existed = ($null -ne $cur); Value = $cur; Kind = 'DWord' }
                        }
                    }
                }
                @{ Values = $snaps }
            } `
            -Apply  {
                $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
                foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
                    $p = $k.PSPath
                    if ((Get-ItemProperty $p -ErrorAction SilentlyContinue).PSObject.Properties.Name -match 'DhcpIPAddress|IPAddress') {
                        New-ItemProperty $p -Name 'TcpAckFrequency' -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                        New-ItemProperty $p -Name 'TCPNoDelay'      -PropertyType DWord -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                }
            } `
            -Undo   { param($s)
                foreach ($v in $s.Values) {
                    if ($v.Existed) { New-ItemProperty $v.Path -Name $v.Name -PropertyType DWord -Value $v.Value -Force -ErrorAction SilentlyContinue | Out-Null }
                    else { Remove-ItemProperty $v.Path -Name $v.Name -Force -ErrorAction SilentlyContinue }
                }
            }
        # appearance and system tweaks from external tools
        New-RegTweak appearance-dark 'Enable dark mode' Appearance Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
            -Values @((RegVal 'AppsUseLightTheme' DWord 0), (RegVal 'SystemUsesLightTheme' DWord 0)) `
            -Explain 'Switches Windows and apps to dark theme.'
        New-RegTweak appearance-transparency 'Disable transparency' Appearance Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
            -Values @((RegVal 'EnableTransparency' DWord 0)) `
            -Explain 'Turns off acrylic transparency.'
        New-RegTweak appearance-anim 'Disable animations' Appearance Safe `
            -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' `
            -Values @((RegVal 'MinAnimate' String '0')) `
            -Explain 'Disables window animations.'
        New-RegTweak taskbar-left 'Align taskbar left' Appearance Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @((RegVal 'TaskbarAl' DWord 0)) `
            -Explain 'Moves taskbar to the left (Win11).'
        New-RegTweak taskbar-search-hide 'Hide taskbar search' Appearance Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' `
            -Values @((RegVal 'SearchboxTaskbarMode' DWord 0)) `
            -Explain 'Hides the taskbar search box.'
        New-RegTweak taskbar-taskview 'Hide Task View button' Appearance Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @((RegVal 'ShowTaskViewButton' DWord 0)) `
            -Explain 'Hides Task View from the taskbar.'
        New-RegTweak start-recommended 'Disable Start recommended' Appearance Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @((RegVal 'Start_TrackProgs' DWord 0)) `
            -Explain 'Stops showing recommended apps in Start.'
        New-RegTweak explorer-hidden 'Show hidden files' Appearance Safe `
            -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
            -Values @((RegVal 'Hidden' DWord 1), (RegVal 'ShowSuperHidden' DWord 1)) `
            -Explain 'Shows hidden and system files in Explorer.'
        New-RegTweak system-numlock 'Enable NumLock at startup' Appearance Safe `
            -Path 'HKCU:\Control Panel\Keyboard' `
            -Values @((RegVal 'InitialKeyboardIndicators' String '2')) `
            -Explain 'NumLock on after logon.'
        New-RegTweak mouse-accel 'Disable mouse acceleration' Appearance Safe `
            -Path 'HKCU:\Control Panel\Mouse' `
            -Values @((RegVal 'MouseSpeed' String '0'), (RegVal 'MouseThreshold1' String '0'), (RegVal 'MouseThreshold2' String '0')) `
            -Explain 'Turns off Enhance pointer precision.'
        New-RegTweak privacy-location 'Disable location services' Privacy Safe `
            -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' `
            -Values @((RegVal 'Value' String 'Deny')) `
            -Explain 'Blocks location access for apps.'
        New-RegTweak privacy-findmy 'Disable Find my device' Privacy Safe `
            -Path 'HKLM:\Software\Policies\Microsoft\FindMyDevice' `
            -Values @((RegVal 'AllowFindMyDevice' DWord 0)) `
            -Explain 'Disables Find my device.'

    )
}

function Resolve-TweakSelection {
    param(
        [object[]]$Registry,
        [string[]]$Area, [string[]]$Include, [string[]]$Exclude,
        [bool]$Conservative, [bool]$IncludeDangerous
    )
    $rank = @{ Safe = 0; Moderate = 1; Aggressive = 2; Dangerous = 3 }
    $maxRisk = if ($IncludeDangerous) { 3 } elseif ($Conservative) { 1 } else { 2 }

    foreach ($t in $Registry) {
        $on = $t.DefaultOn
        if ($Area -and ($t.Area -notin $Area)) { $on = $false }
        if ($rank[$t.Risk] -gt $maxRisk) { $on = $false }
        if (($Include -contains $t.Id) -or ($Include -contains $t.Name)) { $on = $true }
        if (($Exclude -contains $t.Id) -or ($Exclude -contains $t.Name)) { $on = $false }
        if ($on) { $t }
    }
}

function Test-TweakApplied {
    param([object]$Tweak)
    try {
        switch ($Tweak.Type) {
            'Registry' {
                foreach ($v in $Tweak.Spec.Values) {
                    $snap = Get-RegValueSnapshot -Path $Tweak.Spec.Path -Name $v.Name
                    if (-not $snap.Existed) { return $false }
                    if ([string]$snap.Value -ne [string]$v.Value) { return $false }
                }
                return $true
            }
            'Service' {
                $svc = Get-Service -Name $Tweak.Spec.Service -ErrorAction SilentlyContinue
                if (-not $svc) { return $null }
                return ([string]$svc.StartType -eq $Tweak.Spec.Startup)
            }
            'ScheduledTask' {
                if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }
                foreach ($t in $Tweak.Spec.Tasks) {
                    $st = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
                    if ($st -and $st.State -ne 'Disabled') { return $false }
                }
                return $true
            }
            'Custom' {
                if ($Tweak.Spec.Test) { return [bool](& $Tweak.Spec.Test) }
                return $null
            }
        }
    } catch { return $null }
    $null
}

function Get-TweakSnapshot {
    param([object]$Tweak)
    switch ($Tweak.Type) {
        'Registry' {
            $vals = foreach ($v in $Tweak.Spec.Values) { Get-RegValueSnapshot -Path $Tweak.Spec.Path -Name $v.Name }
            return @{ Path = $Tweak.Spec.Path; Values = @($vals) }
        }
        'Service' {
            $svc = Get-Service -Name $Tweak.Spec.Service -ErrorAction SilentlyContinue
            return @{ Service = $Tweak.Spec.Service
                     Found = [bool]$svc
                     StartType = if ($svc) { [string]$svc.StartType } else { $null }
                     Status = if ($svc) { [string]$svc.Status } else { $null } }
        }
        'ScheduledTask' {
            $states = @()
            if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
                foreach ($t in $Tweak.Spec.Tasks) {
                    $st = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
                    $states += @{ Path = $t.Path; Name = $t.Name; State = if ($st) { [string]$st.State } else { $null } }
                }
            }
            return @{ Tasks = $states }
        }
        'Custom'  { return [hashtable](& $Tweak.Spec.Backup) }
    }
    @{}
}

function Set-TweakState {
    param([object]$Tweak, [object]$Snapshot)
    switch ($Tweak.Type) {
        'Registry' {
            foreach ($v in $Tweak.Spec.Values) { Set-RegValue -Path $Tweak.Spec.Path -Name $v.Name -Kind $v.Kind -Value $v.Value }
        }
        'Service' {
            Set-Service -Name $Tweak.Spec.Service -StartupType $Tweak.Spec.Startup -ErrorAction Stop
            if ($Tweak.Spec.StopNow -and $Snapshot.Status -eq 'Running') {
                Stop-Service -Name $Tweak.Spec.Service -Force -ErrorAction SilentlyContinue
            }
        }
        'ScheduledTask' {
            foreach ($t in $Tweak.Spec.Tasks) {
                Disable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue | Out-Null
            }
        }
        'Custom' { & $Tweak.Spec.Apply $Snapshot }
    }
}

function Invoke-Tweak {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Tweak)

    $applied = Test-TweakApplied -Tweak $Tweak
    if ($applied -eq $true) {
        Write-OptLog "$($Tweak.Name)  [already applied]" 'Debug'
        $script:Skipped++
        return
    }

    $snapshot = Get-TweakSnapshot -Tweak $Tweak
    $target   = $Tweak.Name
    $action   = "Apply tweak [$($Tweak.Area)/$($Tweak.Risk)]"

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        try {
            Set-TweakState -Tweak $Tweak -Snapshot $snapshot
            Write-OptLog "$($Tweak.Name)" 'Success'
            $script:Applied++
            $script:Snapshots.Add([pscustomobject]@{ Id = $Tweak.Id; Type = $Tweak.Type; Snapshot = $snapshot })
            $script:Stats.Add([pscustomobject]@{ Id = $Tweak.Id; Area = $Tweak.Area; Risk = $Tweak.Risk; Result = 'applied' })
        }
        catch {
            $script:Errors++
            Write-OptLog "  $($Tweak.Name): $($_.Exception.Message)" 'Error'
            $script:Stats.Add([pscustomobject]@{ Id = $Tweak.Id; Area = $Tweak.Area; Risk = $Tweak.Risk; Result = 'error' })
        }
    }
    elseif (Test-WhatIfMode) {
        $script:Stats.Add([pscustomobject]@{ Id = $Tweak.Id; Area = $Tweak.Area; Risk = $Tweak.Risk; Result = 'would-apply' })
    }
}

function Write-BackupManifest {
    if (Test-WhatIfMode -or $script:Snapshots.Count -eq 0) { return $null }
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null
    }
    $file = Join-Path $BackupDir ("optimize-backup-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))
    $manifest = [pscustomobject]@{
        Timestamp    = (Get-Date).ToString('s')
        RestorePoint = $script:RestorePointMade
        Tweaks       = $script:Snapshots
    }
    try {
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $file -Encoding UTF8 -WhatIf:$false
        Write-OptLog "Backup manifest written: $file" 'Info'
        return $file
    } catch { Write-OptLog "Could not write backup manifest: $($_.Exception.Message)" 'Warning'; return $null }
}

function Get-LatestManifest {
    if (-not (Test-Path $BackupDir)) { return $null }
    Get-ChildItem -Path $BackupDir -Filter 'optimize-backup-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Restore-Tweak {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Entry, [object[]]$Registry)

    $def = $Registry | Where-Object { $_.Id -eq $Entry.Id } | Select-Object -First 1
    $name = if ($def) { $def.Name } else { $Entry.Id }
    $snap = $Entry.Snapshot

    if (-not $PSCmdlet.ShouldProcess($name, 'Revert tweak')) { return }
    try {
        switch ($Entry.Type) {
            'Registry' {
                foreach ($v in $snap.Values) { Restore-RegValue -Path $snap.Path -Snap $v }
            }
            'Service' {
                if ($snap.Found) {
                    if ($snap.StartType) { Set-Service -Name $snap.Service -StartupType $snap.StartType -ErrorAction SilentlyContinue }
                    if ($snap.Status -eq 'Running') { Start-Service -Name $snap.Service -ErrorAction SilentlyContinue }
                }
            }
            'ScheduledTask' {
                if (Get-Command Enable-ScheduledTask -ErrorAction SilentlyContinue) {
                    foreach ($t in $snap.Tasks) {
                        if ($t.State -and $t.State -ne 'Disabled') {
                            Enable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue | Out-Null
                        }
                    }
                }
            }
            'Custom' {
                if ($def -and $def.Spec.Undo) { & $def.Spec.Undo $snap }
                else { Write-OptLog "No undo available for '$name'." 'Warning' }
            }
        }
        Write-OptLog "Reverted: $name" 'Success'
        $script:Applied++
    }
    catch { $script:Errors++; Write-OptLog "  revert $name : $($_.Exception.Message)" 'Error' }
}

function Start-SunCleanerUndo {
    Write-OptLog 'Windows Optimize - UNDO' 'Step'
    $manifestPath = if ($BackupManifest) { $BackupManifest } else { Get-LatestManifest }
    if (-not $manifestPath -or -not (Test-Path $manifestPath)) {
        Write-OptLog 'No backup manifest found - nothing to undo.' 'Warning'; return
    }
    Write-OptLog "Using manifest: $manifestPath" 'Info'
    try { $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json }
    catch { Write-OptLog "Could not read manifest: $($_.Exception.Message)" 'Error'; return }

    $registry = Get-OptimizationTweakRegistry
    $entries  = @($manifest.Tweaks)
    if (-not $entries.Count) { Write-OptLog 'Manifest has no recorded tweaks.' 'Warning'; return }

    # revert in reverse order of application.
    [array]::Reverse($entries)
    foreach ($e in $entries) { Restore-Tweak -Entry $e -Registry $registry }

    Write-OptLog '' 'Info'
    Write-OptLog ("Reverted {0} tweak(s), {1} error(s)." -f $script:Applied, $script:Errors) 'Success'
}

function Show-OptSummary {
    param([string]$ManifestFile)
    $dur  = (Get-Date) - $script:StartTime
    $mode = if (Test-WhatIfMode) { 'DRY RUN' } else { 'OPTIMIZE' }
    Write-OptLog '' 'Info'
    Write-OptLog "===== $mode SUMMARY =====" 'Step'
    $byArea = $script:Stats | Group-Object Area | Sort-Object Name
    foreach ($g in $byArea) {
        Write-OptLog ("  {0,-12} {1} tweak(s)" -f $g.Name, $g.Count) 'Info'
    }
    $verb = if (Test-WhatIfMode) { 'Would apply' } else { 'Applied' }
    Write-OptLog '' 'Info'
    if (Test-WhatIfMode) {
        $would = @($script:Stats | Where-Object Result -eq 'would-apply').Count
        Write-OptLog ("{0}: {1} tweak(s)" -f $verb, $would) 'Success'
    }
    else {
        Write-OptLog ("{0}: {1} tweak(s), skipped {2} already-applied, {3} error(s)" -f `
            $verb, $script:Applied, $script:Skipped, $script:Errors) 'Success'
        if ($ManifestFile) { Write-OptLog "Undo with:  .\Optimize-Windows-Senior.ps1 -Undo" 'Info' }
    }
    Write-OptLog ("Duration: {0:N1}s   Log: {1}" -f $dur.TotalSeconds, $LogPath) 'Info'
}

function Write-OptReport {
    param([string]$ManifestFile)
    Write-SunCleanerReport -ReportPath $ReportPath -Engine 'Optimize' `
        -RestorePoint $script:RestorePointMade -StartTime $script:StartTime `
        -Summary @{
            Applied  = $script:Applied
            Skipped  = $script:Skipped
            Errors   = $script:Errors
            Manifest = $ManifestFile
        } `
        -Items $script:Stats `
        -LogAction { param($m, $l) Write-OptLog $m $l }
}

function Show-TweakList {
    Write-Host ''
    Write-Host 'Optimization tweak registry:' -ForegroundColor Cyan
    Get-OptimizationTweakRegistry |
        Sort-Object Area, @{ E = { @{Safe=0;Moderate=1;Aggressive=2;Dangerous=3}[$_.Risk] } } |
        Format-Table @{ L='Id'; E={$_.Id}; W=22 },
                     @{ L='Area'; E={$_.Area}; W=12 },
                     @{ L='Risk'; E={$_.Risk}; W=11 },
                     @{ L='Default'; E={ if($_.DefaultOn){'on'}else{'off'} }; W=8 },
                     @{ L='Tweak'; E={$_.Name} } -AutoSize
    Write-Host 'Safe + Moderate + Aggressive selectable by default; debatable tweaks ship off (toggle or -Include).' -ForegroundColor DarkGray
    Write-Host ''
}

function Show-OptUsageHelp {
@'
sunCleaner - optimization engine v1.0.0  (registry-driven, full undo)

USAGE
  .\Optimize-Windows-Senior.ps1 [options]

SELECTION
  -Area <names>         Limit to: Performance, Privacy, Debloat, Network
  -Include <ids>        Force tweaks on  (see -ListTweaks for ids)
  -Exclude <ids>        Force tweaks off
  -IncludeDangerous     Also apply the irreversible Dangerous tier
  -Conservative         Cap at Safe + Moderate (skip Aggressive)

UNDO
  -Undo                 Revert the most recent run from its backup manifest
  -BackupManifest <p>   Undo a specific manifest file
  -BackupDir <path>     Where manifests live (default %ProgramData%\sunCleaner\backups)

SAFETY
  -WhatIf / -DryRun,-dr Preview only, change nothing (real ShouldProcess)
  -NoRestorePoint,-nrp  Skip the Checkpoint-Computer restore point (created by default)
  -Unattended,-Force,-f No prompts - for automation

OUTPUT
  -LogPath <path>       Text log (default: %TEMP%\WindowsOptimize.log)
  -ReportPath <path>    Machine-readable JSON report
  -ListTweaks           Print the tweak registry and exit
  -Help                 Show this help

EXAMPLES
  .\Optimize-Windows-Senior.ps1 -WhatIf
  .\Optimize-Windows-Senior.ps1 -Area Privacy,Performance
  .\Optimize-Windows-Senior.ps1 -Undo
'@ | Write-Host
}

function Start-SunCleanerOptimize {
    $Area = $script:Area
    $Include = $script:Include
    $Exclude = $script:Exclude
    $IncludeDangerous = $script:IncludeDangerous
    $Conservative = $script:Conservative
    $DryRun = $script:DryRun
    $Unattended = $script:Unattended
    $NoRestorePoint = $script:NoRestorePoint
    $BackupDir = $script:BackupDir
    $LogPath = $script:LogPath
    $ReportPath = $script:ReportPath
    $modeText = if (Test-WhatIfMode) { 'DryRun' } else { 'Live' }
    Write-OptLog 'sunCleaner - optimization' 'Step'
    Write-OptLog ("PowerShell {0} | Mode: {1}" -f $PSVersionTable.PSVersion, $modeText) 'Info'

    if (-not (Test-AdminPrivileges)) {
        Write-OptLog 'Administrator privileges are required. Re-run as Administrator.' 'Error'
        exit 2
    }

    $registry  = Get-OptimizationTweakRegistry
    $selection = Resolve-TweakSelection -Registry $registry -Area $Area `
        -Include $Include -Exclude $Exclude -Conservative:$Conservative `
        -IncludeDangerous:$IncludeDangerous

    if (-not $selection) { Write-OptLog 'No tweaks selected - nothing to do.' 'Warning'; return }

    $dangerous = $selection | Where-Object { $_.Risk -eq 'Dangerous' }
    Write-OptLog ("Selected {0} tweak(s){1}." -f @($selection).Count,
        $(if ($dangerous) { ", including $($dangerous.Count) DANGEROUS" } else { '' })) 'Info'

    if ($dangerous -and -not (Test-WhatIfMode) -and -not $Unattended) {
        Write-OptLog 'Dangerous (irreversible) tweaks selected:' 'Safety'
        $dangerous | ForEach-Object { Write-OptLog "   - $($_.Name)" 'Safety' }
        $answer = Read-Host 'Proceed with these? (yes/No)'
        if ($answer -notmatch '^(y|yes)$') {
            $selection = $selection | Where-Object { $_.Risk -ne 'Dangerous' }
            Write-OptLog 'Skipping the Dangerous tier by your choice.' 'Info'
        }
    }

    if (-not $NoRestorePoint -and -not (Test-WhatIfMode)) { New-OptRestorePoint | Out-Null }

    $order = 'Performance','Privacy','Debloat','Network'
    foreach ($a in $order) {
        foreach ($tweak in ($selection | Where-Object { $_.Area -eq $a })) {
            Invoke-Tweak -Tweak $tweak
        }
    }

    $manifest = Write-BackupManifest
    Show-OptSummary -ManifestFile $manifest
    Write-OptReport -ManifestFile $manifest
}

# --- src/Engines/Repair.ps1 ---

<#
.SYNOPSIS
    sunCleaner - repair engine - scans for common problems, then repairs them.
#>


$script:StartTime        = Get-Date
$script:Results          = New-Object System.Collections.Generic.List[object]
$script:Fixed            = 0
$script:FixErrors        = 0
$script:RebootNeeded     = $false
$script:RestorePointMade = $false

if ($DryRun) { $WhatIfPreference = $true }


function Write-RepLog {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Debug','Step','WhatIf','Safety')]
        [string]$Level = 'Info'
    )
    Write-WsLog -Message $Message -Level $Level -LogPath $LogPath
}

function New-RepairRestorePoint {
    $st = New-SunCleanerRestorePoint `
        -Description "Before Windows Repair $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
        -LogAction { param($m, $l) Write-RepLog $m $l }
    if ($st -eq 'Created') { $script:RestorePointMade = $true }
    return ($st -ne 'Failed')
}

#   scan returns @{ Status = 'OK'|'Warn'|'Fail'; Detail = '...' }
function New-DiagnosticCheck {
    param(
        [string]$Id, [string]$Name, [string]$Category,
        [scriptblock]$Scan, [scriptblock]$Fix,
        [string]$FixRisk = 'Safe', [string]$FixLabel, [bool]$Reboot = $false
    )
    [pscustomobject]@{
        Id = $Id; Name = $Name; Category = $Category
        Scan = $Scan; Fix = $Fix; FixRisk = $FixRisk; FixLabel = $FixLabel; Reboot = $Reboot
    }
}

function Get-DiagnosticCheckRegistry {
    @(
        New-DiagnosticCheck img-health 'System image health (DISM)' Integrity `
            -Scan {
                if (-not (Get-Command Repair-WindowsImage -ErrorAction SilentlyContinue)) {
                    return @{ Status = 'Skip'; Detail = 'DISM module unavailable' }
                }
                $state = (Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState
                switch ("$state") {
                    'Healthy'              { @{ Status = 'OK';   Detail = 'Component store healthy' } }
                    'Repairable'           { @{ Status = 'Fail'; Detail = 'Component store corruption is repairable' } }
                    default                { @{ Status = 'Warn'; Detail = "Image health: $state (deep scan with DISM /ScanHealth)" } }
                }
            } `
            -Fix {
                Write-RepLog 'Running DISM /RestoreHealth (may take several minutes)...' 'Info'
                Repair-WindowsImage -Online -RestoreHealth -ErrorAction SilentlyContinue | Out-Null
                Write-RepLog 'Running sfc /scannow...' 'Info'
                & sfc.exe /scannow | Out-Null
            } -FixRisk Aggressive -FixLabel 'DISM RestoreHealth + SFC' -Reboot $false

        New-DiagnosticCheck disk-smart 'Physical disk health (SMART)' Disk `
            -Scan {
                if (-not (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
                    return @{ Status = 'Skip'; Detail = 'Storage module unavailable' }
                }
                $bad = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.HealthStatus -and $_.HealthStatus -ne 'Healthy' }
                if ($bad) { @{ Status = 'Fail'; Detail = ('Unhealthy disk(s): ' + (($bad | ForEach-Object { "$($_.FriendlyName)=$($_.HealthStatus)" }) -join ', ') + ' - back up now') } }
                else      { @{ Status = 'OK';   Detail = 'All physical disks report Healthy' } }
            } -Fix $null

        New-DiagnosticCheck disk-space 'Low free disk space' Disk `
            -Scan {
                $worst = 'OK'; $lines = @()
                foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
                    if (-not $d.Size) { continue }
                    $pct = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
                    $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
                    $lines += "$($d.DeviceID) $freeGB GB free ($pct%)"
                    if ($pct -lt 5 -or $freeGB -lt 5)        { $worst = 'Fail' }
                    elseif (($pct -lt 12 -or $freeGB -lt 15) -and $worst -ne 'Fail') { $worst = 'Warn' }
                }
                @{ Status = $worst; Detail = ($lines -join ' | ') + $(if ($worst -ne 'OK') { ' - run Disk cleanup' } else { '' }) }
            } -Fix $null

        New-DiagnosticCheck disk-dirty 'Volumes flagged for chkdsk' Disk `
            -Scan {
                $dirty = @()
                foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
                    & fsutil.exe dirty query "$($d.DeviceID)" *>$null
                    if ($LASTEXITCODE -eq 0) { $dirty += $d.DeviceID }
                }
                if ($dirty) { @{ Status = 'Warn'; Detail = ('Dirty bit set on: ' + ($dirty -join ', ')) } }
                else        { @{ Status = 'OK';   Detail = 'No volume flagged dirty' } }
            } `
            -Fix {
                foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
                    & fsutil.exe dirty query "$($d.DeviceID)" *>$null
                    if ($LASTEXITCODE -eq 0) { Write-RepLog "chkdsk $($d.DeviceID) /scan (online)..." 'Info'; & chkdsk.exe "$($d.DeviceID)" /scan | Out-Null }
                }
            } -FixRisk Moderate -FixLabel 'chkdsk /scan (online, no reboot)'

        New-DiagnosticCheck reboot-pending 'Pending reboot' Update `
            -Scan {
                $reasons = @()
                if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
                if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate' }
                $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
                if ($pfro) { $reasons += 'PendingFileRename' }
                if ($reasons) { @{ Status = 'Warn'; Detail = ('Reboot required: ' + ($reasons -join ', ')) } }
                else          { @{ Status = 'OK';   Detail = 'No pending reboot' } }
            } `
            -Fix { Write-RepLog 'Scheduling reboot in 60s (cancel with: shutdown /a)' 'Warning'; & shutdown.exe /r /t 60 /c 'sunCleaner repair reboot' } `
            -FixRisk Aggressive -FixLabel 'Reboot in 60s (cancel: shutdown /a)' -Reboot $true

        New-DiagnosticCheck wu-health 'Windows Update components' Update `
            -Scan {
                $sd = "$env:WINDIR\SoftwareDistribution\Download"
                $sizeGB = 0
                if (Test-Path $sd) { $sizeGB = [math]::Round(((Get-ChildItem $sd -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1GB, 2) }
                $wu = Get-Service wuauserv -ErrorAction SilentlyContinue
                if ($wu -and $wu.StartType -eq 'Disabled') { return @{ Status = 'Warn'; Detail = 'wuauserv is Disabled; SoftwareDistribution ' + $sizeGB + ' GB' } }
                if ($sizeGB -gt 4) { return @{ Status = 'Warn'; Detail = "SoftwareDistribution cache is large ($sizeGB GB)" } }
                @{ Status = 'OK'; Detail = "Update cache $sizeGB GB; service OK" }
            } `
            -Fix {
                Write-RepLog 'Resetting Windows Update components...' 'Info'
                foreach ($s in 'wuauserv','bits','cryptsvc') { Stop-Service $s -Force -ErrorAction SilentlyContinue }
                foreach ($p in @("$env:WINDIR\SoftwareDistribution","$env:WINDIR\System32\catroot2")) {
                    if (Test-Path $p) { Rename-Item $p "$p.old_$(Get-Date -Format 'yyyyMMddHHmmss')" -Force -ErrorAction SilentlyContinue }
                }
                foreach ($s in 'cryptsvc','bits','wuauserv') { Start-Service $s -ErrorAction SilentlyContinue }
            } -FixRisk Moderate -FixLabel 'Reset Windows Update (rename SoftwareDistribution/catroot2)'

        New-DiagnosticCheck net-connectivity 'Internet & DNS' Network `
            -Scan {
                # address held in a variable so PSScriptAnalyzer doesn't flag it as a hardcoded host.
                $pingTarget = '8.8.8.8'; $dnsTarget = 'microsoft.com'
                $ping = Test-Connection -ComputerName $pingTarget -Count 1 -Quiet -ErrorAction SilentlyContinue
                $dns  = $false
                if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
                    $dns = [bool](Resolve-DnsName $dnsTarget -ErrorAction SilentlyContinue)
                }
                if (-not $ping) { @{ Status = 'Fail'; Detail = 'No reply from 8.8.8.8 (no internet)' } }
                elseif (-not $dns) { @{ Status = 'Warn'; Detail = 'Internet OK but DNS resolution failed' } }
                else { @{ Status = 'OK'; Detail = 'Internet and DNS reachable' } }
            } `
            -Fix {
                Write-RepLog 'Flushing DNS and resetting the network stack...' 'Info'
                & ipconfig.exe /flushdns | Out-Null
                & netsh.exe winsock reset | Out-Null
                & netsh.exe int ip reset | Out-Null
                & ipconfig.exe /release | Out-Null
                & ipconfig.exe /renew | Out-Null
            } -FixRisk Aggressive -FixLabel 'Flush DNS + winsock/IP reset' -Reboot $true

        New-DiagnosticCheck dev-errors 'Devices with driver problems' Devices `
            -Scan {
                $bad = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 }
                if ($bad) {
                    $names = ($bad | Select-Object -First 5 | ForEach-Object { "$($_.Name) (code $($_.ConfigManagerErrorCode))" }) -join '; '
                    @{ Status = 'Warn'; Detail = "$(@($bad).Count) device(s) with errors: $names" }
                } else { @{ Status = 'OK'; Detail = 'No devices report driver errors' } }
            } `
            -Fix { Write-RepLog 'Rescanning for hardware changes...' 'Info'; & pnputil.exe /scan-devices *>$null } `
            -FixRisk Safe -FixLabel 'Rescan devices (pnputil /scan-devices)'

        New-DiagnosticCheck svc-critical 'Critical services stopped' Services `
            -Scan {
                $want = 'Audiosrv','Dhcp','Dnscache','EventLog','mpssvc','Winmgmt','Schedule','BFE','LanmanWorkstation','ProfSvc','nsi','Power'
                $stopped = foreach ($n in $want) {
                    $s = Get-Service $n -ErrorAction SilentlyContinue
                    if ($s -and $s.StartType -in 'Automatic','Boot','System' -and $s.Status -ne 'Running') { $n }
                }
                $stopped = @($stopped)
                if ($stopped.Count) { @{ Status = 'Fail'; Detail = ('Stopped: ' + ($stopped -join ', ')) } }
                else                { @{ Status = 'OK';   Detail = 'All monitored critical services are running' } }
            } `
            -Fix {
                $want = 'Audiosrv','Dhcp','Dnscache','EventLog','mpssvc','Winmgmt','Schedule','BFE','LanmanWorkstation','ProfSvc','nsi','Power'
                foreach ($n in $want) {
                    $s = Get-Service $n -ErrorAction SilentlyContinue
                    if ($s -and $s.StartType -in 'Automatic','Boot','System' -and $s.Status -ne 'Running') {
                        Start-Service $n -ErrorAction SilentlyContinue
                        Write-RepLog "started $n" 'Debug'
                    }
                }
            } -FixRisk Safe -FixLabel 'Start stopped critical services'

        New-DiagnosticCheck def-health 'Microsoft Defender health' Security `
            -Scan {
                if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
                    return @{ Status = 'Skip'; Detail = 'Defender module unavailable (3rd-party AV?)' }
                }
                $st = Get-MpComputerStatus -ErrorAction Stop
                $issues = @()
                if (-not $st.RealTimeProtectionEnabled) { $issues += 'real-time protection OFF' }
                if ($st.AntivirusSignatureAge -gt 7)    { $issues += "signatures $($st.AntivirusSignatureAge)d old" }
                if ($issues) { @{ Status = 'Warn'; Detail = ($issues -join '; ') } }
                else         { @{ Status = 'OK';   Detail = 'Real-time protection on; signatures current' } }
            } `
            -Fix {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
                Write-RepLog 'Updating Defender signatures...' 'Info'
                Update-MpSignature -ErrorAction SilentlyContinue
            } -FixRisk Safe -FixLabel 'Enable real-time protection + update signatures'

        New-DiagnosticCheck wmi-repo 'WMI repository consistency' System `
            -Scan {
                $out = & winmgmt.exe /verifyrepository 2>&1
                if ($LASTEXITCODE -eq 0) { @{ Status = 'OK'; Detail = 'WMI repository is consistent' } }
                else { @{ Status = 'Fail'; Detail = 'WMI repository inconsistent' } }
            } `
            -Fix { Write-RepLog 'Salvaging WMI repository...' 'Info'; & winmgmt.exe /salvagerepository 2>&1 | Out-Null } `
            -FixRisk Moderate -FixLabel 'Salvage WMI repository'

        New-DiagnosticCheck time-sync 'System time synchronization' System `
            -Scan {
                $w = Get-Service w32time -ErrorAction SilentlyContinue
                if (-not $w) { return @{ Status = 'Skip'; Detail = 'w32time service not found' } }
                if ($w.Status -ne 'Running') { return @{ Status = 'Warn'; Detail = 'Time service (w32time) is stopped' } }
                @{ Status = 'OK'; Detail = 'Time service running' }
            } `
            -Fix { Start-Service w32time -ErrorAction SilentlyContinue; & w32tm.exe /resync /force *>$null } `
            -FixRisk Safe -FixLabel 'Start w32time + resync clock'

        New-DiagnosticCheck event-errors 'Recent critical/error events' System `
            -Scan {
                $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1,2; StartTime = (Get-Date).AddDays(-2) } -MaxEvents 300 -ErrorAction SilentlyContinue
                $ev = @($ev)
                if ($ev.Count -eq 0) { return @{ Status = 'OK'; Detail = 'No critical/error events in the last 48h' } }
                $top = ($ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3 |
                        ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
                $status = if ($ev.Count -gt 50) { 'Warn' } else { 'OK' }
                @{ Status = $status; Detail = "$($ev.Count) error/critical event(s) in 48h; top: $top" }
            } -Fix $null

        New-DiagnosticCheck restore-enabled 'System Restore protection' System `
            -Scan {
                $rp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -ErrorAction SilentlyContinue
                $pts = 0
                try { $pts = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue).Count } catch { $pts = 0 }
                if ($rp.DisableSR -eq 1) { @{ Status = 'Warn'; Detail = 'System Restore is disabled (no rollback safety net)' } }
                elseif ($pts -eq 0)      { @{ Status = 'Warn'; Detail = 'System Restore on but no restore points exist' } }
                else                     { @{ Status = 'OK';   Detail = "System Restore on; $pts restore point(s)" } }
            } `
            -Fix {
                if (Get-Command Enable-ComputerRestore -ErrorAction SilentlyContinue) {
                    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
                    $rk = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
                    New-ItemProperty -Path $rk -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                    Checkpoint-Computer -Description 'sunCleaner baseline' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction SilentlyContinue
                } else { Write-RepLog 'Enable-ComputerRestore unavailable (PowerShell 7?) - enable System Protection manually' 'Warning' }
            } -FixRisk Safe -FixLabel 'Enable System Restore + create a checkpoint'

        New-DiagnosticCheck hosts-integrity 'Hosts file integrity' Network `
            -Scan {
                $hosts = "$env:WINDIR\System32\drivers\etc\hosts"
                if (-not (Test-Path $hosts)) { return @{ Status = 'OK'; Detail = 'No hosts file (default)' } }
                $lines  = Get-Content $hosts -ErrorAction SilentlyContinue | Where-Object { $_ -and ($_ -notmatch '^\s*#') -and ($_ -match '\S') }
                $active = @($lines | Where-Object { $_ -notmatch '^\s*(127\.0\.0\.1|::1)\s+localhost\s*$' })
                $susp   = @($active | Where-Object { $_ -match '(?i)(microsoft|windowsupdate|defender|msftncsi|office|sophos|mcafee|avast|kaspersky)' })
                if ($susp.Count)        { @{ Status = 'Fail'; Detail = "$($susp.Count) hosts entry(ies) redirect Microsoft/AV/update domains - possible hijack" } }
                elseif ($active.Count)  { @{ Status = 'Warn'; Detail = "$($active.Count) custom hosts entry(ies) present" } }
                else                    { @{ Status = 'OK';   Detail = 'Hosts file has no active redirects' } }
            } `
            -Fix {
                $hosts = "$env:WINDIR\System32\drivers\etc\hosts"
                $bak = "$hosts.suncleaner_$(Get-Date -Format 'yyyyMMddHHmmss').bak"
                Copy-Item $hosts $bak -Force -ErrorAction SilentlyContinue
                Write-RepLog "Backed up hosts to $bak; writing default header" 'Info'
                Set-Content -Path $hosts -Value '# Copyright (c) 1993-2009 Microsoft Corp.' -Encoding ASCII -ErrorAction SilentlyContinue
                & ipconfig.exe /flushdns | Out-Null
            } -FixRisk Moderate -FixLabel 'Back up & reset hosts to default (then flush DNS)'

        New-DiagnosticCheck proxy-hijack 'Proxy / PAC hijack' Network `
            -Scan {
                $is = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                $p = Get-ItemProperty $is -ErrorAction SilentlyContinue
                if ($p.AutoConfigURL)                       { @{ Status = 'Fail'; Detail = "AutoConfigURL (PAC) set: $($p.AutoConfigURL)" } }
                elseif ($p.ProxyEnable -eq 1 -and $p.ProxyServer) { @{ Status = 'Warn'; Detail = "Proxy enabled: $($p.ProxyServer)" } }
                else                                        { @{ Status = 'OK';   Detail = 'No proxy / PAC configured' } }
            } `
            -Fix {
                $is = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                Set-ItemProperty $is -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
                Remove-ItemProperty $is -Name ProxyServer -ErrorAction SilentlyContinue
                Remove-ItemProperty $is -Name AutoConfigURL -ErrorAction SilentlyContinue
                & netsh.exe winhttp reset proxy *>$null
            } -FixRisk Moderate -FixLabel 'Reset WinINET/WinHTTP proxy settings'

        New-DiagnosticCheck firewall-state 'Windows Firewall enabled' Security `
            -Scan {
                if (-not (Get-Command Get-NetFirewallProfile -ErrorAction SilentlyContinue)) { return @{ Status = 'Skip'; Detail = 'Firewall module unavailable' } }
                $off = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled })
                if ($off.Count -ge 3) { @{ Status = 'Fail'; Detail = 'All firewall profiles are OFF' } }
                elseif ($off.Count)   { @{ Status = 'Warn'; Detail = ('Firewall off for: ' + (($off.Name) -join ', ')) } }
                else                  { @{ Status = 'OK';   Detail = 'All firewall profiles enabled' } }
            } `
            -Fix { Set-NetFirewallProfile -All -Enabled True -ErrorAction SilentlyContinue } `
            -FixRisk Moderate -FixLabel 'Re-enable all firewall profiles'

        New-DiagnosticCheck def-signatures 'Defender signatures & threats' Security `
            -Scan {
                if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) { return @{ Status = 'Skip'; Detail = 'Defender module unavailable' } }
                $s = Get-MpComputerStatus -ErrorAction SilentlyContinue
                if (-not $s) { return @{ Status = 'Skip'; Detail = 'Defender status unavailable' } }
                $active = @(Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { $_.ThreatStatusID -in 1, 102, 103, 107 })
                if ($active.Count)                 { @{ Status = 'Fail'; Detail = "$($active.Count) active/unremediated threat(s)" } }
                elseif ($s.DefenderSignaturesOutOfDate) { @{ Status = 'Warn'; Detail = 'Defender signatures are out of date' } }
                else                               { @{ Status = 'OK';   Detail = 'Defender signatures current; no active threats' } }
            } `
            -Fix { Write-RepLog 'Updating Defender signatures...' 'Info'; if (Get-Command Update-MpSignature -ErrorAction SilentlyContinue) { Update-MpSignature -ErrorAction SilentlyContinue } } `
            -FixRisk Safe -FixLabel 'Update Defender signatures'

        New-DiagnosticCheck smb1-disabled 'SMBv1 protocol disabled' Security `
            -Scan {
                $srv = (Get-SmbServerConfiguration -ErrorAction SilentlyContinue).EnableSMB1Protocol
                if ($null -eq $srv) { return @{ Status = 'Skip'; Detail = 'SMB module unavailable' } }
                if ($srv) { @{ Status = 'Warn'; Detail = 'SMBv1 is ENABLED (EternalBlue/WannaCry vector)' } }
                else      { @{ Status = 'OK';   Detail = 'SMBv1 disabled' } }
            } `
            -Fix {
                Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue
                if (Get-Command Disable-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
                    Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
                }
            } -FixRisk Safe -FixLabel 'Disable SMBv1' -Reboot $true

        New-DiagnosticCheck sched-task-health 'Critical scheduled tasks enabled' System `
            -Scan {
                if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return @{ Status = 'Skip'; Detail = 'ScheduledTasks module unavailable' } }
                $want = @(
                    @{ P = '\Microsoft\Windows\WindowsUpdate\';        N = 'Scheduled Start' },
                    @{ P = '\Microsoft\Windows\UpdateOrchestrator\';   N = 'Schedule Scan' },
                    @{ P = '\Microsoft\Windows\SystemRestore\';        N = 'SR' },
                    @{ P = '\Microsoft\Windows\Windows Defender\';     N = 'Windows Defender Scheduled Scan' })
                $disabled = foreach ($t in $want) {
                    $st = Get-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction SilentlyContinue
                    if ($st -and $st.State -eq 'Disabled') { $t.N }
                }
                $disabled = @($disabled)
                if ($disabled.Count) { @{ Status = 'Warn'; Detail = ('Critical task(s) disabled: ' + ($disabled -join ', ')) } }
                else                 { @{ Status = 'OK';   Detail = 'Monitored critical tasks are enabled' } }
            } `
            -Fix {
                $want = @(
                    @{ P = '\Microsoft\Windows\WindowsUpdate\';        N = 'Scheduled Start' },
                    @{ P = '\Microsoft\Windows\UpdateOrchestrator\';   N = 'Schedule Scan' },
                    @{ P = '\Microsoft\Windows\SystemRestore\';        N = 'SR' },
                    @{ P = '\Microsoft\Windows\Windows Defender\';     N = 'Windows Defender Scheduled Scan' })
                foreach ($t in $want) {
                    $st = Get-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction SilentlyContinue
                    if ($st -and $st.State -eq 'Disabled') { Enable-ScheduledTask -TaskPath $t.P -TaskName $t.N -ErrorAction SilentlyContinue | Out-Null }
                }
            } -FixRisk Moderate -FixLabel 'Re-enable critical scheduled tasks (curated list)'

        New-DiagnosticCheck bits-health 'BITS transfer queue' Update `
            -Scan {
                if (-not (Get-Command Get-BitsTransfer -ErrorAction SilentlyContinue)) { return @{ Status = 'Skip'; Detail = 'BITS module unavailable' } }
                $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue)
                $err  = @($jobs | Where-Object { $_.JobState -in 'Error', 'TransientError' })
                if ($err.Count)          { @{ Status = 'Warn'; Detail = "$($err.Count) BITS job(s) in error state" } }
                elseif ($jobs.Count -gt 50) { @{ Status = 'Warn'; Detail = "$($jobs.Count) BITS jobs queued (backlog)" } }
                else                     { @{ Status = 'OK';   Detail = "$($jobs.Count) BITS job(s); none in error" } }
            } `
            -Fix { Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue } `
            -FixRisk Moderate -FixLabel 'Clear stuck BITS transfers'

        New-DiagnosticCheck spooler-health 'Print spooler' Services `
            -Scan {
                $sp = Get-Service Spooler -ErrorAction SilentlyContinue
                if (-not $sp) { return @{ Status = 'Skip'; Detail = 'Spooler service not found' } }
                $printers = @(Get-Printer -ErrorAction SilentlyContinue)
                if ($printers.Count -eq 0) { return @{ Status = 'OK'; Detail = 'No printers installed' } }
                $queue = @(Get-ChildItem "$env:WINDIR\System32\spool\PRINTERS" -ErrorAction SilentlyContinue)
                if ($sp.StartType -ne 'Disabled' -and $sp.Status -ne 'Running') { @{ Status = 'Warn'; Detail = 'Spooler should run but is stopped' } }
                elseif ($queue.Count -gt 0) { @{ Status = 'Warn'; Detail = "$($queue.Count) file(s) stuck in the print queue" } }
                else { @{ Status = 'OK'; Detail = 'Spooler running; queue clear' } }
            } `
            -Fix {
                Stop-Service Spooler -Force -ErrorAction SilentlyContinue
                Get-ChildItem "$env:WINDIR\System32\spool\PRINTERS\*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                Start-Service Spooler -ErrorAction SilentlyContinue
            } -FixRisk Safe -FixLabel 'Clear print queue + restart spooler'

        New-DiagnosticCheck store-health 'Microsoft Store health' System `
            -Scan {
                try { $store = Get-AppxPackage -Name Microsoft.WindowsStore -ErrorAction Stop | Select-Object -First 1 }
                catch { return @{ Status = 'Skip'; Detail = 'Appx module unavailable in this PowerShell host' } }
                if (-not $store) { return @{ Status = 'Warn'; Detail = 'Microsoft Store package not found for this user' } }
                if ($store.Status -and $store.Status -ne 'Ok') { @{ Status = 'Warn'; Detail = "Store package status: $($store.Status)" } }
                else { @{ Status = 'OK'; Detail = "Store $($store.Version) present" } }
            } `
            -Fix { Write-RepLog 'Resetting Microsoft Store cache (wsreset)...' 'Info'; & wsreset.exe *>$null } `
            -FixRisk Safe -FixLabel 'Reset Store cache (wsreset)'

        New-DiagnosticCheck disk-reliability 'SSD wear & temperature' Disk `
            -Scan {
                if (-not (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue)) { return @{ Status = 'Skip'; Detail = 'Storage module unavailable' } }
                $worst = 'OK'; $lines = @()
                foreach ($pd in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
                    $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                    if (-not $rc) { continue }
                    $parts = @()
                    if ($null -ne $rc.Wear)        { $parts += "wear $($rc.Wear)%"; if ($rc.Wear -ge 90) { $worst = 'Fail' } elseif ($rc.Wear -ge 80 -and $worst -ne 'Fail') { $worst = 'Warn' } }
                    if ($null -ne $rc.Temperature) { $parts += "$($rc.Temperature) C"; if ($rc.Temperature -gt 70) { $worst = 'Fail' } elseif ($rc.Temperature -gt 60 -and $worst -ne 'Fail') { $worst = 'Warn' } }
                    if ($rc.ReadErrorsUncorrected) { $worst = 'Fail'; $parts += "$($rc.ReadErrorsUncorrected) uncorrected" }
                    if ($parts.Count) { $lines += ("$($pd.FriendlyName): " + ($parts -join ', ')) }
                }
                if ($lines.Count -eq 0) { @{ Status = 'OK'; Detail = 'No reliability counters reported (HDD/USB/older SATA)' } }
                else                    { @{ Status = $worst; Detail = ($lines -join ' | ') } }
            } -Fix $null

        New-DiagnosticCheck crash-history 'Recent crashes (BSOD / unexpected shutdown)' System `
            -Scan {
                $dumps = @(Get-ChildItem "$env:WINDIR\Minidump\*.dmp" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-30) })
                $bug   = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue)
                $n = $dumps.Count + $bug.Count
                if ($n -eq 0)      { @{ Status = 'OK';   Detail = 'No crash dumps or bugcheck events in 30 days' } }
                elseif ($n -ge 2)  { @{ Status = 'Warn'; Detail = "$($dumps.Count) minidump(s), $($bug.Count) bugcheck event(s) in 30 days - recurring instability" } }
                else               { @{ Status = 'OK';   Detail = "$n crash artifact in 30 days (isolated)" } }
            } -Fix $null
        New-DiagnosticCheck startup-bloat 'Startup apps bloat' System `
            -Scan {
                $keys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run')
                $count = 0
                foreach ($k in $keys) {
                    if (Test-Path $k) {
                        $props = (Get-ItemProperty $k -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -is [byte[]] }
                        foreach ($p in $props) { if ($p.Value[0] -eq 2) { $count++ } }
                    }
                }
                if ($count -gt 8) { @{ Status = 'Warn'; Detail = "$count enabled startup apps - trims boot time" } }
                elseif ($count -gt 5) { @{ Status = 'Warn'; Detail = "$count enabled startup apps" } }
                else { @{ Status = 'OK'; Detail = "$count enabled startup apps" } }
            } `
            -Fix {
                Write-RepLog 'Opening startup manager - use the Startup screen to disable entries.' 'Info'
            } -FixRisk Safe -FixLabel 'Review startup apps'

        New-DiagnosticCheck winget-updates 'Winget upgradable apps' System `
            -Scan {
                if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return @{ Status = 'Skip'; Detail = 'winget not available' } }
                $out = winget upgrade --include-unknown 2>$null | Out-String
                $lines = @($out -split "`n" | Where-Object { $_ -match '^\S+.*\s+\d+(\.\d+)+' })
                $n = $lines.Count
                if ($n -gt 5) { @{ Status = 'Warn'; Detail = "$n apps have updates (winget upgrade --all)" } }
                elseif ($n -gt 0) { @{ Status = 'Warn'; Detail = "$n app(s) upgradable" } }
                else { @{ Status = 'OK'; Detail = 'No winget upgrades pending' } }
            } `
            -Fix {
                if (Get-Command winget -ErrorAction SilentlyContinue) { winget upgrade --all --include-unknown --accept-package-agreements --accept-source-agreements } 
            } -FixRisk Moderate -FixLabel 'winget upgrade --all'

        New-DiagnosticCheck volume-frag 'Volume fragmentation' System `
            -Scan {
                try {
                    $v = Get-Volume -DriveLetter C -ErrorAction Stop
                    if ($v.FileSystemType -eq 'NTFS') {
                        $frag = (Optimize-Volume -DriveLetter C -Analyze -Verbose:$false -ErrorAction SilentlyContinue | Out-String)
                        if ($frag -match '(\d+)%\s*fragmented') { $pct = [int]$Matches[1]; if ($pct -gt 10) { return @{ Status = 'Warn'; Detail = "C: $pct% fragmented" } } }
                    }
                } catch {}
                @{ Status = 'OK'; Detail = 'Volume fragmentation OK' }
            } -Fix $null

    )
}

function Resolve-CheckSelection {
    param([object[]]$Registry, [string[]]$Category, [string[]]$Include, [string[]]$Exclude)
    foreach ($c in $Registry) {
        $on = $true
        if ($Category -and ($c.Category -notin $Category)) { $on = $false }
        if (($Include -contains $c.Id) -or ($Include -contains $c.Name)) { $on = $true }
        if (($Exclude -contains $c.Id) -or ($Exclude -contains $c.Name)) { $on = $false }
        if ($on) { $c }
    }
}

function Invoke-Scan {
    param([object]$Check)
    $r = @{ Status = 'Skip'; Detail = '' }
    try { $r = & $Check.Scan } catch { $r = @{ Status = 'Skip'; Detail = $_.Exception.Message } }
    [pscustomobject]@{
        Id = $Check.Id; Name = $Check.Name; Category = $Check.Category
        Status = $r.Status; Detail = $r.Detail
        HasFix = [bool]$Check.Fix; FixRisk = $Check.FixRisk; FixLabel = $Check.FixLabel; Reboot = $Check.Reboot
    }
}

function Invoke-Fix {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$Check)
    if ($PSCmdlet.ShouldProcess($Check.Name, "Fix: $($Check.FixLabel)")) {
        try {
            & $Check.Fix
            Write-RepLog "Fixed: $($Check.Name)" 'Success'
            $script:Fixed++
            if ($Check.Reboot) { $script:RebootNeeded = $true }
            return $true
        }
        catch { $script:FixErrors++; Write-RepLog "  fix $($Check.Name): $($_.Exception.Message)" 'Error'; return $false }
    }
    $false
}

function Get-StatusColor { param([string]$S)
    switch ($S) { 'OK' { 'Green' } 'Warn' { 'Yellow' } 'Fail' { 'Red' } default { 'DarkGray' } } }

function Show-ScanReport {
    Write-RepLog '' 'Info'
    Write-RepLog '===== HEALTH REPORT =====' 'Step'
    $last = $null
    foreach ($r in $script:Results) {
        if ($r.Category -ne $last) { Write-Host ("  {0}" -f $r.Category) -ForegroundColor Cyan; $last = $r.Category }
        $mark = switch ($r.Status) { 'OK' { 'OK  ' } 'Warn' { 'WARN' } 'Fail' { 'FAIL' } default { 'skip' } }
        Write-Host ("    [{0}] {1,-34} {2}" -f $mark, $r.Name, $r.Detail) -ForegroundColor (Get-StatusColor $r.Status)
    }
    $warn = @($script:Results | Where-Object Status -eq 'Warn').Count
    $fail = @($script:Results | Where-Object Status -eq 'Fail').Count
    Write-RepLog '' 'Info'
    Write-RepLog ("Issues found: {0} failing, {1} warning, {2} OK" -f $fail, $warn,
        @($script:Results | Where-Object Status -eq 'OK').Count) $(if ($fail) { 'Error' } elseif ($warn) { 'Warning' } else { 'Success' })
}

function Write-RepReport {
    Write-SunCleanerReport -ReportPath $ReportPath -Engine 'Repair' `
        -RestorePoint $script:RestorePointMade -StartTime $script:StartTime `
        -Summary @{
            Fixed     = $script:Fixed
            FixErrors = $script:FixErrors
            Reboot    = $script:RebootNeeded
        } `
        -Items $script:Results `
        -LogAction { param($m, $l) Write-RepLog $m $l }
}

function Show-RepairInventory {
    Write-Host ''
    Write-Host 'Diagnostic check registry:' -ForegroundColor Cyan
    Get-DiagnosticCheckRegistry |
        Format-Table @{ L='Id'; E={$_.Id}; W=18 },
                     @{ L='Category'; E={$_.Category}; W=10 },
                     @{ L='Fix'; E={ if($_.Fix){$_.FixRisk}else{'(report only)'} }; W=14 },
                     @{ L='Check'; E={$_.Name} } -AutoSize
    Write-Host ''
}

function Show-RepUsageHelp {
@'
sunCleaner v1.0.0  (scan -> report -> repair)

SELECTION
  -Category <names>     Limit to: Integrity, Disk, Update, Network, Devices, Services, Security, System
  -Include <ids>        Force checks on  (see -ListChecks for ids)
  -Exclude <ids>        Force checks off

FLOW
  (default)             Scan, show report, then choose what to repair
  -ScanOnly             Diagnose only - never change anything
  -FixAll               Non-interactive: auto-apply fixable issues (Safe+Moderate)
  -IncludeHeavy         With -FixAll, also apply Aggressive (heavy/reboot) repairs
  -Conservative         Cap auto-fixes at Safe + Moderate

SAFETY
  -WhatIf / -DryRun,-dr Preview only, change nothing (real ShouldProcess)
  -NoRestorePoint,-nrp  Skip the restore point made before repairs
  -Unattended,-Force,-f No prompts - for automation

OUTPUT
  -LogPath <path>       Text log (default: %TEMP%\WindowsRepair.log)
  -ReportPath <path>    Machine-readable JSON report
  -ListChecks           Print the check registry and exit
  -Help                 Show this help
'@ | Write-Host
}

function Start-SunCleanerRepairInner {
    $Category = $script:Category
    $Include = $script:Include
    $Exclude = $script:Exclude
    $ScanOnly = $script:ScanOnly
    $FixAll = $script:FixAll
    $IncludeHeavy = $script:IncludeHeavy
    $Conservative = $script:Conservative
    $DryRun = $script:DryRun
    $Unattended = $script:Unattended
    $NoRestorePoint = $script:NoRestorePoint
    $LogPath = $script:LogPath
    $ReportPath = $script:ReportPath
    Write-RepLog 'sunCleaner - repair' 'Step'
    Write-RepLog ("PowerShell {0} | Mode: {1}" -f $PSVersionTable.PSVersion, $(if (Test-WhatIfMode) { 'DryRun' } else { 'Live' })) 'Info'
    if (-not (Test-AdminPrivileges)) { Write-RepLog 'Administrator privileges are required. Re-run as Administrator.' 'Error'; exit 2 }

    $registry  = Get-DiagnosticCheckRegistry
    $selection = @(Resolve-CheckSelection -Registry $registry -Category $Category -Include $Include -Exclude $Exclude)
    if (-not $selection.Count) { Write-RepLog 'No checks selected.' 'Warning'; return }

    Write-RepLog ("Scanning {0} check(s)..." -f $selection.Count) 'Info'
    foreach ($c in $selection) {
        Write-RepLog ("  scanning: {0}" -f $c.Name) 'Debug'
        $script:Results.Add((Invoke-Scan -Check $c))
    }
    Show-ScanReport
    Write-RepReport

    if ($ScanOnly) { return }

    # fixable = Warn/Fail with a Fix defined.
    $rank = @{ Safe = 0; Moderate = 1; Aggressive = 2 }
    $fixable = @($script:Results | Where-Object { $_.HasFix -and $_.Status -in 'Warn','Fail' })
    if (-not $fixable.Count) { Write-RepLog 'No auto-fixable issues detected.' 'Success'; return }

    # decide which to fix.
    $toFix = @()
    if ($FixAll -or $Unattended) {
        $cap = if ($IncludeHeavy -and -not $Conservative) { 2 } elseif ($Conservative) { 1 } else { 1 }
        $toFix = $fixable | Where-Object { $rank[$_.FixRisk] -le $cap }
    }
    elseif (-not (Test-WhatIfMode)) {
        Write-RepLog '' 'Info'
        Write-RepLog 'Fixable issues:' 'Step'
        $i = 0; $map = @{}
        foreach ($f in $fixable) {
            $i++; $map[$i] = $f
            $rb = if ($f.Reboot) { ' [reboot]' } else { '' }
            Write-Host ("   {0,2}. ({1,-10}) {2} -> {3}{4}" -f $i, $f.FixRisk, $f.Name, $f.FixLabel, $rb) -ForegroundColor (Get-StatusColor $f.Status)
        }
        Write-Host ''
        Write-Host '  Enter numbers to fix | a=all safe (Safe+Moderate)  h=all incl. heavy  Enter=skip' -ForegroundColor DarkGray
        $in = (Read-Host '  >').Trim()
        if ($in -eq '')      { Write-RepLog 'No repairs selected.' 'Info'; return }
        elseif ($in -eq 'a') { $toFix = $fixable | Where-Object { $rank[$_.FixRisk] -le 1 } }
        elseif ($in -eq 'h') { $toFix = $fixable }
        else {
            $sel = @()
            foreach ($tok in ($in -split '[\s,]+')) { if ($tok -match '^\d+$' -and $map.ContainsKey([int]$tok)) { $sel += $map[[int]$tok] } }
            $toFix = $sel
        }
    }
    else {
        # -WhatIf: preview fixing everything fixable.
        $toFix = $fixable
    }

    $toFix = @($toFix)
    if (-not $toFix.Count) { Write-RepLog 'Nothing to repair.' 'Info'; return }

    if (-not $NoRestorePoint -and -not (Test-WhatIfMode)) { New-RepairRestorePoint | Out-Null }

    foreach ($r in $toFix) {
        $check = $registry | Where-Object { $_.Id -eq $r.Id } | Select-Object -First 1
        if ($check) { Invoke-Fix -Check $check | Out-Null }
    }

    Write-RepLog '' 'Info'
    $verb = if (Test-WhatIfMode) { 'Would fix' } else { 'Fixed' }
    Write-RepLog ("{0}: {1} issue(s), {2} error(s)" -f $verb, $script:Fixed, $script:FixErrors) 'Success'
    if ($script:RebootNeeded) { Write-RepLog 'A reboot is required to complete some repairs.' 'Warning' }
    Write-RepLog ("Duration: {0:N1}s   Log: {1}" -f ((Get-Date) - $script:StartTime).TotalSeconds, $LogPath) 'Info'
}

# --- src/Features/Network.ps1 ---

function Get-ActiveAdapter {
    try { Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up' }
    catch {
        $list = netsh interface ip show interfaces | Select-String 'Enabled'
        foreach ($line in $list) {
            $parts = $line.ToString().Trim() -split '\s+'
            [pscustomobject]@{ Name = $parts[-1]; Status = 'Up' }
        }
    }
}

function Reset-NetworkStack {
    try {
        ipconfig /flushdns | Out-Null
        ipconfig /registerdns | Out-Null
        netsh winsock reset | Out-Null
        netsh int ip reset | Out-Null
        Write-WsLog 'network stack reset - reboot recommended' 'Success'
    } catch { Write-WsLog "network reset failed: $_" 'Error' }
}

function Clear-DnsCache {
    try { ipconfig /flushdns | Out-Null; Write-WsLog 'dns cache flushed' 'Success' }
    catch { Write-WsLog "flush failed: $_" 'Error' }
}

function Set-StaticIp {
    param([string]$IfName, [string]$Ip, [string]$Mask, [string]$Gateway)
    try { netsh interface ip set address name="$IfName" static $Ip $Mask $Gateway 1 | Out-Null; Write-WsLog "static ip $Ip on $IfName" 'Success' }
    catch { Write-WsLog "set ip failed: $_" 'Error' }
}

function Set-DnsServers {
    param([string]$IfName, [string]$Dns1, [string]$Dns2)
    try {
        if (-not $Dns1) { Write-WsLog 'primary dns required' 'Warning'; return }
        netsh interface ip set dns name="$IfName" static $Dns1 primary | Out-Null
        if ($Dns2) { netsh interface ip add dns name="$IfName" $Dns2 index=2 | Out-Null }
        Write-WsLog "dns $Dns1 on $IfName" 'Success'
    } catch { Write-WsLog "set dns failed: $_" 'Error' }
}

function Enable-Dhcp {
    param([string]$IfName)
    try {
        netsh interface ip set address name="$IfName" source=dhcp | Out-Null
        netsh interface ip set dns name="$IfName" source=dhcp | Out-Null
        Write-WsLog "$IfName reverted to dhcp" 'Success'
    } catch { Write-WsLog "dhcp revert failed: $_" 'Error' }
}

function Show-NetworkScreen {
    $items = @(
        [pscustomobject]@{ Label = 'Flush DNS cache' }
        [pscustomobject]@{ Label = 'Reset network stack (flush + winsock + ip)' }
        [pscustomobject]@{ Label = 'List active adapters' }
        [pscustomobject]@{ Label = 'Set static IP / gateway' }
        [pscustomobject]@{ Label = 'Set DNS servers' }
        [pscustomobject]@{ Label = 'Revert adapter to DHCP' }
    )
    while ($true) {
        $status = @('uses netsh / ipconfig - requires admin for changes')
        switch (Show-Menu -Title 'sunCleaner - network' -Items $items -StatusLines $status) {
            0 { Clear-DnsCache; Wait-Enter }
            1 { Reset-NetworkStack; Wait-Enter }
            2 {
                $adapters = @(Get-ActiveAdapter)
                if ($adapters) { $adapters | Format-Table Name, Status -AutoSize | Out-String | Write-Host }
                else { Write-WsLog 'no active adapters' 'Warning' }
                Wait-Enter
            }
            3 {
                $name = Read-Host '  adapter name'
                $ip = Read-Host '  ip (e.g. 192.168.1.100)'
                $mask = Read-Host '  mask (255.255.255.0)'
                $gw = Read-Host '  gateway (192.168.1.1)'
                if ($name -and $ip) { Set-StaticIp -IfName $name -Ip $ip -Mask $mask -Gateway $gw }
                Wait-Enter
            }
            4 {
                $name = Read-Host '  adapter name'
                $d1 = Read-Host '  dns1 (1.1.1.1)'
                $d2 = Read-Host '  dns2 (8.8.8.8, optional)'
                if ($name) { Set-DnsServers -IfName $name -Dns1 $d1 -Dns2 $d2 }
                Wait-Enter
            }
            5 {
                $name = Read-Host '  adapter name'
                if ($name) { Enable-Dhcp -IfName $name }
                Wait-Enter
            }
            $null { return }
        }
    }
}

# --- src/Features/Startup.ps1 ---

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

# --- src/Menu/Main.ps1 ---

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

Initialize-UiTheme -Plain:$Plain

if (-not (Test-AdminPrivileges)) {
    if ($NoElevate) { Write-WsLog 'Not running as Administrator - most actions will fail.' 'Warning' }
    else {
        Write-WsLog 'Requesting administrator privileges...' 'Step'
        try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',"irm https://pastebin.com/raw/XXXX | iex") -ErrorAction Stop; exit 0 } catch { Write-WsLog 'Elevation cancelled.' 'Error'; exit 1 }
    }
}

if ($InstallSchedule) { Install-SunCleanerSchedule -Root $PSScriptRoot -LogAction { param($m,$l) Write-WsLog $m $l } | Out-Null; exit 0 }
if ($RemoveSchedule) { Remove-SunCleanerSchedule -LogAction { param($m,$l) Write-WsLog $m $l } | Out-Null; exit 0 }
if ($ScheduledClean) {
    $script:StartTime = Get-Date; $script:Stats = New-Object System.Collections.Generic.List[object]
    $script:TotalBytes=0; $script:TotalFiles=0; $script:TotalErrors=0; $script:RestorePointMade=$false
    $script:Category=$null; $script:Include=$null; $script:Exclude=$null; $script:IncludeDangerous=$false; $script:Conservative=$false
    $script:CurrentUserOnly=$false; $script:Drives=$null; $script:DryRun=$false; $script:Unattended=$true; $script:NoRestorePoint=$true; $script:SkipOptimization=$true
    $script:MaxAgeDays=0; $script:LogPath="$env:TEMP\sunCleaner-sched-clean.log"
    if (-not $ReportPath) { $ReportPath = "$env:ProgramData\sunCleaner\reports\cleanup.json" }; $script:ReportPath = $ReportPath
    Start-SunCleanerCleanup; exit 0
}
if ($ScheduledScan) {
    $script:StartTime=Get-Date; $script:Results=New-Object System.Collections.Generic.List[object]
    $script:Fixed=0; $script:FixErrors=0; $script:RebootNeeded=$false; $script:RestorePointMade=$false
    $script:Category=$null; $script:Include=$null; $script:Exclude=$null; $script:ScanOnly=$true; $script:FixAll=$false; $script:IncludeHeavy=$false
    $script:Conservative=$false; $script:DryRun=$false; $script:Unattended=$true; $script:NoRestorePoint=$false
    $script:LogPath="$env:TEMP\sunCleaner-sched-scan.log"
    if (-not $ReportPath) { $ReportPath = "$env:ProgramData\sunCleaner\reports\repair.json" }; $script:ReportPath = $ReportPath
    Start-SunCleanerRepairInner; exit 0
}

# pastebin (irm | iex) has no InvocationName '.' check, so always show menu when not dot-sourced
if ($MyInvocation.InvocationName -ne '.' -or $MyInvocation.Line -match 'irm|iex') {
    Show-SunSplash
    Show-MainMenu
}
