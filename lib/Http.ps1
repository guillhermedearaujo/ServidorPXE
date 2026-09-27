function Get-DorPXEHttpAllowed {
    [CmdletBinding()]
    param($Config, [string]$Mac, [string]$Ip)
    $allow = @($Config.Security.HttpAllow)
    if ($allow.Count -eq 0) { return $true }
    foreach ($a in $allow) {
        if (-not $a) { continue }
        if ($a -match '^([0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2})*)$' -and $Mac) {
            if ((ConvertTo-DorPXEMac $a) -eq (ConvertTo-DorPXEMac $Mac)) { return $true }
        }
        elseif ($a -match '^(.+):(\d{1,3})$') {
            $p = $Matches[1]
            if ($Ip -and $Ip -like "$p*") { return $true }
        }
        elseif ($a -eq '*' -or $a -eq '0.0.0.0/0') { return $true }
    }
    return $false
}

function Get-DorPXEHttpPrefixes {
    [CmdletBinding()]
    param($Config)
    $port = [int]$Config.Server.HttpPort
    $ip = if ($Config.Server.Address -and $Config.Server.Address -ne 'auto') { $Config.Server.Address } else { Get-DorPXEIPv4 -BindAddress $Config.Dhcp.BindAddress }
    $out = @("http://${ip}:$port/", "http://+:${port}/", "http://localhost:${port}/")
    if ($Config.Server.Https -and $Config.Server.HttpsThumbprint) {
        $out += "https://${ip}:$port/", "https://+:${port}/"
    }
    return @($out | Select-Object -Unique)
}

function New-DorPXEHttpResponse {
    [CmdletBinding()]
    param($Context, [int]$Status = 200, [string]$ContentType = 'text/plain', [byte[]]$Body)
    $r = $Context.Response
    $r.StatusCode = $Status
    $r.ContentType = $ContentType
    $r.Headers.Add('Cache-Control', 'no-store')
    if ($Body) {
        $r.ContentLength64 = $Body.Length
        $r.OutputStream.Write($Body, 0, $Body.Length)
    }
    else { $r.ContentLength64 = 0 }
    try { $r.OutputStream.Close() } catch { }
    try { $r.Close() } catch { }
}

function Send-DorPXEHttpText {
    [CmdletBinding()]
    param($Context, [string]$Text, [int]$Status = 200, [string]$ContentType = 'text/plain; charset=utf-8')
    $enc = New-Object Text.UTF8Encoding($false)
    New-DorPXEHttpResponse -Context $Context -Status $Status -ContentType $ContentType -Body ($enc.GetBytes($Text))
}

function Send-DorPXEHttpJson {
    [CmdletBinding()]
    param($Context, $Object, [int]$Status = 200)
    # Hashtable com arrays quebra o ConvertTo-Json em runspace legado (fica pendurado)
    if ($Object -is [hashtable]) { $Object = [pscustomobject]$Object }
    $txt = $Object | ConvertTo-Json -Depth 8
    Send-DorPXEHttpText -Context $Context -Text $txt -Status $Status -ContentType 'application/json; charset=utf-8'
}

function Send-DorPXEHttpRedirect {
    [CmdletBinding()]
    param($Context, [string]$Location, [int]$Status = 302)
    $r = $Context.Response
    $r.StatusCode = $Status
    $r.Headers['Location'] = $Location
    $r.Headers['Cache-Control'] = 'no-store'
    $r.ContentLength64 = 0
    try { $r.OutputStream.Close() } catch { }
    try { $r.Close() } catch { }
}

# Resposta JSON com Set-Cookie (usado no login/logout).
function Send-DorPXEHttpJsonCookie {
    [CmdletBinding()]
    param($Context, $Object, [int]$Status = 200, [string]$Cookie = '')
    if ($Object -is [hashtable]) { $Object = [pscustomobject]$Object }
    $txt = $Object | ConvertTo-Json -Depth 8
    $r = $Context.Response
    $r.StatusCode = $Status
    $r.ContentType = 'application/json; charset=utf-8'
    $r.Headers['Cache-Control'] = 'no-store'
    if ($Cookie) { $r.Headers.Add('Set-Cookie', $Cookie) }
    $enc = New-Object Text.UTF8Encoding($false)
    $bytes = $enc.GetBytes($txt)
    $r.ContentLength64 = $bytes.Length
    $r.OutputStream.Write($bytes, 0, $bytes.Length)
    try { $r.OutputStream.Close() } catch { }
    try { $r.Close() } catch { }
}

