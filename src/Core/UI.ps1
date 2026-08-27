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
