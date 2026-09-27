$script:DhcpDiscover = 1
$script:DhcpOffer = 2
$script:DhcpRequest = 3
$script:DhcpDecline = 4
$script:DhcpAck = 5
$script:DhcpNak = 6
$script:DhcpRelease = 7
$script:DhcpInform = 8

function Get-DorPXEDhcpTypeName {
    param([int]$Type)
    switch ($Type) {
        1 { 'DISCOVER' } 2 { 'OFFER' } 3 { 'REQUEST' } 4 { 'DECLINE' }
        5 { 'ACK' } 6 { 'NAK' } 7 { 'RELEASE' } 8 { 'INFORM' } default { "TIPO$Type" }
    }
}

function ConvertTo-DorPXEAscii { param([string]$Text) ,([Text.Encoding]::ASCII.GetBytes($Text)) }

function ConvertTo-DorPXEU16Bytes {
    param([int]$Value)
    , ([byte[]]@( (($Value -shr 8) -band 0xFF), ($Value -band 0xFF) ))
}

function Get-DorPXEDhcpOptionBytes {
    param($Options, [int]$Code)
    if ($null -eq $Options) { return $null }
    if ($Options.ContainsKey($Code)) { return $Options[$Code] }
    return $null
}

function Get-DorPXEDhcpOptionText {
    param($Options, [int]$Code)
    $b = Get-DorPXEDhcpOptionBytes -Options $Options -Code $Code
    if (-not $b) { return $null }
    $t = [Text.Encoding]::ASCII.GetString([byte[]]$b)
    return ($t -replace "`0.*$", '').Trim()
}

function Get-DorPXEDhcpOptionU16 {
    param($Options, [int]$Code)
    $b = Get-DorPXEDhcpOptionBytes -Options $Options -Code $Code
    if (-not $b -or $b.Length -lt 1) { return $null }
    if ($b.Length -eq 1) { return [int]$b[0] }
    return (([int]$b[0] -shl 8) -bor [int]$b[1])
}

function Get-DorPXEDhcpOptionIp {
    param($Options, [int]$Code)
    $b = Get-DorPXEDhcpOptionBytes -Options $Options -Code $Code
    if (-not $b -or $b.Length -lt 4) { return $null }
    return "$([int]$b[0]).$([int]$b[1]).$([int]$b[2]).$([int]$b[3])"
}

function ConvertFrom-DorPXEDhcpPacket {
    [CmdletBinding()]
    param([byte[]]$Bytes, [switch]$AllowReply)
    if (-not $Bytes -or $Bytes.Length -lt 240) { return $null }
    if ($Bytes[0] -ne 1 -and -not $AllowReply) { return $null }
    $o = [ordered]@{}
    $o['Op'] = [int]$Bytes[0]
    $o['Htype'] = [int]$Bytes[1]
    $o['Hlen'] = [int]$Bytes[2]
    $o['Hops'] = [int]$Bytes[3]
    $o['Xid'] = [byte[]]@($Bytes[4], $Bytes[5], $Bytes[6], $Bytes[7])
    $o['Secs'] = (([int]$Bytes[8] -shl 8) -bor [int]$Bytes[9])
    $o['Flags'] = (([int]$Bytes[10] -shl 8) -bor [int]$Bytes[11])
    $o['Ciaddr'] = ConvertFrom-DorPXEIpBytes ([byte[]]@($Bytes[12], $Bytes[13], $Bytes[14], $Bytes[15]))
    $o['Yiaddr'] = ConvertFrom-DorPXEIpBytes ([byte[]]@($Bytes[16], $Bytes[17], $Bytes[18], $Bytes[19]))
    $o['Siaddr'] = ConvertFrom-DorPXEIpBytes ([byte[]]@($Bytes[20], $Bytes[21], $Bytes[22], $Bytes[23]))
    $o['Giaddr'] = ConvertFrom-DorPXEIpBytes ([byte[]]@($Bytes[24], $Bytes[25], $Bytes[26], $Bytes[27]))
    $hlen = [Math]::Min([Math]::Max($o['Hlen'], 1), 16)
    $mac = New-Object byte[] 6
    for ($i = 0; $i -lt $hlen; $i++) { $mac[$i] = $Bytes[28 + $i] }
    $o['Mac'] = ConvertTo-DorPXEMac (($mac | ForEach-Object { $_.ToString('X2') }) -join '')
    $o['Sname'] = ([Text.Encoding]::ASCII.GetString([byte[]]$Bytes[44..107]) -replace "`0.*$", '')
    $o['File'] = ([Text.Encoding]::ASCII.GetString([byte[]]$Bytes[108..235]) -replace "`0.*$", '')
    $o['Options'] = @{}
    if ($Bytes[236] -eq 99 -and $Bytes[237] -eq 130 -and $Bytes[238] -eq 83 -and $Bytes[239] -eq 99) {
        $i = 240
        while ($i -lt $Bytes.Length) {
            $code = [int]$Bytes[$i]
            if ($code -eq 0 -or $code -eq 255) { break }
            if ($code -eq 1) { $i++; continue }
            if ($i + 1 -ge $Bytes.Length) { break }
            $len = [int]$Bytes[$i + 1]
            if ($i + 2 + $len - 1 -gt $Bytes.Length - 1) { break }
            $val = New-Object byte[] $len
            for ($k = 0; $k -lt $len; $k++) { $val[$k] = $Bytes[$i + 2 + $k] }
            $o['Options'][$code] = $val
            $i += 2 + $len
        }
    }
    $o['MessageType'] = { Get-DorPXEDhcpOptionU16 -Options $o['Options'] -Code 53 }
    $o['ClientArch'] = { Get-DorPXEDhcpOptionU16 -Options $o['Options'] -Code 93 }
    $o['UserClass'] = { Get-DorPXEDhcpOptionText -Options $o['Options'] -Code 77 }
    $o['VendorClass'] = { Get-DorPXEDhcpOptionText -Options $o['Options'] -Code 60 }
    $o['ClientId'] = { Get-DorPXEDhcpOptionBytes -Options $o['Options'] -Code 61 }
    $o['ServerId'] = { Get-DorPXEDhcpOptionBytes -Options $o['Options'] -Code 54 }
    $o['ParamRequest'] = { Get-DorPXEDhcpOptionBytes -Options $o['Options'] -Code 55 }
    return [pscustomobject]$o
}