function Read-DorPXEHttpBody {
    [CmdletBinding()]
    param($Context, [int]$MaxBytes = 65536)
    $req = $Context.Request
    $out = @{}
    if (-not $req.HasEntityBody) { return $out }
    $len = 0
    try { $len = [int]$req.ContentLength64 } catch { $len = 0 }
    # sem Content-Length conhecido (-1/chunked) nao le o corpo: evita bloqueio em GET com body
    if ($len -le 0) { return $out }
    if ($len -gt $MaxBytes) { throw "corpo muito grande (max $MaxBytes bytes)" }
    $buf = New-Object byte[] $len
    $read = 0
    while ($read -lt $len) {
        $n = $req.InputStream.Read($buf, $read, $len - $read)
        if ($n -le 0) { break }
        $read += $n
    }
    if ($read -le 0) { return $out }
    $raw = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
    try {
        $j = $raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $out[$p.Name] = $p.Value }
    }
    catch { throw 'corpo JSON invalido' }
    return $out
}

function Send-DorPXEHttpFile {
    [CmdletBinding()]
    param(
        $Context,
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$Offset = 0,
        [long]$Length = -1,
        [string]$RangeHeader
    )
    $fi = Get-Item -LiteralPath $Path
    $total = $fi.Length
    $start = 0
    $end = $total - 1
    $partial = $false
    if ($RangeHeader -match 'bytes=(\d*)-(\d*)') {
        $partial = $true
        if ($Matches[1]) { $start = [long]$Matches[1] }
        if ($Matches[2]) { $end = [long]$Matches[2] }
        if (-not $Matches[1] -and $Matches[2]) { $start = [Math]::Max(0, $total - [long]$Matches[2]); $end = $total - 1 }
        if ($end -ge $total) { $end = $total - 1 }
        if ($start -gt $end) {
            New-DorPXEHttpResponse -Context $Context -Status 416
            return
        }
    }
    if ($Offset -gt 0) { $start = $Offset; $partial = $true }
    if ($Length -ge 0) { $end = [Math]::Min($end, $start + $Length - 1) }
    $len = $end - $start + 1
    $r = $Context.Response
    $r.StatusCode = if ($partial) { 206 } else { 200 }
    $r.ContentType = Get-DorPXEMimeType -Path $fi.FullName
    $r.ContentLength64 = $len
    $r.Headers.Add('Accept-Ranges', 'bytes')
    $r.Headers.Add('Last-Modified', $fi.LastWriteTimeUtc.ToString('R'))
    if ($partial) { $r.Headers.Add('Content-Range', "bytes $start-$end/$total") }
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 131072)
    try {
        [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] 131072
        $left = $len
        while ($left -gt 0) {
            $n = $fs.Read($buf, 0, [Math]::Min($buf.Length, $left))
            if ($n -le 0) { break }
            $r.OutputStream.Write($buf, 0, $n)
            $left -= $n
        }
    }
    finally {
        try { $fs.Close() } catch { }
    }
    try { $r.OutputStream.Close() } catch { }
    try { $r.Close() } catch { }
}

function Get-DorPXEHealthText {
    [CmdletBinding()]
    param($Job)
    $State = $Job.State
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('DorPXE ' + (Get-DorPXEVersion) + ' - OK')
    $lines.Add('server   : ' + $Job.ServerName + ' (' + $Job.ServerAddress + ')')
    $lines.Add('uptime   : ' + ((Get-Date) - $State.StartTime).ToString('hh\:mm\:ss'))
    $dhcpOn = if ($Job.Components) { $Job.Components.Dhcp } else { $Job.Config.Dhcp.Enabled }
    $tftpOn = if ($Job.Components) { $Job.Components.Tftp } else { $Job.Config.Dhcp.Enabled }
    $lines.Add('dhcp     : ' + $(if ($dhcpOn) { 'proxyDHCP ativo em UDP/67' } else { 'desativado' }))
    $lines.Add('tftp     : ' + $(if ($tftpOn) { "ativo em UDP/$($Job.Config.Server.TftpPort)" } else { 'desativado' }))
    $lines.Add('http     : porta ' + $Job.Config.Server.HttpPort + ' (ouvindo)')
    $lines.Add('politica : ' + $Job.Config.Policy.Mode + ' (default: ' + $Job.Config.Policy.DefaultAction + ')')
    $lines.Add('perfis   : ' + ((Get-DorPXEProfiles -Config $Job.Config | ForEach-Object { $_.Name }) -join ', '))
    $s = $State.Stats
    $lines.Add(('stats    : dhcp req={0} ofertas={1} negadas={2} | tftp req={3} bytes={4} | http req={5} bytes={6} | boots={7}' -f `
                $s.DhcpRequests, $s.DhcpOffers, $s.DhcpDenied, $s.TftpRequests, $s.TftpBytes, $s.HttpRequests, $s.HttpBytes, $s.Boots))
    $last = @($State.BootLog | Select-Object -Last 10)
    if ($last.Count -gt 0) {
        $lines.Add('ultimos boots:')
        foreach ($b in $last) {
            $lines.Add(('  {0} {1} {2} perfil={3} origem={4} {5}' -f `
                        $b.At.ToString('HH:mm:ss'), $b.Mac, $b.Ip, $b.Profile, $b.Source, $b.Reason))
        }
    }
    return ($lines -join "`n")
}

