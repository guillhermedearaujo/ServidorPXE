function ConvertFrom-DorPXETftpRequest {
    [CmdletBinding()]
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 5) { return $null }
    # opcode TFTP ocupa 2 bytes (RRQ = 0x0001)
    if ($Bytes[0] -ne 0 -or $Bytes[1] -ne 1) { return $null }
    $op = 1
    $tokens = New-Object System.Collections.Generic.List[string]
    $i = 2
    while ($i -lt $Bytes.Length) {
        $start = $i
        while ($i -lt $Bytes.Length -and $Bytes[$i] -ne 0) { $i++ }
        if ($i -ge $Bytes.Length) { break }
        $tokens.Add([Text.Encoding]::ASCII.GetString([byte[]]$Bytes[$start..($i - 1)]))
        $i++
    }
    if ($tokens.Count -lt 2) { return $null }
    $o = [ordered]@{
        Op      = $op
        File    = $tokens[0]
        Mode    = $tokens[1]
        Options = @{}
    }
    for ($k = 2; $k -lt $tokens.Count; $k += 2) {
        $name = $tokens[$k]
        $val = if ($k + 1 -lt $tokens.Count) { $tokens[$k + 1] } else { '' }
        $o['Options'][$name.ToLowerInvariant()] = $val
    }
    return [pscustomobject]$o
}

function New-DorPXETftpOack {
    [CmdletBinding()]
    param($Options, [int[]]$Blksize)
    $b = New-Object System.Collections.Generic.List[byte]
    $b.Add(0); $b.Add(6)
    foreach ($k in $Options.Keys) {
        $b.AddRange((ConvertTo-DorPXEAscii $k))
        $b.Add(0)
        $b.AddRange((ConvertTo-DorPXEAscii ([string]$Options[$k])))
        $b.Add(0)
    }
    , $b.ToArray()
}

function New-DorPXETftpData {
    [CmdletBinding()]
    param([int]$Block, [byte[]]$Data)
    $b = New-Object byte[] (4 + $Data.Length)
    $b[0] = 0
    $b[1] = 3
    $b[2] = (($Block -shr 8) -band 0xFF)
    $b[3] = ($Block -band 0xFF)
    if ($Data.Length -gt 0) { [Array]::Copy($Data, 0, $b, 4, $Data.Length) }
    , $b
}

function New-DorPXETftpAck {
    [CmdletBinding()]
    param([int]$Block)
    , ([byte[]]@(0, 4, (($Block -shr 8) -band 0xFF), ($Block -band 0xFF)))
}

function New-DorPXETftpError {
    [CmdletBinding()]
    param([int]$Code = 0, [string]$Message = 'error')
    $m = ConvertTo-DorPXEAscii $Message
    $b = New-Object byte[] (4 + $m.Length + 1)
    $b[0] = 0; $b[1] = 5; $b[2] = 0; $b[3] = $Code
    [Array]::Copy($m, 0, $b, 4, $m.Length)
    , $b
}

function Get-DorPXETftpNegotiated {
    [CmdletBinding()]
    param($Request, [int]$MaxBlksize = 8192, [long]$FileSize = 0)
    $o = @{}
    $want = $Request.Options
    if ($want.ContainsKey('blksize')) {
        $v = 0
        if ([int]::TryParse($want['blksize'], [ref]$v) -and $v -ge 8) {
            $o['blksize'] = [Math]::Min($v, $MaxBlksize)
        }
        else { $o['blksize'] = 512 }
    }
    if ($want.ContainsKey('timeout')) {
        $v = 0
        if ([int]::TryParse($want['timeout'], [ref]$v) -and $v -ge 1) { $o['timeout'] = [Math]::Min($v, 30) }
        else { $o['timeout'] = 5 }
    }
    # tsize: o cliente pede o tamanho do arquivo; o OACK deve devolver o valor real
    if ($want.ContainsKey('tsize')) { $o['tsize'] = [string]$FileSize }
    return $o
}