function Test-DorPXEPxeClient {
    param($Packet)
    if ($null -eq $Packet) { return $false }
    $arch = Get-DorPXEDhcpOptionU16 -Options $Packet.Options -Code 93
    if ($null -ne $arch) { return $true }
    $vc = Get-DorPXEDhcpOptionText -Options $Packet.Options -Code 60
    if ($vc -and ($vc -match '^(PXEClient|HTTPClient)') ) { return $true }
    $uc = Get-DorPXEDhcpOptionText -Options $Packet.Options -Code 77
    if ($uc -and ($uc -match 'iPXE')) { return $true }
    return $false
}

function Test-DorPXEIpxeClient {
    param($Packet)
    if ($null -eq $Packet) { return $false }
    $uc = Get-DorPXEDhcpOptionText -Options $Packet.Options -Code 77
    if ($uc -and ($uc -match 'iPXE')) { return $true }
    $vc = Get-DorPXEDhcpOptionText -Options $Packet.Options -Code 60
    if ($vc -and ($vc -match 'iPXE')) { return $true }
    return $false
}

function New-DorPXEDhcpReply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][int]$MessageType,
        [string]$ServerId,
        [string]$NextServer,
        [string]$BootFile,
        [hashtable]$Options,
        [int[]]$EchoOptions = @(12, 60, 61, 77, 93, 94, 97)
    )
    $buf = New-Object byte[] 576
    $buf[0] = 2
    $buf[1] = $Request.Htype
    $buf[2] = $Request.Hlen
    $buf[3] = 0
    [Array]::Copy($Request.Xid, 0, $buf, 4, 4)
    $secs = ConvertTo-DorPXEU16Bytes $Request.Secs; [Array]::Copy($secs, 0, $buf, 8, 2)
    $flg = ConvertTo-DorPXEU16Bytes ($Request.Flags -bor 0x8000)
    [Array]::Copy($flg, 0, $buf, 10, 2)
    $a = ConvertTo-DorPXEIpBytes $Request.Ciaddr; [Array]::Copy($a, 0, $buf, 12, 4)
    $a = ConvertTo-DorPXEIpBytes $Request.Yiaddr; [Array]::Copy($a, 0, $buf, 16, 4)
    if ($NextServer) { $a = ConvertTo-DorPXEIpBytes $NextServer; [Array]::Copy($a, 0, $buf, 20, 4) }
    $a = ConvertTo-DorPXEIpBytes $Request.Giaddr; [Array]::Copy($a, 0, $buf, 24, 4)
    $hexMac = ($Request.Mac -replace '[:\-]', '')
    for ($i = 0; $i -lt 6; $i++) { $buf[28 + $i] = [Convert]::ToByte($hexMac.Substring($i * 2, 2), 16) }
    $hostName = if ($ServerId) { $ServerId } else { '0.0.0.0' }
    $sn = ConvertTo-DorPXEAscii $hostName
    [Array]::Copy($sn, 0, $buf, 44, [Math]::Min($sn.Length, 63))
    if ($BootFile) {
        $bf = ConvertTo-DorPXEAscii $BootFile
        [Array]::Copy($bf, 0, $buf, 108, [Math]::Min($bf.Length, 127))
    }
    $buf[236] = 99; $buf[237] = 130; $buf[238] = 83; $buf[239] = 99

    $opt = New-Object System.Collections.Generic.List[byte]
    $opt.Add(53); $opt.Add(1); $opt.Add([byte]$MessageType)
    $opt.Add(54); $opt.Add(4); $opt.AddRange((ConvertTo-DorPXEIpBytes $ServerId))
    foreach ($code in $EchoOptions) {
        $v = Get-DorPXEDhcpOptionBytes -Options $Request.Options -Code $code
        if ($v -and $v.Length -gt 0 -and $v.Length -le 255) {
            $opt.Add([byte]$code); $opt.Add([byte]$v.Length)
            foreach ($b in $v) { $opt.Add([byte]$b) }
        }
    }
    if ($NextServer) { $opt.Add(66); $v = ConvertTo-DorPXEAscii $NextServer; $opt.Add([byte]$v.Length); foreach ($b in $v) { $opt.Add($b) } }
    if ($BootFile) { $opt.Add(67); $v = ConvertTo-DorPXEAscii $BootFile; $opt.Add([byte]$v.Length); foreach ($b in $v) { $opt.Add($b) } }
    if ($Options) {
        foreach ($code in ($Options.Keys | Sort-Object)) {
            $v = $Options[$code]
            if ($null -eq $v) { continue }
            if ($v -is [int] -or $v -is [long]) { $v = ConvertTo-DorPXEU16Bytes ([int]$v) }
            elseif ($v -is [string]) { $v = ConvertTo-DorPXEAscii $v }
            $v = [byte[]]$v
            if ($v.Length -gt 255) { $v = $v[0..254] }
            $opt.Add([byte]$code); $opt.Add([byte]$v.Length)
            foreach ($b in $v) { $opt.Add([byte]$b) }
        }
    }
    $opt.Add(255)
    [Array]::Copy($opt.ToArray(), 0, $buf, 240, [Math]::Min($opt.Count, 335))
    , $buf
}