function Invoke-DorPXEHttpRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)]$Context
    )
    $Config = $Job.Config
    $State = $Job.State
    $req = $Context.Request
    $res = $Context.Response
    $path = $req.Url.AbsolutePath
    $query = ConvertFrom-DorPXEQueryString -Query $req.Url.Query
    $remote = $req.RemoteEndPoint.Address.ToString()
    $mac = $query['mac']
    $ip = $query['ip']
    if (-not $ip) { $ip = $remote }
    $ua = $req.Headers['User-Agent']
    $State.Stats.HttpRequests = $State.Stats.HttpRequests + 1
    $allowed = Get-DorPXEHttpAllowed -Config $Config -Mac $mac -Ip $remote
    Write-DorPXELog ("HTTP {0} {1} de {2} (ua='{3}')" -f $req.HttpMethod, $req.Url.PathAndQuery, $remote, $ua) -Level Debug -Component http

    try {
        $isApi = ($path -match '/pxe/api/' -or $path -match '/api/')
        if ($req.HttpMethod -ne 'GET' -and $req.HttpMethod -ne 'HEAD' -and -not ($isApi -and $req.HttpMethod -eq 'POST')) {
            Send-DorPXEHttpText -Context $Context -Status 405 -Text 'somente GET'
            return
        }
        $p = $path.TrimStart('/')
        if ($p -like 'pxe/*') { $p = $p.Substring(4) }
        elseif ($p -eq 'pxe') { $p = '' }

        switch -Regex ($p) {
            '^$' {
                # raiz do site: leva ao console, preservando o token da query
                $loc = '/pxe/admin'
                if ($query['t']) { $loc = $loc + '?t=' + [uri]::EscapeDataString([string]$query['t']) }
                Send-DorPXEHttpRedirect -Context $Context -Location $loc
                return
            }
            '^servidorpxe\.log$' {
                # log ativo: arquivo de texto na raiz do projeto (protegido como o console)
                $auth = Test-DorPXEAdminRequest -Config $Config -Context $Context
                if (-not $auth.Ok) {
                    $State.Stats.HttpDenied = $State.Stats.HttpDenied + 1
                    Send-DorPXEHttpText -Context $Context -Status 403 -Text $auth.Reason
                    return
                }
                $lf = (Get-DorPXEPath).LogFile
                if (-not (Test-Path -LiteralPath $lf -PathType Leaf)) {
                    Send-DorPXEHttpText -Context $Context -Status 404 -Text 'log inexistente: ' + $lf
                    return
                }
                $txt = @(Get-Content -LiteralPath $lf -Tail 2000 -ErrorAction SilentlyContinue) -join "`n"
                Send-DorPXEHttpText -Context $Context -Text $txt -ContentType 'text/plain; charset=utf-8'
                return
            }
            '^admin/?$' {
                $auth = Test-DorPXEAdminRequest -Config $Config -Context $Context
                if (-not $auth.Ok) {
                    $State.Stats.HttpDenied = $State.Stats.HttpDenied + 1
                    # sem sessao: mostra a tela de login (200) em vez de erro 403
                    Send-DorPXEHttpText -Context $Context -ContentType 'text/html; charset=utf-8' -Text (Get-DorPXEAdminLoginHtml -Reason $auth.Reason)
                    return
                }
                Send-DorPXEHttpText -Context $Context -ContentType 'text/html; charset=utf-8' -Text (Get-DorPXEAdminHtml -Config $Config)
                return
            }
            '^api/login$' {
                # login com usuario LOCAL do Windows (ou dominio), modelo ByFace
                $body = Read-DorPXEHttpBody -Context $Context
                $u = [string]$body.username
                $p = [string]$body.password
                $remember = [bool]$body.remember
                if (-not (Test-DorPXEAuthThrottle)) {
                    Send-DorPXEHttpJson -Context $Context -Status 429 -Object @{ error = 'muitas tentativas. aguarde 2 minutos e tente de novo.' }
                    return
                }
                if (-not $u -or -not $p) {
                    Send-DorPXEHttpJson -Context $Context -Status 400 -Object @{ error = 'informe usuario e senha' }
                    return
                }
                $r = Invoke-DorPXEAuthenticate -Config $Config -User $u -Password $p
                if (-not $r.Ok) {
                    Add-DorPXEAuthFailure
                    Write-DorPXELog "auth: login negado para '$((ConvertFrom-DorPXEUserName -Name $u))' de $remote" -Level Warn -Component auth
                    Send-DorPXEHttpJson -Context $Context -Status 401 -Object @{ error = $r.Error }
                    return
                }
                $State.Stats.HttpRequests = $State.Stats.HttpRequests + 1
                $days = [int](Get-DorPXEAuthOption -Config $Config -Name 'RememberDays' -Default 30)
                $token = New-DorPXESessionToken -Config $Config -User $r.User -Remember:$remember
                $cookie = "dorpxe_session=$token; Path=/; HttpOnly; SameSite=Strict"
                if ($remember) {
                    $exp = (Get-Date).AddDays([Math]::Max(1, $days)).ToUniversalTime().ToString('r')
                    $cookie += "; Expires=$exp"
                }
                Write-DorPXELog "auth: login OK - $($r.User) ($($r.Mode)) de $remote" -Level Info -Component auth
                Send-DorPXEHttpJsonCookie -Context $Context -Cookie $cookie -Object @{
                    ok            = $true
                    user          = $r.User
                    mode          = $r.Mode
                    remember      = $remember
                    expiresInDays = if ($remember) { [Math]::Max(1, $days) } else { 0 }
                }
                return
            }
            '^api/session$' {
                $u = Get-DorPXESessionUser -Config $Config -Request $req
                if ($u) {
                    Send-DorPXEHttpJson -Context $Context -Object @{ authenticated = $true; user = $u }
                    return
                }
                $loop = ($remote -eq '127.0.0.1' -or $remote -eq '::1' -or $remote -eq '::ffff:127.0.0.1')
                    $tok = ''
                if ($loop) {
                    $q2 = ConvertFrom-DorPXEQueryString -Query $req.Url.Query
                    $tok = [string]$q2['t']
                }
                $hasLocal = [bool]($tok -and $tok -eq (Get-DorPXEAdminToken -Config $Config))
                Send-DorPXEHttpJson -Context $Context -Object @{
                    authenticated = $hasLocal
                    user          = $null
                    localToken    = $hasLocal
                }
                return
            }
            '^api/logout$' {
                Send-DorPXEHttpJsonCookie -Context $Context -Cookie 'dorpxe_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict' -Object @{ ok = $true }
                return
            }
            '^api/status$' {
                $auth = Test-DorPXEAdminRequest -Config $Config -Context $Context
                if (-not $auth.Ok) { Send-DorPXEHttpJson -Context $Context -Status 403 -Object @{ error = $auth.Reason }; return }
                Send-DorPXEHttpJson -Context $Context -Object (Get-DorPXEStatusPayload -Job $Job -User $auth.User)
                return
            }
            '^api/log$' {
                $auth = Test-DorPXEAdminRequest -Config $Config -Context $Context
                if (-not $auth.Ok) { Send-DorPXEHttpJson -Context $Context -Status 403 -Object @{ error = $auth.Reason }; return }
                $last = 200
                if ($query['last']) { $last = [Math]::Min(1000, [int]$query['last']) }
                $tail = @(Get-DorPXEAdminLogTail -Last $last -Component ([string]$query['component']))
                # JSON montado na mao: ConvertTo-Json com array de strings pendura em runspace legado
                $parts = @()
                foreach ($l in $tail) {
                    $e = ([string]$l) -replace '(["\\])', '\$1'
                    $parts += '"' + $e + '"'
                }
                $json = '{"lines":[' + ($parts -join ',') + ']}'
                Send-DorPXEHttpText -Context $Context -Text $json -Status 200 -ContentType 'application/json; charset=utf-8'
                return
            }
            '^api/(.+)$' {
                $action = $Matches[1]
                $auth = Test-DorPXEAdminRequest -Config $Config -Context $Context -Write
                if (-not $auth.Ok) { Send-DorPXEHttpJson -Context $Context -Status 403 -Object @{ error = $auth.Reason }; return }
                if ($req.HttpMethod -ne 'POST') { Send-DorPXEHttpJson -Context $Context -Status 405 -Object @{ error = 'use POST' }; return }
                $body = Read-DorPXEHttpBody -Context $Context
                if ($action -like 'service.*') {
                    $op = $action.Substring(8)
                    if ($op -notin @('stop', 'restart')) { Send-DorPXEHttpJson -Context $Context -Status 400 -Object @{ error = "controle desconhecido: $op" }; return }
                    $State.Stats.HttpRequests = $State.Stats.HttpRequests + 1
                    Start-DorPXEAdminControl -Action $op
                    $msg = if ($op -eq 'stop') { 'Parando o servidor...' } else { 'Reiniciando o servidor...' }
                    Send-DorPXEHttpJson -Context $Context -Object @{ ok = $true; message = $msg }
                    return
                }
                try {
                    Send-DorPXEHttpJson -Context $Context -Object (Invoke-DorPXEAdminAction -Job $Job -Context $Context -Action $action -Body $body)
                }
                catch {
                    Write-DorPXELog "admin: acao '$action' falhou - $($_.Exception.Message)" -Level Warn -Component admin
                    Send-DorPXEHttpJson -Context $Context -Status 400 -Object @{ error = $_.Exception.Message }
                }
                return
            }
            '^health(\.txt)?$' {
                Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEHealthText -Job $Job)
                return
            }
            '^autoexec\.ipxe$' {
                Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEAutoExecScript -Config $Config)
                return
            }
            '^boot\.ipxe$' {
                $decision = Resolve-DorPXEDecision -Config $Config -Mac $mac -Ip $ip
                if (-not $allowed -or -not $decision.Allowed) {
                    $State.Stats.HttpDenied = $State.Stats.HttpDenied + 1
                    $reason = if (-not $allowed) { "fora de Security.HttpAllow" } else { $decision.Reason }
                }
                else {
                    $reason = $null
                    $State.Stats.Boots = $State.Stats.Boots + 1
                }
                Add-DorPXEBootLog -State $State -Entry @{
                    Mac = $decision.Mac; Ip = $ip; Source = $decision.Source; Reason = $reason
                    Profile = $decision.Profile; Action = $(if ($reason) { 'Deny' } else { $decision.Action })
                    Model = $decision.Model; UserAgent = $ua; Remote = $remote
                }
                if ($reason) {
                    Write-DorPXELog "HTTP boot.ipxe: $mac -> NEGADO ($reason)" -Level Info -Component http
                    $d = $decision
                    $d.Reason = $reason
                    Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEDenyScript -Config $Config -Decision $d)
                    return
                }
                $name = $query['profile']
                if (-not $name) { $name = $decision.Profile }
                $profile = if ($name) { Get-DorPXEProfile -Config $Config -Name $name } else { $null }
                if (-not $profile) {
                    # perfil inexistente/inexplicito => menu, mas somente para quem a politica autoriza
                    if ($decision.Allowed -or $decision.Action -eq 'Menu' -or $Config.Policy.MenuProfiles) {
                        Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEMenuScript -Config $Config -Decision $decision)
                    }
                    else {
                        $d = $decision; $d.Reason = "$($decision.Reason) (sem menu para nao autorizados)"
                        Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEDenyScript -Config $Config -Decision $d)
                    }
                    return
                }
                if (-not $decision.Allowed) {
                    $d = $decision; $d.Reason = "$($decision.Reason) (perfil negado pela politica)"
                    Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEDenyScript -Config $Config -Decision $d)
                    return
                }
                Write-DorPXELog ("HTTP boot.ipxe: {0} -> perfil {1} ({2} origem {3})" -f $decision.Mac, $profile.Name, $ip, $decision.Source) -Level Info -Component http
                Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEBootScript -Config $Config -Profile $profile -Decision $decision)
                return
            }
            '^menu\.ipxe$' {
                $decision = Resolve-DorPXEDecision -Config $Config -Mac $mac -Ip $ip
                if (-not $allowed) {
                    $d = $decision; $d.Reason = 'fora de Security.HttpAllow'
                    Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEDenyScript -Config $Config -Decision $d)
                    return
                }
                if (-not $decision.Allowed -and $decision.Action -ne 'Menu' -and -not $Config.Policy.MenuProfiles) {
                    $d = $decision; $d.Reason = "$($decision.Reason) (sem menu para nao autorizados)"
                    Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEDenyScript -Config $Config -Decision $d)
                    return
                }
                Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEMenuScript -Config $Config -Decision $decision)
                return
            }
            '^status\.ipxe$' {
                $decision = Resolve-DorPXEDecision -Config $Config -Mac $mac -Ip $ip
                Send-DorPXEHttpText -Context $Context -Text (Get-DorPXEStatusScript -Config $Config -Decision $decision)
                return
            }
            '^log(\.json)?$' {
                $last = 20
                if ($query['last']) { $last = [Math]::Min(500, [int]$query['last']) }
                $obj = [pscustomobject]@{
                    version  = (Get-DorPXEVersion)
                    stats    = $State.Stats
                    boots    = @($State.BootLog | Select-Object -Last $last)
                    dhcp     = @($State.DhcpLog | Select-Object -Last $last)
                    tftp     = @($State.TftpLog | Select-Object -Last $last)
                }
                Send-DorPXEHttpText -Context $Context -ContentType 'application/json' -Text ($obj | ConvertTo-Json -Depth 6)
                return
            }
            '^policy\.txt$' {
                $decision = Resolve-DorPXEDecision -Config $Config -Mac $mac -Ip $ip
                $lines = @(
                    "mac      : $($decision.Mac)",
                    "ip       : $ip",
                    "allowed  : $($decision.Allowed)",
                    "action   : $($decision.Action)",
                    "profile  : $($decision.Profile)",
                    "model    : $($decision.Model)",
                    "vendor   : $($decision.Vendor)",
                    "source   : $($decision.Source)",
                    "reason   : $($decision.Reason)"
                ) -join "`n"
                Send-DorPXEHttpText -Context $Context -Text $lines
                return
            }
            '.*' {
                $root = Join-Path (Get-DorPXEPath).Www ''
                $safe = Resolve-DorPXESafePath -Root $root -Path $p
                if (-not $safe -or -not (Test-Path -LiteralPath $safe -PathType Leaf)) {
                    Send-DorPXEHttpText -Context $Context -Status 404 -Text "nao encontrado: /$p"
                    return
                }
                if (-not $allowed) {
                    $State.Stats.HttpDenied = $State.Stats.HttpDenied + 1
                    Send-DorPXEHttpText -Context $Context -Status 403 -Text 'acesso negado pela politica'
                    return
                }
                if ($req.HttpMethod -eq 'HEAD') {
                    $fi = Get-Item -LiteralPath $safe
                    New-DorPXEHttpResponse -Context $Context -Status 200 -ContentType (Get-DorPXEMimeType -Path $fi.FullName)
                    return
                }
                $len = (Get-Item -LiteralPath $safe).Length
                Send-DorPXEHttpFile -Context $Context -Path $safe -RangeHeader $req.Headers['Range']
                $State.Stats.HttpBytes = $State.Stats.HttpBytes + $len
                return
            }
        }
    }
    catch {
        Write-DorPXELog "HTTP: erro em $path - $($_.Exception.Message)" -Level Error -Component http
        try { Send-DorPXEHttpText -Context $Context -Status 500 -Text "erro interno: $($_.Exception.Message)" } catch { }
    }
    finally {
        try { $res.Close() } catch { }
    }
}

