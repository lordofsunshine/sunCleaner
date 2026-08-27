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