function Get-DorPXEDhcpBootPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Packet
    )
    $arch = Get-DorPXEDhcpOptionU16 -Options $Packet.Options -Code 93
    if ($null -eq $arch) {
        $vc = Get-DorPXEDhcpOptionText -Options $Packet.Options -Code 60
        if ($vc -and $vc -match 'Arch:(\d{1,5})') { $arch = [int]$Matches[1] } else { $arch = 0 }
    }
    $isIpxe = Test-DorPXEIpxeClient -Packet $Packet
    $arm = Test-DorPXEArmArchitecture -Architecture $arch
    $bootFile = $null
    $reason = $null
    if ($Config.Dhcp.BootFile) { $bootFile = $Config.Dhcp.BootFile }
    elseif ($arm) { $reason = "arquitetura ARM (op93=$arch) nao suportada" }
    elseif ($isIpxe) { $bootFile = 'autoexec.ipxe'; $reason = '2o estagio iPXE' }
    else {
        $bootFile = Get-DorPXEArchBootFile -Architecture $arch
        if (-not $bootFile) { $reason = "arquitetura desconhecida (op93=$arch)" }
        else { $reason = "1o estagio ($((Get-DorPXEArchName -Architecture $arch)))" }
    }
    [pscustomobject]@{
        Architecture = $arch
        ArchName     = (Get-DorPXEArchName -Architecture $arch)
        IsIpxe       = $isIpxe
        BootFile     = $bootFile
        Reason       = $reason
    }
}

function Get-DorPXEDhcpDestination {
    param($Packet)
    if ($Packet.Giaddr -and $Packet.Giaddr -ne '0.0.0.0') {
        return [pscustomobject]@{ Address = $Packet.Giaddr; Port = 67; Via = 'relay' }
    }
    if ($Packet.Ciaddr -and $Packet.Ciaddr -ne '0.0.0.0') {
        return [pscustomobject]@{ Address = $Packet.Ciaddr; Port = 68; Via = 'unicast' }
    }
    return [pscustomobject]@{ Address = '255.255.255.255'; Port = 68; Via = 'broadcast' }
}