function Add-DorPXEHttpJob {
    [CmdletBinding()]
    param($Job, $State, $Context)
    $State.Pool.AddRunner('param($x) Invoke-DorPXEHttpRequest @x', @{ Job = $Job; Context = $Context })
    Write-DorPXELog "HTTP: contexto enfileirado (fila=$($State.Pool.Counters.Queued))" -Level Debug -Component http
}

function Start-DorPXEHttpServer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Job)
    $Config = $Job.Config
    $State = $Job.State
    $listener = $null
    $added = @()
    $ip = if ($Config.Server.Address -and $Config.Server.Address -ne 'auto') { $Config.Server.Address } else { Get-DorPXEIPv4 -BindAddress $Config.Dhcp.BindAddress }
    $port = [int]$Config.Server.HttpPort
    $sets = @(
        @("http://${ip}:$port/", "http://localhost:${port}/", "http://127.0.0.1:${port}/"),
        @("http://${ip}:$port/", "http://127.0.0.1:${port}/"),
        @("http://localhost:${port}/", "http://127.0.0.1:${port}/"),
        @("http://127.0.0.1:${port}/"),
        @("http://+:${port}/")
    )
    if ($Config.Server.Https -and $Config.Server.HttpsThumbprint) {
        $sets = @(
            @("https://${ip}:$port/", "https://localhost:${port}/", "http://${ip}:$port/", "http://localhost:${port}/"),
            @("https://${ip}:$port/", "https://localhost:${port}/"),
            @("https://+:${port}/"),
            @("http://${ip}:$port/", "http://localhost:${port}/"),
            @("http://+:${port}/")
        )
    }
    foreach ($set in $sets) {
        $l = New-Object Net.HttpListener
        foreach ($p in $set) { try { $l.Prefixes.Add($p) } catch { } }
        $started = $false
        try { $l.Start(); $started = $true } catch { $started = $false }
        if ($started) { $listener = $l; $added = $set; break }
        try { $l.Close() } catch { }
    }
    if (-not $listener) {
        Write-DorPXELog 'HTTP: nao foi possivel abrir o HttpListener em nenhuma combinacao de URL' -Level Error -Component http
        Write-DorPXELog 'HTTP: rode como administrador e reserve a URL com: netsh http add urlacl url=http://+:PORT/ user=Everyone' -Level Error -Component http
        return
    }
    Write-DorPXELog ("HTTP ouvindo em {0}" -f ($added -join ' ')) -Level Info -Component http
    # Uma unica operacao pendente de GetContext: re-arme somente depois de consumir o resultado.
    # Abandonar BeginGetContext (chamar de novo sem EndGetContext) acumula requisicoes orfas no
    # HttpListener e o servico deixa de aceitar conexoes depois de alguns segundos.
    $iar = $null
    try { $iar = $listener.BeginGetContext($null, $null) } catch { $iar = $null }
    while (-not $Job.Stop.IsCancellationRequested) {
        if ($null -eq $iar) { Start-Sleep -Milliseconds 200; continue }
        $signaled = $iar.AsyncWaitHandle.WaitOne(500)
        if (-not $signaled) { continue }
        $ctx = $null
        try { $ctx = $listener.EndGetContext($iar) }
        catch { $ctx = $null }
        $iar = $null
        if ($ctx) {
            Add-DorPXEHttpJob -Job $Job -State $State -Context $ctx
            try { $iar = $listener.BeginGetContext($null, $null) } catch { $iar = $null }
        }
    }
    if ($iar) { try { [void]$listener.EndGetContext($iar) } catch { } }
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    Write-DorPXELog 'HTTP: encerrado' -Level Info -Component http
}