function Invoke-DorPXETftpTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ClientIp,
        [Parameter(Mandatory = $true)][int]$ClientPort,
        [hashtable]$Negotiated
    )
    $blksize = if ($Negotiated.ContainsKey('blksize')) { [int]$Negotiated['blksize'] } else { 512 }
    $timeout = if ($Negotiated.ContainsKey('timeout')) { [int]$Negotiated['timeout'] } else { 5 }
    $maxRetries = 6
    $udp = New-Object Net.Sockets.UdpClient(0)
    $udp.Client.ReceiveTimeout = ($timeout * 1000)
    $dst = New-Object Net.IPEndPoint([Net.IPAddress]::Parse($ClientIp), $ClientPort)
    $fs = New-Object IO.FileStream($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 65536)
    $sent = 0L
    try {
        $buf = New-Object byte[] $blksize
        $block = 1
        $retries = 0
        $done = $false
        $pending = $false
        $lastData = $null
        while (-not $Job.Stop.IsCancellationRequested -and -not $done) {
            if (-not $pending) {
                $n = $fs.Read($buf, 0, $blksize)
                $data = New-Object byte[] $n
                if ($n -gt 0) { [Array]::Copy($buf, 0, $data, 0, $n) }
                $lastData = New-DorPXETftpData -Block $block -Data $data
                [void]$udp.Send($lastData, $lastData.Length, $dst)
                $sent += $n
                $pending = $true
                if ($n -lt $blksize) { $done = 'pending-last' }
            }
            $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            try { $rx = $udp.Receive([ref]$ep) }
            catch [Net.Sockets.SocketException] {
                $retries++
                if ($retries -gt $maxRetries) {
                    Write-DorPXELog "TFTP: $ClientIp abandonou apos $retries retransmissoes em $FilePath" -Level Warn -Component tftp
                    break
                }
                [void]$udp.Send($lastData, $lastData.Length, $dst)
                continue
            }
            if ($rx.Length -lt 4) { continue }
            $op = (([int]$rx[0] -shl 8) -bor [int]$rx[1])
            $rb = (([int]$rx[2] -shl 8) -bor [int]$rx[3])
            if ($op -eq 4) {
                if ($rb -eq $block) {
                    $pending = $false
                    $retries = 0
                    $block++
                    if ($done -eq 'pending-last') { $done = $true }
                }
                elseif ($rb -eq ($block - 1)) {
                    [void]$udp.Send($lastData, $lastData.Length, $dst)
                }
            }
            elseif ($op -eq 5) { break }
        }
        $Job.State.Stats.TftpBytes = $Job.State.Stats.TftpBytes + $sent
        return $sent
    }
    finally {
        try { $fs.Close() } catch { }
        try { $udp.Close() } catch { }
    }
}

function Test-DorPXETftpLoop {
    [CmdletBinding()]
    param($State, [string]$ClientIp, [string]$File)
    $now = Get-Date
    $State.TftpSeen.Add([pscustomobject]@{ At = $now; Ip = $ClientIp; File = $File })
    while ($State.TftpSeen.Count -gt 200) { $State.TftpSeen.RemoveAt(0) | Out-Null }
    $window = ($State.TftpSeen | Where-Object { $_.Ip -eq $ClientIp -and $_.File -eq $File -and ($now - $_.At).TotalSeconds -le 60 })
    return $window.Count
}

function Start-DorPXETftpServer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Job)
    $Config = $Job.Config
    $State = $Job.State
    $port = 69
    if ($Config.Server.TftpPort) { $port = [int]$Config.Server.TftpPort }
    $bind = if ($Config.Dhcp.BindAddress -and $Config.Dhcp.BindAddress -ne 'auto') { $Config.Dhcp.BindAddress } else { '0.0.0.0' }
    $root = Join-Path (Get-DorPXEPath).Www ''
    $udp = $null
    try {
        $udp = New-Object Net.Sockets.UdpClient([Net.IPEndPoint]::new([Net.IPAddress]::Parse($bind), $port))
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 500
    }
    catch {
        Write-DorPXELog "TFTP: falha ao abrir UDP/$port em $bind - $($_.Exception.Message)" -Level Error -Component tftp
        return
    }
    Write-DorPXELog ("TFTP ouvindo em {0}:{1} (raiz {2})" -f $bind, $port, $root) -Level Info -Component tftp
    Write-DorPXELog 'TFTP: anti-loop ativo - se um cliente repetir o mesmo arquivo, o fluxo para o estagio 2 (autoexec.ipxe via HTTP)' -Level Info -Component tftp

    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
    while (-not $Job.Stop.IsCancellationRequested) {
        try { $bytes = $udp.Receive([ref]$ep) }
        catch [Net.Sockets.SocketException] { continue }
        catch { continue }
        $clientIp = $ep.Address.ToString()
        $clientPort = $ep.Port
        Write-DorPXELog "TFTP: requisicao de $clientIp`:$clientPort ($($bytes.Length) bytes)" -Level Debug -Component tftp
        try {
            $req = ConvertFrom-DorPXETftpRequest -Bytes $bytes
            if (-not $req) {
                # ACK/DATA dirigidos ao TID principal e normal em clientes estritos; o resto e lixo
                $opc = if ($bytes.Length -ge 2) { ([int]$bytes[0] -shl 8) -bor [int]$bytes[1] } else { 0 }
                $lvl = if ($opc -eq 3 -or $opc -eq 4 -or $opc -eq 5) { 'Debug' } else { 'Warn' }
                Write-DorPXELog "TFTP: RRQ invalido de $clientIp (bytes: $(($bytes[0..([Math]::Min(15, $bytes.Length - 1))] | ForEach-Object { $_.ToString('X2') }) -join ' '))" -Level $lvl -Component tftp
                continue
            }
            $State.Stats.TftpRequests = $State.Stats.TftpRequests + 1
            $rel = $req.File
            $safe = Resolve-DorPXESafePath -Root $root -Path $rel
            $name = Split-Path -Leaf $rel
            $hits = Test-DorPXETftpLoop -State $State -ClientIp $clientIp -File $name
            if ($hits -gt [int]$Config.Security.LoopMax) {
                Write-DorPXELog "TFTP: BLOQUEADO por anti-loop ($hits x '$name' em 60s) para $clientIp - use o menu HTTP" -Level Warn -Component tftp
                $err = New-DorPXETftpError -Code 4 -Message 'loop detectado: use o estagio 2 via HTTP'
                [void]$udp.Send($err, $err.Length, $ep)
                continue
            }
            if (-not $safe -or -not (Test-Path -LiteralPath $safe -PathType Leaf)) {
                Write-DorPXELog "TFTP 404: '$rel' de $clientIp" -Level Info -Component tftp
                $err = New-DorPXETftpError -Code 1 -Message "arquivo nao encontrado: $rel"
                [void]$udp.Send($err, $err.Length, $ep)
                continue
            }
            $len = (Get-Item -LiteralPath $safe).Length
            $neg = Get-DorPXETftpNegotiated -Request $req -FileSize $len
            if ($req.Mode -and $req.Mode -ne 'octet' -and $req.Mode -ne 'netascii') {
                $err = New-DorPXETftpError -Code 4 -Message "modo nao suportado: $($req.Mode)"
                [void]$udp.Send($err, $err.Length, $ep)
                continue
            }
            if ($req.Options.Count -gt 0) {
                $oack = New-DorPXETftpOack -Options $neg
                [void]$udp.Send($oack, $oack.Length, $ep)
            }
            Write-DorPXELog ("TFTP {0} -> '{1}' ({2} bytes){3}" -f $clientIp, $rel, $len, $(if ($neg.ContainsKey('blksize')) { " blksize=$($neg['blksize'])" } else { '' })) -Level Info -Component tftp
            $State.TftpLog.Add([pscustomobject]@{ At = Get-Date; Ip = $clientIp; File = $rel; Bytes = $len; Block = 0 })
            while ($State.TftpLog.Count -gt 200) { $State.TftpLog.RemoveAt(0) | Out-Null }
            $xfer = @{
                Job        = $Job
                FilePath   = $safe
                ClientIp   = $clientIp
                ClientPort = $clientPort
                Negotiated = $neg
            }
            $State.Pool.AddRunner('param($x) Invoke-DorPXETftpTransfer @x', $xfer)
        }
        catch {
            Write-DorPXELog "TFTP: erro em '$rel' de $clientIp - $($_.Exception.Message)" -Level Error -Component tftp
        }
    }
    try { $udp.Close() } catch { }
    Write-DorPXELog 'TFTP: encerrado' -Level Info -Component tftp
}