function Start-DorPXEDhcpServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job
    )
    $Config = $Job.Config
    $State = $Job.State
    $bind = if ($Config.Dhcp.BindAddress -and $Config.Dhcp.BindAddress -ne 'auto') { $Config.Dhcp.BindAddress } else { '0.0.0.0' }
    $serverId = $Job.ServerAddress
    $nextServer = $Config.Dhcp.NextServer
    if (-not $nextServer -or $nextServer -eq 'auto') { $nextServer = $serverId }
    $udp = $null
    try {
        $udp = New-Object Net.Sockets.UdpClient([Net.IPEndPoint]::new([Net.IPAddress]::Parse($bind), 67))
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 400
    }
    catch {
        Write-DorPXELog "DHCP: falha ao abrir UDP/67 em $bind - $($_.Exception.Message)" -Level Error -Component dhcp
        return
    }
    Write-DorPXELog ("DHCP proxyDHCP ouvindo em {0}:67 (server-id {1}, next-server {2}, modo {3})" -f `
            $bind, $serverId, $nextServer, $Config.Dhcp.Mode) -Level Info -Component dhcp
    Write-DorPXELog 'DHCP: apenas options 66/67 - o endereÃ§amento IP continua no seu Windows Server DHCP' -Level Info -Component dhcp

    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
    while (-not $Job.Stop.IsCancellationRequested) {
        try { $bytes = $udp.Receive([ref]$ep) }
        catch [Net.Sockets.SocketException] { continue }
        catch { continue }
        try {
            $src = $ep.Address.ToString()
            $req = ConvertFrom-DorPXEDhcpPacket -Bytes $bytes
            if (-not $req) { continue }
            $mt = Get-DorPXEDhcpOptionU16 -Options $req.Options -Code 53
            if ($null -eq $mt) { continue }
            $State.Stats.DhcpRequests = $State.Stats.DhcpRequests + 1
            $mtName = Get-DorPXEDhcpTypeName -Type $mt

            if (-not (Test-DorPXEPxeClient -Packet $req)) { continue }

            $decision = Resolve-DorPXEDecision -Config $Config -Mac $req.Mac -Ip $req.Ciaddr
            $plan = Get-DorPXEDhcpBootPlan -Config $Config -Packet $req
            $dhcpLog = $State.DhcpLog
            $entry = [pscustomobject]@{
                At = Get-Date; Mac = $req.Mac; Src = $src; Type = $mtName
                Arch = $plan.ArchName; BootFile = $plan.BootFile; Via = (Get-DorPXEDhcpDestination -Packet $req).Via
                Allowed = $decision.Allowed; Action = $decision.Action; Profile = $decision.Profile
                Model = $decision.Model; Reason = $decision.Reason
            }
            $dhcpLog.Add($entry)
            while ($dhcpLog.Count -gt 300) { $dhcpLog.RemoveAt(0) | Out-Null }

            $replies = @()
            if ($mt -eq $script:DhcpDiscover) { $replies = @($script:DhcpOffer) }
            elseif ($mt -eq $script:DhcpRequest -and $Config.Dhcp.ProxyAck) { $replies = @($script:DhcpAck) }
            elseif ($mt -eq $script:DhcpInform) { $replies = @($script:DhcpAck) }
            if ($replies.Count -eq 0) { continue }

            $extra = @{}
            if ($Config.Dhcp.ExtraOptions) { foreach ($k in $Config.Dhcp.ExtraOptions.Keys) { $extra[[int]$k] = $Config.Dhcp.ExtraOptions[$k] } }

            $bootFile = $null
            $denyReason = $null
            if (-not $plan.BootFile) { $denyReason = $plan.Reason }
            elseif (-not $decision.Allowed) {
                if ($Config.Policy.DefaultAction -eq 'Local') { $denyReason = 'politica: nao autorizado (Local)' }
            }
            if ($denyReason) {
                $bootFile = $null
                $State.Stats.DhcpDenied = $State.Stats.DhcpDenied + 1
                Write-DorPXELog ("DHCP {0} {1} via {2}: SEM opcoes de boot - {3}" -f $mtName, $req.Mac, $src, $denyReason) -Level Info -Component dhcp
            }
            else {
                $bootFile = $plan.BootFile
                Write-DorPXELog ("DHCP {0} {1} via {2} -> file={3} ({4})" -f $mtName, $req.Mac, $src, $bootFile, $plan.Reason) -Level Info -Component dhcp
            }

            foreach ($rt in $replies) {
                $pkt = New-DorPXEDhcpReply -Request $req -MessageType $rt -ServerId $serverId `
                    -NextServer $(if ($bootFile) { $nextServer } else { $null }) `
                    -BootFile $bootFile -Options $extra
                $dest = Get-DorPXEDhcpDestination -Packet $req
                $epOut = New-Object Net.IPEndPoint([Net.IPAddress]::Parse($dest.Address), $dest.Port)
                [void]$udp.Send($pkt, $pkt.Length, $epOut)
                $State.Stats.DhcpOffers = $State.Stats.DhcpOffers + 1
                # resposta unicast extra para clientes de teste em loopback (a broadcast de 255.255.255.255:68
                # nao alcanca um socket efemero); em rede real apenas o destino DHCP padrao e usado
                if ($src -like '127.*' -and $ep.Port -ne 68) {
                    $epLoop = New-Object Net.IPEndPoint([Net.IPAddress]::Loopback, $ep.Port)
                    [void]$udp.Send($pkt, $pkt.Length, $epLoop)
                    Write-DorPXELog "DHCP: resposta tambem enviada para 127.0.0.1:$($ep.Port) (teste loopback)" -Level Debug -Component dhcp
                }
            }
        }
        catch {
            Write-DorPXELog "DHCP: erro processando pacote: $($_.Exception.Message)" -Level Error -Component dhcp
        }
    }
    try { $udp.Close() } catch { }
    Write-DorPXELog 'DHCP: encerrado' -Level Info -Component dhcp
}

function Test-DorPXEDhcpProbe {
    [CmdletBinding()]
    param(
        [string]$ServerAddress = '255.255.255.255',
        [int]$TimeoutMs = 2000,
        [string]$Mac = 'DE:AD:BE:EF:00:01',
        [int]$Arch = 0
    )
    $req = New-Object byte[] 300
    $req[0] = 1; $req[1] = 1; $req[2] = 6
    $xid = New-Object byte[] 4
    (New-Object Random).NextBytes($xid)
    [Array]::Copy($xid, 0, $req, 4, 4)
    $hex = ($Mac -replace '[:\-.]', '')
    for ($i = 0; $i -lt 6; $i++) { $req[28 + $i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    $req[236] = 99; $req[237] = 130; $req[238] = 83; $req[239] = 99
    $p = 240
    $req[$p++] = 53; $req[$p++] = 1; $req[$p++] = 1
    $req[$p++] = 93; $req[$p++] = 2; $req[$p++] = [byte](($Arch -shr 8) -band 0xFF); $req[$p++] = [byte]($Arch -band 0xFF)
    $req[$p++] = 60; $req[$p++] = 11
    $vc = ConvertTo-DorPXEAscii 'PXEClient'
    foreach ($b in $vc) { $req[$p++] = $b }
    $req[$p++] = 55; $req[$p++] = 4
    $req[$p++] = 1; $req[$p++] = 3; $req[$p++] = 6; $req[$p++] = 66
    $req[$p++] = 255
    $udp = New-Object Net.Sockets.UdpClient(0)
    $udp.EnableBroadcast = $true
    $udp.Client.ReceiveTimeout = $TimeoutMs
    try {
        $dst = New-Object Net.IPEndPoint([Net.IPAddress]::Parse($ServerAddress), 67)
        [void]$udp.Send($req, $p, $dst)
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $rx = $udp.Receive([ref]$ep)
        $pkt = ConvertFrom-DorPXEDhcpPacket -Bytes $rx -AllowReply
        if ($pkt) {
            $plan = Get-DorPXEDhcpBootPlan -Config (Import-DorPXEConfig) -Packet $pkt
            return [pscustomobject]@{
                Received = $true
                From = $ep.Address.ToString()
                Type = (Get-DorPXEDhcpTypeName -Type (Get-DorPXEDhcpOptionU16 -Options $pkt.Options -Code 53))
                ServerId = (Get-DorPXEDhcpOptionIp -Options $pkt.Options -Code 54)
                NextServer = (Get-DorPXEDhcpOptionText -Options $pkt.Options -Code 66)
                BootFile = (Get-DorPXEDhcpOptionText -Options $pkt.Options -Code 67)
                Siaddr = $pkt.Siaddr
                Giaddr = $pkt.Giaddr
                Plan = $plan
                Error = $null
            }
        }
        return [pscustomobject]@{ Received = $false; From = $null; Type = $null; NextServer = $null; BootFile = $null; Plan = $null; Error = 'resposta nao e DHCP' }
    }
    catch [Net.Sockets.SocketException] {
        return [pscustomobject]@{ Received = $false; From = $null; Type = $null; NextServer = $null; BootFile = $null; Plan = $null; Error = 'timeout' }
    }
    finally { try { $udp.Close() } catch { } }
}