function Test-DorPXEHttpProbe {
    [CmdletBinding()]
    param(
        [string]$ServerAddress,
        [string]$Path = '/pxe/health.txt',
        [int]$TimeoutSec = 5,
        [int]$Port = 0
    )
    if (-not $ServerAddress) { $ServerAddress = Get-DorPXEIPv4 }
    if ($Port -le 0) {
        $Port = 80
        try {
            $sf = Join-Path (Get-DorPXEPath).State 'status.json'
            if (Test-Path -LiteralPath $sf) {
                $st = [IO.File]::ReadAllText($sf) | ConvertFrom-Json
                if ($st.httpPort) { $Port = [int]$st.httpPort }
            }
            if ($Port -le 0) { $Port = [int](Import-DorPXEConfig).Server.HttpPort }
        }
        catch { }
    }
    $url = "http://${ServerAddress}:$Port$Path"
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec
        $head = ($r.Content -split "`n" | Select-Object -First 3) -join ' / '
        return [pscustomobject]@{ Ok = $true; Status = [int]$r.StatusCode; Url = $url; Preview = $head; Bytes = $r.RawContentLength }
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.Response) { $msg = "HTTP $([int]$_.Exception.Response.StatusCode)" }
        return [pscustomobject]@{ Ok = $false; Status = 0; Url = $url; Preview = $msg; Bytes = 0 }
    }
}