function Test-DorPXETftpProbe {
    [CmdletBinding()]
    param(
        [string]$ServerAddress,
        [string]$File = 'autoexec.ipxe',
        [int]$TimeoutMs = 3000
    )
    if (-not $ServerAddress) { $ServerAddress = Get-DorPXEIPv4 }
    $udp = New-Object Net.Sockets.UdpClient(0)
    $udp.Client.ReceiveTimeout = $TimeoutMs
    try {
        $b = New-Object System.Collections.Generic.List[byte]
        $b.Add(0); $b.Add(1)
        foreach ($c in (ConvertTo-DorPXEAscii $File)) { $b.Add($c) }
        $b.Add(0)
        foreach ($c in (ConvertTo-DorPXEAscii 'octet')) { $b.Add($c) }
        $b.Add(0)
        $b.AddRange((ConvertTo-DorPXEAscii 'blksize')); $b.Add(0); $b.AddRange((ConvertTo-DorPXEAscii '1400')); $b.Add(0)
        $b.Add(0)
        $arr = $b.ToArray()
        $dst = New-Object Net.IPEndPoint([Net.IPAddress]::Parse($ServerAddress), 69)
        [void]$udp.Send($arr, $arr.Length, $dst)
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $rx = $udp.Receive([ref]$ep)
        $op = (([int]$rx[0] -shl 8) -bor [int]$rx[1])
        $blk = $(if ($rx.Length -ge 4) { ([int]$rx[2] -shl 8) -bor [int]$rx[3] } else { 0 })
        $head = $(if ($op -eq 3) { "DATA bloco $blk" } elseif ($op -eq 6) { 'OACK' } elseif ($op -eq 5) { "ERRO $($rx[3]) $([Text.Encoding]::ASCII.GetString([byte[]]$rx[4..($rx.Length-1)]))" } else { "OP$op" })
        return [pscustomobject]@{
            Ok = ($op -eq 3 -or $op -eq 6); From = $ep.Address.ToString()
            Reply = $head; Bytes = $rx.Length
            Preview = $(if ($op -eq 3 -and $rx.Length -gt 4) { ([Text.Encoding]::ASCII.GetString([byte[]]$rx[4..($rx.Length-1)]) -split "`n" | Select-Object -First 4) -join ' / ' } else { '' })
        }
    }
    catch [Net.Sockets.SocketException] {
        return [pscustomobject]@{ Ok = $false; From = $null; Reply = 'timeout'; Bytes = 0; Preview = '' }
    }
    finally { try { $udp.Close() } catch { } }
}
