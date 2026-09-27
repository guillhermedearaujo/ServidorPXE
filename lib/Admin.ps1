function Get-DorPXEAdminToken {
    [CmdletBinding()]
    param($Config)
    $paths = Get-DorPXEPath
    $file = Join-Path $paths.State 'admin-token.txt'
    $token = $null
    if (Test-Path -LiteralPath $file) {
        try { $token = [IO.File]::ReadAllText($file).Trim() } catch { $token = $null }
    }
    if (-not $token) {
        $bytes = New-Object byte[] 24
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $token = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
        try {
            [IO.File]::WriteAllText($file, $token, (New-Object Text.UTF8Encoding($false)))
        }
        catch {
            Write-DorPXELog "admin: nao foi possivel gravar state\admin-token.txt - $($_.Exception.Message)" -Level Warn -Component admin
        }
    }
    return $token
}

# URL do console. Sem token de proposito: o navegador abre a tela de login
# (usuario local do Windows). -WithToken devolve a URL de automacao, valida
# apenas em loopback.
function Get-DorPXEAdminUrl {
    [CmdletBinding()]
    param($Config, [int]$Port = 0, [switch]$WithToken)
    $p = if ($Port -gt 0) { $Port } else { [int]$Config.Server.HttpPort }
    $addr = $Config.Server.Address
    $hostName = if ($addr -and $addr -ne 'auto') { $addr } else { '127.0.0.1' }
    $url = "http://${hostName}:$p/pxe/admin"
    if ($WithToken) { $url = $url + '?t=' + (Get-DorPXEAdminToken -Config $Config) }
    return $url
}

# Prioridade: sessao do usuario local (cookie) > token de automacao (so loopback).
function Test-DorPXEAdminRequest {
    [CmdletBinding()]
    param($Config, $Context, [switch]$Write)
    $req = $Context.Request
    $remote = $req.RemoteEndPoint.Address.ToString()
    $loopback = ($remote -eq '127.0.0.1' -or $remote -eq '::1' -or $remote -eq '::ffff:127.0.0.1')

    $user = Get-DorPXESessionUser -Config $Config -Request $req
    if ($user) {
        return [pscustomobject]@{ Ok = $true; Loopback = $loopback; Remote = $remote; User = $user; Auth = 'sessao'; Reason = $null }
    }

    $token = ''
    try { $token = [string]$req.Headers['X-DorPXE-Token'] } catch { $token = '' }
    if (-not $token) {
        $q = ConvertFrom-DorPXEQueryString -Query $req.Url.Query
        $token = [string]$q['t']
    }
    $expected = Get-DorPXEAdminToken -Config $Config
    $hasToken = [bool]($token -and $expected -and $token -eq $expected)
    $ok = $hasToken
    if (-not $loopback) { $ok = $false }
    if ($Write -and -not $loopback) { $ok = $false }
    $reason = if (-not $loopback) { 'acesso remoto exige login com usuario local do Windows' }
             elseif (-not $hasToken) { 'faca login com um usuario local autorizado' }
             else { $null }
    return [pscustomobject]@{
        Ok      = $ok
        Loopback = $loopback
        Remote  = $remote
        User    = $null
        Auth    = if ($ok) { 'token-local' } else { $null }
        Reason  = $reason
    }
}

# Cache curto para consultas caras (firewall/CIM): o console atualiza a cada 3s.
function Get-DorPXECachedValue {
    [CmdletBinding()]
    param([string]$Key, [scriptblock]$Block, [int]$Seconds = 120)
    $c = $script:DorPXEEnvCache
    if ($c -and $c.ContainsKey($Key) -and ((Get-Date) - $c[$Key].At).TotalSeconds -lt $Seconds) { return $c[$Key].Data }
    $data = & $Block
    if (-not $c) { $c = @{}; $script:DorPXEEnvCache = $c }
    $c[$Key] = [pscustomobject]@{ At = (Get-Date); Data = $data }
    return $data
}

# Diagnostico do ambiente: o que falta para o boot funcionar na rede corporativa.
# So leitura local (arquivos + config); nada de rede, para o console continuar leve.
function Get-DorPXEEnvironmentReport {
    [CmdletBinding()]
    param($Config, $Job)
    $paths = Get-DorPXEPath
    $it = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($Name, $Ok, $Level, $Detail)
        $it.Add([pscustomobject]@{ Name = $Name; Ok = [bool]$Ok; Level = $Level; Detail = $Detail })
    }

    # 1) binarios iPXE (obrigatorios para o boot de verdade)
    $efi = @(Get-ChildItem -LiteralPath (Join-Path $paths.Ipxe 'x86_64-efi') -Filter 'ipxe.efi' -File -ErrorAction SilentlyContinue)
    $pxe = @(Get-ChildItem -LiteralPath (Join-Path $paths.Ipxe 'x86_64-pcbios') -File -Filter '*.kpxe' -ErrorAction SilentlyContinue)
    $auto = @(Get-ChildItem -LiteralPath $paths.Ipxe -Recurse -Filter 'autoexec.ipxe' -File -ErrorAction SilentlyContinue)
    $ipxeOk = ($efi.Count -gt 0 -and $pxe.Count -gt 0 -and $auto.Count -gt 0)
    & $add 'Binarios iPXE' $ipxeOk $(if ($ipxeOk) { 'ok' } else { 'bad' }) `
        $(if ($ipxeOk) { "UEFI + PCBIOS + $($auto.Count) autoexec.ipxe" } else { 'faltam ipxe.efi/undionly.kpxe em www\ipxe (repo incompleto?)' })

    # 2) pasta de midia
    $mediaRoot = Get-DorPXEMediaRoot
    $mediaOk = Test-Path -LiteralPath $mediaRoot -PathType Container
    & $add 'Pasta de midia' $mediaOk $(if ($mediaOk) { 'ok' } else { 'warn' }) $mediaRoot

    # 3) boot.wim pronto (para instalar) / fonte configurada
    $bwim = Get-DorPXEMediaBootWimDir -Config $Config
    & $add 'Imagem WinPE' ([bool]$bwim) $(if ($bwim) { 'ok' } else { 'warn' }) `
        $(if ($bwim) { $bwim } else { 'sem ISO/boot.wim - o console so gerencia ate voce apontar a ISO (Passo 2)' })

    # 4) ISO configurada
    $isoN = @($Config.Media.Iso | Where-Object { $_ }).Count
    $isoDir = [string]$Config.Media.IsoDir
    & $add 'ISO do Windows 11' ([bool]($isoN -gt 0 -or $isoDir)) $(if ($isoN -gt 0 -or $isoDir) { 'ok' } else { 'warn' }) `
        $(if ($isoN -gt 0) { "$isoN ISO(s) no config" } elseif ($isoDir) { "pasta: $isoDir" } else { 'Media.Iso vazio - rode: ServidorPXE.ps1 Build-Media -Iso "C:\...\Win11.iso"' })

    # 5) DHCP: modo proxy e endereco de bind
    $dhcpMode = [string]$Config.Dhcp.Mode
    $bind = try { Get-DorPXEIPv4 -BindAddress ([string]$Config.Dhcp.BindAddress) } catch { $null }
    $bindOk = [bool]$bind
    & $add 'DHCP' ($bindOk -and $Job.Components.dhcp) $(if ($bindOk -and $Job.Components.dhcp) { 'ok' } else { 'warn' }) `
        ("modo {0} em {1}{2}" -f $dhcpMode, $(if ($bind) { $bind } else { '?' }), $(if ($dhcpMode -eq 'Proxy') { ' (proxy: convive com o DHCP corporativo)' } else { '' }))

    # 6) proxy DHCP exige resposta do servidor corporativo na mesma faixa
    & $add 'Escopo da rede' $bindOk $(if ($bindOk) { 'ok' } else { 'bad' }) `
        $(if ($bindOk) { "interface $bind" } else { 'sem IPv4 valido - ajuste Server.Address/Dhcp.BindAddress no config' })

    # 7) firewall (consulta cara, cacheada)
    $fw = Get-DorPXECachedValue -Key 'fw' -Seconds 180 -Block {
        $port = [int]$Config.Server.HttpPort
        $has = @(Get-NetFirewallRule -DisplayName 'ServidorPXE*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' } |
            Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -eq [string]$port }).Count
        [bool]($has -gt 0)
    }
    & $add 'Firewall' $fw $(if ($fw) { 'ok' } else { 'warn' }) `
        $(if ($fw) { "porta $($Config.Server.HttpPort) liberada" } else { "sem regra para a porta $($Config.Server.HttpPort) - rode: ServidorPXE.ps1 Install" })

    # 8) execucao: prioridade de script e bloqueio de arquivos baixados (Mark of the Web)
    $ep = Get-DorPXECachedValue -Key 'exec' -Seconds 300 -Block {
        ((Get-ExecutionPolicy -ErrorAction SilentlyContinue | Out-String) -replace '\s+', ' ').Trim()
    }
    # Zone.Identifier nao aparece como property no PS 5.1: usa -Stream nos arquivos de script
    $zoned = @(Get-DorPXECachedValue -Key 'zone' -Seconds 300 -Block {
        $alvos = @()
        $alvos += @(Get-ChildItem -LiteralPath $paths.Base -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.ps1', '.bat', '.cmd' })
        foreach ($d in @($paths.Lib, $paths.Config)) {
            $alvos += @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.ps1', '.bat', '.psd1' })
        }
        $n = 0
        foreach ($f in $alvos) {
            try { if (Get-Item -LiteralPath $f.FullName -Stream Zone.Identifier -ErrorAction Stop) { $n++ } }
            catch { }
        }
        $n
    })
    $epOk = (($ep -match 'Bypass|Unrestricted') -or ($ep -match 'RemoteSigned' -and $zoned -eq 0)) -and $zoned -eq 0
    & $add 'Execucao de scripts' $epOk $(if ($epOk) { 'ok' } else { 'warn' }) `
        ("ExecutionPolicy = {0}{1}" -f $ep, $(if ($zoned -gt 0) { " | $zoned arquivo(s) com Mark of the Web - rode iniciar.bat para liberar" } elseif ($ep -notmatch 'Bypass|Unrestricted') { ' | iniciar.bat aplica Bypass no usuario' } else { '' }))

    # 9) elevacao
    $adm = $false
    try { $adm = [bool](Test-DorPXEAdmin) } catch { $adm = $false }
    & $add 'Privilegio' $adm $(if ($adm) { 'ok' } else { 'warn' }) `
        $(if ($adm) { 'servico como Administrador' } else { 'sem elevacao: UDP/67, TFTP e share podem falhar - iniciar.bat solicita UAC' })

    # 10) allowlist vazia = rede inteira negada
    $devN = 0
    try { $devN = @((Get-DorPXEDeviceDb).Devices).Count } catch { $devN = 0 }
    $mode = [string]$Config.Policy.Mode
    & $add 'Politica x cadastro' ($mode -ne 'AllowList' -or $devN -gt 0) $(if ($mode -ne 'AllowList' -or $devN -gt 0) { 'ok' } else { 'warn' }) `
        $(if ($mode -eq 'AllowList' -and $devN -eq 0) { "AllowList vazia: todo host da rede sera negado ($devN cadastrados)" } else { "$devN equipamento(s) cadastrado(s), modo $mode" })

    # 11) autenticacao do Windows realmente consultavel (o login depende disso)
    $authOk = $false
    $authDetail = 'conta local nao encontrada'
    $ctxChk = $null
    try {
        if (Initialize-DorPXEAuth) {
            $ctxChk = New-DorPXEPrincipalContext -Type Machine
            $authOk = ($null -ne $ctxChk)
            if ($authOk) {
                $grps = @(Get-DorPXEAuthGroups -Config $Config)
                $sidOk = @($grps | Where-Object { ConvertTo-DorPXEGroupSid -Name $_ })
                $authDetail = if ($sidOk.Count -gt 0) {
                    "local + $($grps.Count) grupo(s) autorizado(s): $($grps -join ', ')"
                } else {
                    "local ok, mas NENHUM grupo de AuthGroups existe nesta maquina: $(($grps -join ', '))"
                }
            }
        }
        else { $authDetail = 'assembly System.DirectoryServices.AccountManagement ausente - todo login sera recusado' }
    }
    catch { $authDetail = "falha ao consultar as contas do Windows: $($_.Exception.Message)" }
    finally { if ($ctxChk) { try { $ctxChk.Dispose() } catch { } } }
    $authLevel = if ($authOk) { 'ok' } else { 'error' }
    & $add 'Autenticacao Windows' $authOk $authLevel $authDetail

    return @($it.ToArray())
}

function Get-DorPXEStatusPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Job, [string]$User)
    $Config = $Job.Config
    $State = $Job.State
    $uptime = (Get-Date) - $State.StartTime
    $stats = $State.Stats
    $prof = @(Get-DorPXEProfiles -Config $Config | ForEach-Object {
            [pscustomobject]@{
                Name  = $_.Name
                Title = $_.Title
                Image = $_.ImageName
                Index = $_.ImageIndex
                Mode  = (Get-DorPXEModeState -Config $Config -ProfileName $_.Name)
            }
        })
    $db = Get-DorPXEDeviceDb
    $mediaDir = Get-DorPXEMediaRoot
    $media = @((Get-ChildItem -Path $mediaDir -Directory -ErrorAction SilentlyContinue) | ForEach-Object {
            $files = @(Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue)
            $setup = Join-Path $_.FullName 'sources\setup.exe'
            [pscustomobject]@{
                Name    = $_.Name
                Setup   = (Test-Path -LiteralPath $setup)
                Files   = $files.Count
                Size    = [Math]::Round((($files | Measure-Object -Property Length -Sum).Sum / 1MB), 0)
                Path    = $_.FullName
                BootWim = (Test-Path -LiteralPath (Join-Path $_.FullName 'sources\boot.wim'))
            }
        })
    # --- midia configurada (pasta/ISO) -----------------------------------------
    $isoCfg = @($Config.Media.Iso | Where-Object { $_ })
    $isoDir = [string]$Config.Media.IsoDir
    $cands = New-Object System.Collections.Generic.List[string]
    if ($isoDir) { $cands.Add($isoDir) }
    foreach ($i in $isoCfg) {
        if (Test-Path -LiteralPath $i -PathType Container) { $cands.Add($i) }
        else { $d = Split-Path -Parent $i; if ($d) { $cands.Add($d) } }
    }
    $scanDir = $null
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c -PathType Container) { $scanDir = $c; break } }
    $isoList = @()
    if ($scanDir) {
        $isoList = @(Get-ChildItem -LiteralPath $scanDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
                Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; SizeMB = [Math]::Round($_.Length / 1MB, 0) } })
    }
    # BootWim: arquivo boot.wim ja extraido (para instalar sem remontar a ISO).
    # BootWimSource: pasta/ISO de onde o Build-Media tira o WinPE.
    $bootWimSource = Get-DorPXEMediaBootWimDir -Config $Config
    $bootWim = $null
    if ($bootWimSource -and (Test-Path -LiteralPath $bootWimSource -PathType Leaf)) { $bootWim = $bootWimSource }
    elseif ($bootWimSource) {
        foreach ($rel in @('sources\boot.wim', 'winpe\boot.wim', 'boot.wim')) {
            $c = Join-Path $bootWimSource $rel
            if (Test-Path -LiteralPath $c -PathType Leaf) { $bootWim = $c; break }
        }
    }
    # --- hosts ativos (vistos nos ultimos minutos) -----------------------------
    $janela = (Get-Date).AddMinutes(-20)
    $vistos = @{}
    foreach ($e in @($State.DhcpLog)) {
        if (-not $e.Mac) { continue }
        $t = try { [datetime]$e.At } catch { $null }
        if ($t -and $t -lt $janela) { continue }
        $vistos[$e.Mac] = [pscustomobject]@{ Mac = $e.Mac; Ip = $e.Ip; At = $e.At; Type = 'DHCP' }
    }
    foreach ($e in @($State.BootLog)) {
        if (-not $e.Mac) { continue }
        $t = try { [datetime]$e.At } catch { $null }
        if ($t -and $t -lt $janela) { continue }
        $prev = $vistos[$e.Mac]
        if (-not $prev -or ([datetime]$e.At) -ge ([datetime]$prev.At)) {
            $vistos[$e.Mac] = [pscustomobject]@{ Mac = $e.Mac; Ip = $e.Ip; At = $e.At; Type = 'BOOT'; Action = $e.Action }
        }
    }
    $hosts = @($vistos.Values | Sort-Object At -Descending)
    [pscustomobject]@{
        version    = (Get-DorPXEVersion)
        name       = $Job.ServerName
        address    = $Job.ServerAddress
        httpPort   = [int]$Config.Server.HttpPort
        started    = $State.StartTime.ToString('o')
        uptime     = ('{0:00}:{1:00}:{2:00}' -f [int]$uptime.TotalHours, $uptime.Minutes, $uptime.Seconds)
        components = $Job.Components
        policy     = [pscustomobject]@{ Mode = $Config.Policy.Mode; DefaultAction = $Config.Policy.DefaultAction; MenuSeconds = $Config.Policy.MenuSeconds }
        dhcp       = [pscustomobject]@{ Mode = $Config.Dhcp.Mode; NextServer = $Config.Dhcp.NextServer; ProxyAck = $Config.Dhcp.ProxyAck }
        stats      = [pscustomobject]@{
            DhcpRequests = $stats.DhcpRequests; DhcpOffers = $stats.DhcpOffers; DhcpDenied = $stats.DhcpDenied
            TftpRequests = $stats.TftpRequests; TftpBytes = $stats.TftpBytes; TftpDenied = $stats.TftpDenied
            HttpRequests = $stats.HttpRequests; HttpBytes = $stats.HttpBytes; Boots = $stats.Boots
        }
        profiles   = $prof
        devices    = @($db.Devices)
        models     = @($db.Models)
        prefixes   = @($db.Prefixes)
        media      = $media
        mediaCfg   = [pscustomobject]@{
            IsoDir      = $isoDir
            Iso         = $isoCfg
            ScanDir     = $scanDir
            Isos        = $isoList
            BootWim     = $bootWim
            BootWimSource = $bootWimSource
            WinPeSource = [string]$Config.WinPe.Source
            Slug        = [string]$Config.Media.Slug
        }
        hosts      = $hosts
        logFile    = (Get-DorPXEPath).LogFile
        user       = $User
        env        = @(Get-DorPXEEnvironmentReport -Config $Config -Job $Job)
        events     = [pscustomobject]@{
            boots = @($State.BootLog | Select-Object -Last 15)
            dhcp  = @($State.DhcpLog | Select-Object -Last 15)
            tftp  = @($State.TftpLog | Select-Object -Last 15)
        }
    }
}

function Get-DorPXEAdminLogTail {
    [CmdletBinding()]
    param([int]$Last = 120, [string]$Component = '')
    # log ativo: arquivo de texto na raiz do projeto
    $file = (Get-DorPXEPath).LogFile
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $alt = @(Get-ChildItem -Path (Join-Path (Get-DorPXEPath).Logs 'servidorpxe-*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
        if ($alt.Count -eq 0) { return @() }
        $file = $alt[-1].FullName
    }
    $lines = @(Get-Content -LiteralPath $file -Tail ([Math]::Max(20, $Last)) -ErrorAction SilentlyContinue)
    if ($Component) { $lines = @($lines | Where-Object { $_ -match "\]\s+$([regex]::Escape($Component))\s" }) }
    return $lines
}

function Invoke-DorPXEAdminAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Action,
        $Body
    )
    $Config = $Job.Config
    $script = Join-Path (Get-DorPXEPath).Base 'ServidorPXE.ps1'
    switch ($Action) {
        'device.add' {
            $mac = [string]$Body['mac']
            if (-not $mac) { throw 'informe mac' }
            $r = Add-DorPXEDevice -Mac $mac -Profile ([string]$Body['profile']) -Action ([string]$Body['action']) -Model ([string]$Body['model']) -Note ([string]$Body['note'])
            if (-not $r) { throw 'mac invalido ou duplicado' }
            Write-DorPXELog "admin: device add $mac -> $($r.Profile) ($($r.Action))" -Level Info -Component admin
            return (Get-DorPXEStatusPayload -Job $Job)
        }
        'device.remove' {
            $ok = Remove-DorPXEDevice -Mac ([string]$Body['mac'])
            if (-not $ok) { throw 'mac nao encontrado' }
            Write-DorPXELog "admin: device remove $([string]$Body['mac'])" -Level Info -Component admin
            return (Get-DorPXEStatusPayload -Job $Job)
        }
        'policy.set' {
            $mode = [string]$Body['mode']
            $def = [string]$Body['default']
            $p = Import-DorPXEConfig
            if ($mode -in @('AllowList', 'Open')) { $p.Policy['Mode'] = $mode }
            if ($def -in @('Local', 'Menu', 'Deny')) { $p.Policy['DefaultAction'] = $def }
            Save-DorPXEConfig -Config $p
            # aplica tambem no servico em execucao (nao espera restart)
            $Config.Policy['Mode'] = $p.Policy.Mode
            $Config.Policy['DefaultAction'] = $p.Policy.DefaultAction
            Write-DorPXELog "admin: politica -> Mode=$($Config.Policy.Mode) DefaultAction=$($Config.Policy.DefaultAction) (aplicado agora)" -Level Info -Component admin
            return (Get-DorPXEStatusPayload -Job $Job)
        }
        'media.set' {
            $dir = [string]$Body['dir']
            $iso = [string]$Body['iso']
            $slug = [string]$Body['slug']
            $p = Import-DorPXEConfig
            if ($slug -and $slug -match '^[A-Za-z0-9._-]{1,32}$') { $p.Media['Slug'] = $slug }
            if ($dir) {
                $full = $dir
                if (-not [IO.Path]::IsPathRooted($full)) { $full = Join-Path (Get-DorPXEPath).Base $full }
                if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "Pasta da ISO nao existe: $full" }
                $p.Media['IsoDir'] = $full
            }
            else { $p.Media['IsoDir'] = '' }
            if ($iso) {
                $fullIso = $iso
                if (-not [IO.Path]::IsPathRooted($fullIso)) { $fullIso = Join-Path (Get-DorPXEPath).Base $fullIso }
                if (-not (Test-Path -LiteralPath $fullIso -PathType Leaf)) { throw "ISO nao encontrada: $fullIso" }
                if ([IO.Path]::GetExtension($fullIso).ToLowerInvariant() -ne '.iso') { throw "Arquivo nao e .iso: $fullIso" }
                $p.Media['Iso'] = @($fullIso)
                if (-not $p.Media['IsoDir']) { $p.Media['IsoDir'] = (Split-Path -Parent $fullIso) }
            }
            else { $p.Media['Iso'] = @() }
            # WinPe.Source = MediaIso agora resolve a partir da ISO/pasta informada
            $p.WinPe['Source'] = 'MediaIso'
            Save-DorPXEConfig -Config $p
            $Config.Media['IsoDir'] = $p.Media.IsoDir
            $Config.Media['Iso'] = $p.Media.Iso
            $Config.Media['Slug'] = $p.Media.Slug
            $Config.WinPe['Source'] = 'MediaIso'
            Write-DorPXELog "admin: midia -> dir='$($p.Media.IsoDir)' iso='$(($p.Media.Iso -join ','))' slug=$($p.Media.Slug)" -Level Info -Component admin
            return (Get-DorPXEStatusPayload -Job $Job)
        }
        'media.build' {
            $p = Import-DorPXEConfig
            $iso = @($p.Media.Iso)
            if ($iso.Count -eq 0) { throw 'Informe a pasta/arquivo .iso no Passo 2 antes de construir.' }
            foreach ($i in $iso) { if (-not (Test-Path -LiteralPath $i -PathType Leaf)) { throw "ISO nao encontrada: $i" } }
            $isoval = ($iso -join ',')
            $argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script + '"'), 'Build-Media', '-Iso', ('"' + $isoval + '"'))
            $out = Join-Path (Get-DorPXEPath).Logs 'build-media.out.log'
            Start-Process powershell -WindowStyle Hidden -ArgumentList $argl -RedirectStandardOutput $out -RedirectStandardError (Join-Path (Get-DorPXEPath).Logs 'build-media.err.log')
            Write-DorPXELog "admin: Build-Media despachado (iso=$($iso -join ','))" -Level Info -Component admin
            return @{ started = $true; message = 'Construindo midia em segundo plano... acompanhe o arquivo build-media.out.log'; output = $out }
        }
        default {
            throw "acao desconhecida: $Action"
        }
    }
}

function Start-DorPXEAdminControl {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Action)
    $script = Join-Path (Get-DorPXEPath).Base 'ServidorPXE.ps1'
    if ($Action -eq 'stop') {
        $cmd = "Start-Sleep -Milliseconds 700; & '$script' Stop *> `$null"
    }
    else {
        $cmd = "Start-Sleep -Milliseconds 700; & '$script' Stop *> `$null; Start-Sleep -Seconds 2; Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$script','Start'"
    }
    Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ('"' + $cmd + '"'))
    Write-DorPXELog "admin: controle '$Action' despachado" -Level Info -Component admin
}

function Get-DorPXEAdminLoginHtml {
    [CmdletBinding()]
    param([string]$Reason = '', [string]$Next = '')
    $msg = if ($Reason) { $Reason } else { 'informe usuario e senha' }
    $grupos = (Get-DorPXEAuthGroups) -join ', '
    $destino = if ($Next) { '?next=' + [uri]::EscapeDataString($Next) } else { '' }
    @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>ServidorPXE - acesso restrito</title>
<style>
:root{--bg:#0b0f14;--card:#131b24;--card2:#18222e;--line:#22303d;--fg:#e6edf3;--dim:#8fa3b5;--acc:#3b82f6;--r:14px}
@media (prefers-color-scheme:light){:root{--bg:#f4f7fb;--card:#fff;--card2:#f7fafd;--line:#d8e2ec;--fg:#0f1b28;--dim:#5b6b7c}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;padding:20px;background:var(--bg);color:var(--fg);
  font:15px/1.5 "Segoe UI",system-ui,-apple-system,Roboto,sans-serif}
.box{width:100%;max-width:400px;background:var(--card);border:1px solid var(--line);border-radius:var(--r);
  padding:24px;box-shadow:0 12px 32px rgba(0,0,0,.28)}
.mark{width:42px;height:42px;border-radius:12px;display:grid;place-items:center;font-weight:700;font-size:15px;color:#fff;
  background:linear-gradient(140deg,var(--acc),#7c3aed);margin-bottom:14px}
h1{font-size:17px;margin:0 0 6px}
p{margin:6px 0 14px;color:var(--dim);font-size:13px}
code{font-family:ui-monospace,Consolas,monospace;background:var(--card2);padding:2px 6px;border-radius:5px;font-size:12px}
label{display:block;font-size:12px;color:var(--dim);margin:12px 0 0}
input[type=text],input[type=password]{width:100%;padding:11px 12px;border-radius:10px;border:1px solid var(--line);background:var(--card2);color:var(--fg);font:inherit}
input:focus{outline:2px solid var(--acc);outline-offset:1px}
.chk{display:flex;align-items:center;gap:8px;margin:14px 0 0;font-size:13px;color:var(--fg)}
.chk input{width:16px;height:16px;accent-color:var(--acc)}
button{width:100%;margin-top:16px;padding:11px 14px;border-radius:10px;border:1px solid var(--acc);background:var(--acc);
  color:#fff;font:inherit;font-weight:600;cursor:pointer}
button:hover{filter:brightness(1.08)}
button:disabled{opacity:.6;cursor:progress}
.err{display:none;margin:0 0 6px;padding:10px 12px;border-radius:10px;font-size:13px;
  background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.45);color:#fca5a5}
.note{margin:16px 0 0;padding-top:14px;border-top:1px solid var(--line);font-size:12px;color:var(--dim);line-height:1.6}
</style>
</head>
<body><form class="box" id="lf" autocomplete="off">
  <div class="mark">DP</div>
  <h1>ServidorPXE - console protegido</h1>
  <p class="err" id="err">$msg</p>
  <label for="u">Usuario (local ou dominio)</label>
  <input type="text" id="u" name="username" placeholder="usuario" autocomplete="username" autofocus>
  <label for="p">Senha</label>
  <input type="password" id="p" name="password" placeholder="Senha" autocomplete="current-password">
  <label class="chk"><input type="checkbox" id="k" checked> Lembrar meu acesso neste dispositivo</label>
  <button id="b" type="submit">Entrar</button>
  <p class="note">Autenticacao pelo <b>proprio Windows</b>: conta local ou de dominio.<br>
     Permissao exigida: <code>$grupos</code> ou usuario listado em <code>Server.AuthUsers</code>.<br>
     Nenhuma senha e gravada em disco. Motivo do bloqueio: $msg</p>
</form>
<script>
var F=document.getElementById('lf'),E=document.getElementById('err'),B=document.getElementById('b');
F.addEventListener('submit',function(e){
  e.preventDefault();
  var u=document.getElementById('u').value.trim(),p=document.getElementById('p').value;
  if(!u||!p){E.textContent='informe usuario e senha';E.style.display='block';return}
  B.disabled=true;B.textContent='Validando...';E.style.display='none';
  fetch('/pxe/api/login',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({username:u,password:p,remember:document.getElementById('k').checked})})
   .then(function(r){return r.text().then(function(t){var j=null;try{j=JSON.parse(t)}catch(x){}
     if(!r.ok)throw new Error((j&&j.error)||('HTTP '+r.status));
     location.href=location.pathname+(location.search||'');})})
   .catch(function(x){B.disabled=false;B.textContent='Entrar';
     E.textContent=x.message||'falha ao autenticar';E.style.display='block';});
});
</script>
</body>
</html>
"@
}

function Get-DorPXEAdminHtml {
    [CmdletBinding()]
    param($Config)
    $port = [int]$Config.Server.HttpPort
    $version = Get-DorPXEVersion
    @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<title>ServidorPXE $version - console</title>
<style>
:root{
  --bg:#0b0f14; --bg2:#0f151c; --card:#131b24; --card2:#18222e; --line:#22303d; --line2:#2e4152;
  --fg:#e6edf3; --dim:#8fa3b5; --acc:#3b82f6; --acc2:#7cb0ff; --ok:#22c55e; --warn:#f59e0b; --err:#ef4444;
  --r:14px; --r2:10px; --sh:0 12px 32px rgba(0,0,0,.35); --mono:ui-monospace,Consolas,"Cascadia Mono",monospace;
}
@media (prefers-color-scheme:light){
  :root{ --bg:#f4f7fb; --bg2:#eaeff6; --card:#ffffff; --card2:#f7fafd; --line:#d8e2ec; --line2:#c2d1e0;
         --fg:#0f1b28; --dim:#5b6b7c; --acc2:#1d4ed8; --sh:0 10px 26px rgba(16,32,54,.10); }
}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);
  font:15px/1.5 "Segoe UI",system-ui,-apple-system,Roboto,sans-serif}
a{color:var(--acc2)}
h1,h2,h3{margin:0}
.mono{font-family:var(--mono)}
.mut{color:var(--dim)}
.tiny{font-size:12px}

/* ---------- barra de status ---------- */
.top{position:sticky;top:0;z-index:30;background:var(--card);border-bottom:1px solid var(--line);
  box-shadow:0 1px 0 rgba(255,255,255,.02),0 10px 24px rgba(0,0,0,.18)}
.topin{max-width:1440px;margin:0 auto;padding:12px 18px;display:flex;flex-wrap:wrap;gap:10px 16px;align-items:center}
.brand{display:flex;align-items:center;gap:11px;min-width:0}
.mark{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;font-weight:700;font-size:14px;
  color:#fff;background:linear-gradient(140deg,var(--acc),#7c3aed);box-shadow:0 6px 18px rgba(59,130,246,.35);flex:none}
.brand b{display:block;font-size:15px;letter-spacing:.2px}
.brand span{display:block;font-size:12px;color:var(--dim)}
.pill{display:inline-flex;align-items:center;gap:8px;padding:6px 12px;border-radius:99px;
  border:1px solid var(--line);background:var(--card2);font-size:13px;white-space:nowrap}
.dot{width:9px;height:9px;border-radius:50%;background:var(--dim);flex:none}
.dot.on{background:var(--ok);box-shadow:0 0 0 4px rgba(34,197,94,.16);animation:pulse 2.4s ease-in-out infinite}
.dot.off{background:var(--err);box-shadow:0 0 0 4px rgba(239,68,68,.14)}
@keyframes pulse{0%,100%{box-shadow:0 0 0 3px rgba(34,197,94,.16)}50%{box-shadow:0 0 0 7px rgba(34,197,94,.05)}}
.chips{display:flex;gap:8px;flex-wrap:wrap;flex:1 1 300px;min-width:0}
.chip{display:inline-flex;align-items:baseline;gap:6px;padding:5px 10px;border-radius:9px;background:var(--card2);
  border:1px solid var(--line);font-size:12px;color:var(--dim);white-space:nowrap}
.chip b{font-size:14px;color:var(--fg);font-variant-numeric:tabular-nums}
.chip.good b{color:var(--ok)} .chip.bad b{color:var(--err)} .chip.acc b{color:var(--acc2)} .chip.warn b{color:var(--warn)}
.chip.state{align-items:center}
.tools{display:flex;flex-direction:column;align-items:flex-end;gap:5px;flex-wrap:wrap}
.toolrow{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.who{font-size:12px;color:var(--dim);max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;text-align:right}
.pbar{max-width:1440px;margin:0 auto;padding:0 18px 10px;display:flex;flex-wrap:wrap;gap:8px 10px;align-items:center}
.pbar>label{font-size:12px;color:var(--dim);font-weight:600;white-space:nowrap}
.pbar select{width:auto;min-width:148px;padding:5px 9px;font-size:12.5px}
.pbar .polhint{font-size:12px;color:var(--dim);flex:1 1 240px;min-width:0}
.pbar .polhint b{color:var(--txt)}

/* ---------- estrutura ---------- */
.shell{max-width:1440px;margin:0 auto;padding:20px 18px 60px;display:grid;gap:20px;
  grid-template-columns:250px minmax(0,1fr);align-items:start}
.steps{position:sticky;top:86px;display:flex;flex-direction:column;gap:8px}
.stepbtn{display:flex;gap:11px;align-items:flex-start;width:100%;text-align:left;padding:11px 12px;border-radius:var(--r2);
  background:var(--card);border:1px solid var(--line);color:var(--fg);cursor:pointer;font:inherit;transition:.16s}
.stepbtn:hover{border-color:var(--line2);transform:translateY(-1px)}
.stepbtn .n{flex:none;width:24px;height:24px;border-radius:8px;display:grid;place-items:center;font-size:12px;font-weight:700;
  background:var(--card2);border:1px solid var(--line);color:var(--dim)}
.stepbtn b{display:block;font-size:14px}
.stepbtn small{display:block;font-size:11.5px;color:var(--dim)}
.stepbtn[aria-current="true"]{border-color:var(--acc);background:linear-gradient(180deg,rgba(59,130,246,.14),transparent)}
.stepbtn[aria-current="true"] .n{background:var(--acc);border-color:var(--acc);color:#fff}
.stepbtn.done .n{background:rgba(34,197,94,.16);border-color:rgba(34,197,94,.5);color:var(--ok)}
.hint{margin-top:6px;padding:10px 12px;border-radius:var(--r2);background:var(--card);border:1px dashed var(--line2);
  font-size:12px;color:var(--dim)}

/* ---------- cartoes ---------- */
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--r);box-shadow:var(--sh);margin-bottom:16px;overflow:hidden}
.card>header{display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center;padding:14px 16px;border-bottom:1px solid var(--line);
  background:linear-gradient(180deg,var(--card2),transparent)}
.card>header h2{font-size:15px}
.card>header .sub{font-size:12px;color:var(--dim)}
.card .body{padding:16px}
.hero{display:flex;flex-wrap:wrap;gap:16px;align-items:center;justify-content:space-between}
.hero .big{font-size:26px;font-weight:700;font-variant-numeric:tabular-nums}
.tiles{display:grid;gap:10px;grid-template-columns:repeat(auto-fit,minmax(170px,1fr))}
.tile{background:var(--card2);border:1px solid var(--line);border-radius:var(--r2);padding:12px}
.tile b{display:block;font-size:14px;margin-bottom:4px}
.stats{display:grid;gap:10px;grid-template-columns:repeat(auto-fit,minmax(118px,1fr))}
.stat{background:var(--card2);border:1px solid var(--line);border-radius:var(--r2);padding:10px 12px}
.stat b{display:block;font-size:20px;font-weight:700;font-variant-numeric:tabular-nums;line-height:1.2}
.stat i{font-style:normal;font-size:11px;color:var(--dim);text-transform:uppercase;letter-spacing:.5px}

/* ---------- formularios ---------- */
label.f{display:block;margin-bottom:12px}
label.f>span{display:block;font-size:12px;color:var(--dim);margin-bottom:5px}
input[type=text],input[type=password],select,textarea{width:100%;padding:10px 12px;border-radius:var(--r2);
  border:1px solid var(--line);background:var(--bg2);color:var(--fg);font:inherit}
input:focus,select:focus,textarea:focus,button:focus-visible,.stepbtn:focus-visible{outline:2px solid var(--acc);outline-offset:2px}
input::placeholder{color:var(--dim);opacity:.75}
.grid2{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(210px,1fr))}
button{border:1px solid var(--line);background:var(--card2);color:var(--fg);border-radius:var(--r2);padding:9px 14px;
  cursor:pointer;font:inherit;transition:.15s;white-space:nowrap}
button:hover{border-color:var(--line2);transform:translateY(-1px)}
button:active{transform:none}
button.p{background:var(--acc);border-color:var(--acc);color:#fff;font-weight:600}
button.p:hover{filter:brightness(1.08)}
button.d{background:rgba(239,68,68,.14);border-color:rgba(239,68,68,.45);color:#fca5a5}
button.g{background:transparent}
button.sm{padding:5px 10px;font-size:12.5px}
.row{display:flex;flex-wrap:wrap;gap:9px;align-items:center}
.row.end{justify-content:flex-end}

/* ---------- opcoes deslizantes (politica) ---------- */
.opts{display:grid;gap:10px;grid-template-columns:repeat(auto-fit,minmax(250px,1fr))}
.pg{display:grid;gap:12px;grid-template-columns:1fr 1fr;align-items:start}
@media (max-width:760px){.pg{grid-template-columns:1fr}}
.pg .f{margin:0}
.pg .f>span{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--dim);margin-bottom:5px}
.pg .f>span::before{content:'';width:4px;height:15px;border-radius:2px;background:var(--acc);flex:none}
.pg select{font-weight:600}
.pg code{font-family:var(--mono);font-size:11.5px;color:var(--acc2)}
.h3{font-size:13px;margin:0 0 8px;display:flex;align-items:center;gap:8px}
.h3::before{content:'';width:4px;height:15px;border-radius:2px;background:var(--acc)}
.explain{margin-top:12px;padding:12px 14px;border-radius:var(--r2);background:var(--bg2);border:1px solid var(--line);
  font-size:13px;color:var(--dim)}
.explain b{color:var(--fg)}

/* ---------- listas/tabelas ---------- */
.list{display:grid;gap:8px}
.item{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center;justify-content:space-between;padding:10px 12px;
  border-radius:var(--r2);border:1px solid var(--line);background:var(--card2)}
.item b{font-size:13.5px}
.item small{color:var(--dim);font-size:12px}
.scroll{overflow:auto;border:1px solid var(--line);border-radius:var(--r2);max-height:300px}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{padding:8px 10px;text-align:left;border-bottom:1px solid var(--line);white-space:nowrap}
th{position:sticky;top:0;background:var(--card2);color:var(--dim);font-size:11.5px;text-transform:uppercase;letter-spacing:.5px;z-index:1}
tbody tr:hover{background:var(--card2)}
td.wrap{white-space:normal;max-width:320px}
.badge{display:inline-flex;align-items:center;gap:5px;padding:2px 9px;border-radius:99px;font-size:11.5px;
  border:1px solid var(--line);background:var(--bg2)}
.badge.ok{color:var(--ok);border-color:rgba(34,197,94,.4);background:rgba(34,197,94,.10)}
.badge.warn{color:var(--warn);border-color:rgba(245,158,11,.4);background:rgba(245,158,11,.10)}
.badge.err{color:var(--err);border-color:rgba(239,68,68,.4);background:rgba(239,68,68,.10)}
.hosts{display:flex;flex-wrap:wrap;gap:8px}
.host{display:inline-flex;align-items:center;gap:8px;padding:6px 10px;border-radius:99px;background:var(--bg2);
  border:1px solid var(--line);font-size:12.5px}
.host i{width:7px;height:7px;border-radius:50%;background:var(--ok);font-style:normal}
.host.deny i{background:var(--err)}
.empty{padding:18px;text-align:center;color:var(--dim);font-size:13px}
.nav{display:flex;justify-content:space-between;gap:10px;margin-top:4px}
#toast{position:fixed;right:16px;bottom:16px;z-index:60;background:var(--card);border:1px solid var(--line2);
  border-left:4px solid var(--acc);border-radius:var(--r2);padding:11px 15px;box-shadow:var(--sh);display:none;max-width:min(420px,92vw)}
#toast.err{border-left-color:var(--err)}
#toast.ok{border-left-color:var(--ok)}

/* ---------- responsivo ---------- */
@media (max-width:1000px){
  .shell{grid-template-columns:1fr;padding:14px 12px 48px}
  .steps{position:static;flex-direction:row;overflow-x:auto;padding-bottom:6px;scrollbar-width:thin}
  .stepbtn{min-width:172px}
  .stepbtn small{display:none}
  .hint{display:none}
}
@media (max-width:620px){
  body{font-size:14px}
  .topin{padding:10px 12px;gap:10px}
  .chips{order:3;width:100%;overflow-x:auto;flex-wrap:nowrap;padding-bottom:2px}
  .tools{order:2;margin-left:auto}
.pbar{padding:0 12px 10px}
.pbar select{flex:1 1 140px;min-width:0}
.pbar .polhint{flex:1 1 100%}
  .hero .big{font-size:22px}
  .nav{flex-direction:column-reverse}
  .nav button{width:100%}
}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style>
</head>
<body>
<header class="top">
  <div class="topin">
    <div class="brand">
      <div class="mark">DP</div>
      <div><b>ServidorPXE $version</b><span id="srvname">-</span></div>
    </div>
    <div class="pill"><i class="dot off" id="dot"></i><span id="statustext">consultando...</span></div>
    <div class="chips" id="chips"></div>
    <div class="tools">
      <div class="toolrow">
        <button class="sm" onclick="load(true)">Atualizar</button>
        <button class="sm p" onclick="ctl('restart')">Reiniciar</button>
        <button class="sm" onclick="sair()">Sair</button>
      </div>
      <span class="who" id="who" title="usuario autenticado"></span>
    </div>
  </div>
  <div class="pbar">
    <label>Politica de boot</label>
    <select id="pmode" onchange="markDirty('pmode');policyHint()" title="Quem pode iniciar pela rede">
      <option value="AllowList">Somente cadastrados</option>
      <option value="Open">Todos os equipamentos</option></select>
    <select id="pdef" onchange="markDirty('pdef');policyHint()" title="O que fazer com quem nao esta cadastrado">
      <option value="Local">Iniciar direto</option>
      <option value="Deny">Negar</option></select>
    <button class="sm p" onclick="savePolicy()">Aplicar</button>
    <span class="polhint" id="polhint"></span>
  </div>
</header>

<div class="shell">
  <nav class="steps" id="steps" aria-label="Passos">
    <button class="stepbtn" data-go="1" aria-current="true"><span class="n">1</span><span><b>Servico e ativos</b><small>status, cadastro e Politica</small></span></button>
    <button class="stepbtn" data-go="2"><span class="n">2</span><span><b>Midia (ISO)</b><small>imagem do Windows 11</small></span></button>
    <div class="hint">Logs no arquivo <b>servidorpxe.log</b> na raiz do projeto.<br>No Passo 2 voce aponta a imagem ISO do Windows 11.</div>
  </nav>

  <main>
    <!-- ================= PASSO 1: SERVICO ================= -->
    <section class="step" data-step="1">
      <div class="card">
        <header><h2>1. Servico e ativos</h2><span class="sub" id="upd">-</span>
          <span style="margin-left:auto" class="row">
            <label class="tiny mut"><input type="checkbox" id="auto" checked style="width:auto;margin-right:5px"> atualizacao automatica (3s)</label>
          </span>
        </header>
        <div class="body">
          <div class="hero">
            <div>
              <div class="big" id="uptime">--:--:--</div>
              <div class="mut tiny" id="updlbl">em execucao neste servidor</div>
            </div>
            <div class="row">
              <button class="p" onclick="ctl('restart')">Reiniciar servico</button>
              <a class="tiny" id="loglink" href="/pxe/servidorpxe.log" target="_blank">log (arquivo de texto)</a>
            </div>
          </div>
          <p class="mut tiny" style="margin:10px 0 0" id="ctlmsg"></p>
        </div>
      </div>
      <div class="card">
        <header><h2>Componentes</h2><span class="sub">o que esta atendendo agora</span></header>
        <div class="body"><div class="tiles" id="tiles"></div></div>
      </div>
      <div class="card">
        <header><h2>Contadores</h2><span class="sub">desde o inicio do servico</span></header>
        <div class="body"><div class="stats" id="stats"></div></div>
      </div>
      <div class="card">
        <header><h2>Atividade recente</h2><span class="sub">ultimos eventos recebidos</span></header>
        <div class="body">
          <div class="grid2">
            <div><h3 class="h3" style="margin-bottom:8px">Boot</h3><div class="scroll" id="boots"></div></div>
            <div><h3 class="h3" style="margin-bottom:8px">DHCP</h3><div class="scroll" id="dhcp"></div></div>
          </div>
          <h3 class="h3" style="margin:16px 0 8px">TFTP</h3><div class="scroll" id="tftp"></div>
        </div>
      </div>
      <div class="card">
        <header><h2>Dispositivos</h2><span class="sub" id="devcount">-</span></header>
        <div class="body">
          <h3 class="h3" style="margin-bottom:8px">Vistos agora (ultimos 20 minutos)</h3>
          <div class="hosts" id="hosts"><div class="empty">nenhum host visto ainda</div></div>
        </div>
      </div>
      <div class="card">
        <header><h2>Cadastrar equipamento</h2><span class="sub">o MAC vira a chave de autorizacao</span></header>
        <div class="body">
          <div class="grid2">
            <label class="f"><span>MAC do equipamento</span>
              <input type="text" id="dmac" placeholder="AA:BB:CC:DD:EE:FF" autocomplete="off"></label>
            <label class="f"><span>Perfil de instalacao</span><select id="dprof"></select></label>
            <label class="f"><span>O que fazer no boot</span><select id="dact">
              <option value="Boot">Iniciar direto</option>
              <option value="Deny">Negado</option></select></label>
            <label class="f"><span>Modelo (opcional, para OUI)</span>
              <input type="text" id="dmodel" placeholder="ex.: PC Engines APU" autocomplete="off"></label>
            <label class="f" style="grid-column:1/-1"><span>Observacao (opcional)</span>
              <input type="text" id="dnote" placeholder="ex.: notebook do financeiro" autocomplete="off"></label>
          </div>
          <div class="row"><button class="p" onclick="addDev()">Cadastrar</button>
            <span class="mut tiny">No modo <b>Todos os equipamentos</b> o cadastro nao e obrigatorio.</span></div>
        </div>
      </div>
      <div class="card">
        <header><h2>Cadastrados</h2></header>
        <div class="body"><div class="scroll" id="devsWrap"></div></div>
      </div>
      <div class="nav"><span></span><button class="p" onclick="showStep(2)">Proximo: Midia (ISO)</button></div>
    </section>

    <!-- ================= PASSO 2: MIDIA ================= -->
    <section class="step" data-step="2" hidden>
      <div class="card">
        <header><h2>2. Midia (ISO)</h2><span class="sub" id="mediachip">-</span></header>
        <div class="body">
          <p class="mut" style="margin:0 0 14px">Informe a <b>pasta</b> que contem a imagem <code class="mono">.iso</code> do Windows 11
             (por exemplo <code class="mono">D:\ISOs</code>). O ServidorPXE monta a ISO, extrai o WinPE e publica o share de rede.</p>
          <div class="grid2">
            <label class="f"><span>Pasta da ISO</span>
              <input type="text" id="midir" placeholder="D:\ISOs" autocomplete="off" oninput="markDirty('dir')"></label>
            <label class="f"><span>Imagem .iso encontrada na pasta</span>
              <select id="miso" onchange="markDirty('iso')"></select></label>
            <label class="f"><span>Nome da midia (slug)</span>
              <input type="text" id="mslug" placeholder="win11" autocomplete="off" oninput="markDirty('slug')"></label>
          </div>
          <div class="row">
            <button class="p" onclick="saveMedia()">Salvar midia</button>
            <button onclick="scanMedia()">Verificar pasta</button>
            <button class="g" onclick="buildMedia()">Construir midia (WinPE)</button>
          </div>
          <p class="mut tiny" style="margin:12px 0 0" id="mediamsg"></p>
          <div class="explain" id="mediastate" style="display:none"></div>
        </div>
      </div>
      <div class="card">
        <header><h2>Diagnostico do ambiente</h2><span class="sub" id="envchip">-</span></header>
        <div class="body">
          <p class="mut tiny" style="margin:0 0 10px">Verificacao automatica do que o boot por rede precisa.
             Rodar em rede corporativa (com outro DHCP no ar) e permitido: o ServidorPXE entra como <b>proxy DHCP</b>.</p>
          <div class="list" id="envlist"><div class="empty">consultando...</div></div>
        </div>
      </div>
      <div class="card">
        <header><h2>Perfis de instalacao</h2><span class="sub">imagem aplicada em cada equipamento</span></header>
        <div class="body"><div class="list" id="profs"></div></div>
      </div>
      <div class="card">
        <header><h2>Midias publicadas</h2><span class="sub">pastas geradas em www\_dorpxe\media</span></header>
        <div class="body"><div class="list" id="medias"></div></div>
      </div>
      <div class="nav"><button class="g" onclick="showStep(1)">Voltar: Servico e ativos</button><span></span></div>
    </section>
  </main>
</div>
<div id="toast"></div>
<script>
var T=(new URLSearchParams(location.search)).get('t')||sessionStorage.getItem('dorpxe_t')||'';
if(T)sessionStorage.setItem('dorpxe_t',T);
var LL=document.getElementById('loglink');
if(LL)LL.href='/pxe/servidorpxe.log'+(T?'?t='+encodeURIComponent(T):'');
var D=null,DIRTY={};
function toast(m,err){var t=document.getElementById('toast');t.textContent=m;t.className=err?'err':'ok';
  t.style.display='block';clearTimeout(t._h);t._h=setTimeout(function(){t.style.display='none'},4200)}
function api(u,o){o=o||{};o.credentials='same-origin';o.cache='no-store';
  o.headers=Object.assign({'X-DorPXE-Token':T},o.headers||{});
  return fetch(u,o).then(function(r){
    if(r.status===401){location.href='/pxe/admin';throw new Error('sessao expirada - login novamente')}
    return r.text().then(function(t){
    var j=null;try{j=JSON.parse(t)}catch(e){}
    if(!r.ok)throw new Error((j&&j.error)||('HTTP '+r.status));
    return j;})})}
function post(u,b){return api(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b||{})})}
function esc(s){var d=document.createElement('div');d.textContent=(s===null||s===undefined)?'':String(s);return d.innerHTML}
function hhmm(s){try{return new Date(s).toLocaleTimeString('pt-BR')}catch(e){return s||''}}
function bytes(n){n=+n||0;var u=['B','KB','MB','GB','TB'],i=0;while(n>=1024&&i<u.length-1){n/=1024;i++}
  return n.toFixed(i?1:0)+' '+u[i]}
function num(n){n=+n||0;return n>=1000?n.toLocaleString('pt-BR'):String(n)}
function markDirty(k){DIRTY[k]=true}
function isDirty(){return !!(DIRTY.dir||DIRTY.iso||DIRTY.slug)}
function clearDirty(){DIRTY={}}
function badge(txt,cls){return '<span class="badge '+(cls||'')+'">'+esc(txt)+'</span>'}
function tbl(cols,rows,empty){if(!rows||!rows.length)return '<div class="empty">'+esc(empty)+'</div>';
  return '<table><thead><tr>'+cols.map(function(c){return '<th>'+esc(c[0])+'</th>'}).join('')+'</tr></thead><tbody>'+
    rows.map(function(r){return '<tr>'+cols.map(function(c){return '<td'+(c[2]?' class="wrap"':'')+'>'+(c[2]?c[1](r):esc(c[1](r)))+'</td>'}).join('')+'</tr>'}).join('')+
    '</tbody></table>'}
function showStep(n){n=Math.min(2,Math.max(1,+n||1));localStorage.setItem('dorpxe_step',n);
  [].forEach.call(document.querySelectorAll('section.step'),function(s){s.hidden=(+s.getAttribute('data-step')!==n)});
  [].forEach.call(document.querySelectorAll('.stepbtn'),function(b){b.setAttribute('aria-current',b.getAttribute('data-go')===String(n)?'true':'false')});
  window.scrollTo({top:0,behavior:'smooth'});location.hash='p'+n}
function stepDone(n,d){
  if(!d)return false;
  if(n===1){return !!(d.components&&d.components.http)&&((d.devices||[]).length>0||(d.policy&&d.policy.Mode==='Open'));}
  if(n===2){var m=d.mediaCfg||{};var md=d.media||[];return md.length>0&&md.every(function(x){return x.BootWim;});}
  return false;
}
function midState(d){
  var m=d.mediaCfg||{},md=d.media||[];
  if(md.length&&md.every(function(x){return x.BootWim;}))return{cls:'good',txt:'pronta ('+md.length+')'};
  if(md.length)return{cls:'warn',txt:'incompleta'};
  if(m.IsoDir||(m.Iso&&m.Iso.length))return{cls:'warn',txt:'pendente'};
  return{cls:'bad',txt:'nao configurada'};
}
function head(d){
  var c=d.components||{},s=d.stats||{},live=!!c.http,ms=midState(d);
  document.getElementById('dot').className='dot '+(live?'on':'off');
  document.getElementById('statustext').textContent=live?('Em execucao - HTTP na porta '+d.httpPort):'Servico parado';
  document.getElementById('srvname').textContent=d.name+'  '+d.address+':'+d.httpPort;
  document.getElementById('upd').textContent='atualizado '+new Date().toLocaleTimeString('pt-BR');
  document.getElementById('uptime').textContent=d.uptime||'--:--:--';
  document.getElementById('updlbl').textContent=live?('em execucao ha '+d.uptime+' neste servidor'):'nenhum servico em execucao';
  var chips=[
    ['Imagem',ms.txt,ms.cls],
    ['Uptime',d.uptime,''],
    ['DHCP',num(s.DhcpRequests),'acc'],
    ['Ofertas',num(s.DhcpOffers),'good'],
    ['TFTP',num(s.TftpRequests),''],
    ['HTTP',num(s.HttpRequests),''],
    ['Boots',num(s.Boots),'good'],
    ['Negados',num(s.DhcpDenied+s.TftpDenied),((s.DhcpDenied+s.TftpDenied)>0?'bad':'')],
    ['Hosts ativos',num((d.hosts||[]).length),'acc']
  ];
    document.getElementById('chips').innerHTML=chips.map(function(x){
      return '<span class="chip '+x[2]+'">'+esc(x[0])+' <b>'+esc(x[1])+'</b></span>'}).join('');
    var w=document.getElementById('who');
    if(w){w.textContent=(d.user?'autenticado: '+d.user:(T?'acesso local (token)':'local'));w.title=w.textContent}
  [].forEach.call(document.querySelectorAll('.stepbtn'),function(b){
    var n=+b.getAttribute('data-go');b.classList.toggle('done',stepDone(n,d)&&n!==STEP)});
  var tiles=[
    ['HTTP (iPXE, arquivos, console)',live?'ativo':'inativo',live?'ok':'err','porta '+d.httpPort+' - '+d.address],
    ['TFTP (iPXE, wimboot)',c.tftp?'ativo':'inativo',c.tftp?'ok':'err','porta 69'],
    ['DHCP proxy',c.dhcp?'ativo':'inativo',c.dhcp?'ok':'err',((d.dhcp&&d.dhcp.mode)?d.dhcp.mode:'')+' - next '+((d.dhcp&&d.dhcp.nextServer)?d.dhcp.nextServer:'-')],
    ['Imagem WinPE',ms.txt,ms.cls,(m0(d)&&m0(d).BootWim)?'boot.wim extraido':'rode Construir midia no Passo 2']
  ];
  document.getElementById('tiles').innerHTML=tiles.map(function(t){
    return '<div class="tile"><b>'+esc(t[0])+' '+badge(t[1],t[2])+'</b><small class="mut">'+esc(t[3])+'</small></div>'}).join('');
  var st=[['requisicoes DHCP',s.DhcpRequests],['ofertas',s.DhcpOffers],['negadas',s.DhcpDenied],['requisicoes TFTP',s.TftpRequests],
          ['bytes TFTP',bytes(s.TftpBytes)],['requisicoes HTTP',s.HttpRequests],['bytes HTTP',bytes(s.HttpBytes)],['boots',s.Boots]];
  document.getElementById('stats').innerHTML=st.map(function(x){
    return '<div class="stat"><b>'+esc(num(x[1]))+'</b><i>'+esc(x[0])+'</i></div>'}).join('');
}
function m0(d){return (d&&d.mediaCfg)||{}}
function media(d){
  var m=d.mediaCfg||{},profs=d.profiles||[];
  var sel=document.getElementById('miso');
  var opts=['<option value="">(nao usar arquivo .iso)</option>'];
  (m.Isos||[]).forEach(function(i){opts.push('<option value="'+esc(i.Path)+'">'+esc(i.Name)+' - '+i.SizeMB+' MB</option>')});
  var html=opts.join('');
  if(sel.innerHTML!==html)sel.innerHTML=html;
  if(!DIRTY.iso){
    var want=(m.Iso&&m.Iso.length)?m.Iso[0]:'';
    sel.value=want;
    if(sel.selectedIndex<0)sel.value='';
    if(!DIRTY.dir)document.getElementById('midir').value=m.IsoDir||'';
    if(!DIRTY.slug)document.getElementById('mslug').value=m.Slug||'';
  }
  var ms=midState(d);
  document.getElementById('mediachip').innerHTML='status da imagem: '+badge(ms.txt,ms.cls);
  var st=document.getElementById('mediastate');st.style.display='block';
  st.innerHTML='<b>Pasta configurada:</b> '+(esc(m.IsoDir||'(vazia)'))+'<br><b>ISO em uso:</b> '+
    esc((m.Iso&&m.Iso.length)?m.Iso.join(', '):'nenhuma (a pasta sera usada direto)')+'<br>'+
    '<b>Origem do WinPE:</b> '+esc(m.WinPeSource||'-')+'<br><b>Fonte:</b> '+
    (m.BootWimSource?esc(m.BootWimSource):'<span class="mut">nenhuma - informe a pasta no passo acima</span>')+'<br>'+
    '<b>boot.wim extraido:</b> '+
    (m.BootWim?esc(m.BootWim):'<span class="mut">ainda nao - use "Construir midia" para extrair da ISO</span>');
  document.getElementById('profs').innerHTML=profs.length?profs.map(function(p){
    return '<div class="item"><div><b>'+esc(p.Name)+'</b> <small>'+esc(p.Title||'')+'</small></div><div class="row">'+
      badge(esc(p.Image)+' ['+(+p.Index||0)+']','')+(p.Ready?badge('pronto para instalar','ok'):badge('sem midia WinPE','warn'))+'</div></div>'}).join('')
    :'<div class="empty">nenhum perfil em config\\ServidorPXE.config.psd1</div>';
  document.getElementById('medias').innerHTML=(d.media||[]).length?d.media.map(function(x){
    return '<div class="item"><div><b>'+esc(x.Name)+'</b> <small class="mono">'+esc(x.Path)+'</small></div><div class="row">'+
      badge(x.Files+' arquivos','')+badge(bytes(x.Size*1048576),'')+(x.Setup?badge('setup.exe OK','ok'):badge('sem setup.exe','warn'))+
      (x.BootWim?badge('boot.wim OK','ok'):badge('sem boot.wim','warn'))+'</div></div>'}).join('')
    :'<div class="empty">nenhuma midia extraida ainda - use "Construir midia" no Passo 2</div>';
}
function envlist(d){
  var e=d.env||[],el=document.getElementById('envlist');
  var bad=e.filter(function(x){return x.Level==='bad'}).length;
  var warn=e.filter(function(x){return x.Level==='warn'}).length;
  var chip=document.getElementById('envchip');
  if(chip)chip.textContent=bad?(bad+' pendencia(s) critica(s)'):(warn?(warn+' aviso(s)'):'tudo pronto');
  el.innerHTML=e.map(function(x){
    var cls=x.Level==='ok'?'ok':(x.Level==='warn'?'warn':'bad');
    var mark=x.Level==='ok'?'OK':(x.Level==='warn'?'AVISO':'FALHA');
    return '<div class="item"><div><b>'+esc(x.Name)+'</b> <small class="mono">'+esc(x.Detail||'')+'</small></div>'+
      '<div class="row"><span class="badge '+cls+'">'+mark+'</span></div></div>'}).join('');
}
function policy(d){
  var p=d.policy||{},m=document.getElementById('pmode'),f=document.getElementById('pdef');
  // nao sobrescreve o que o usuario escolheu e ainda nao aplicou (auto-refresh de 3s)
  if(m&&!DIRTY.pmode&&p.Mode)m.value=(p.Mode==='Open'?'Open':'AllowList');
  if(f&&!DIRTY.pdef){
    var def=p.DefaultAction;
    f.value=(def==='Deny'||def==='Menu'||def==='DenyMenu')?'Deny':'Local';
  }
  policyHint();
}
function policyHint(){
  var mode=(document.getElementById('pmode')||{}).value;
  var def=(document.getElementById('pdef')||{}).value;
  var t;
  if(mode==='Open'){
    t=(def==='Deny')
      ? '<b>Resumo:</b> todos sao atendidos, mas so <b>cadastrado</b> instala; os demais recebem boot negado.'
      : '<b>Resumo:</b> qualquer maquina da rede instala o Windows 11 direto, mesmo sem cadastro.';
    if(def!=='Deny')t+=' <b style="color:#fbbf24">use so em rede isolada.</b>';
  }else{
    t='<b>Resumo:</b> so <b>cadastrado</b> instala; qualquer outra maquina e negada. A segunda opcao e ignorada neste modo.';
  }
  var h=document.getElementById('polhint');if(!h)return;
  h.innerHTML=t+((DIRTY.pmode||DIRTY.pdef)?' <b style="color:#fbbf24">alteracao nao aplicada - clique em "Aplicar".</b>':'');
}
function devices(d){
  var h=d.hosts||[],el=document.getElementById('hosts'),devs=d.devices||[];
  document.getElementById('devcount').textContent=devs.length+' cadastrado(s)'+
    ((d.policy&&d.policy.Mode==='AllowList'&&devs.length===0)?' - com a allowlist vazia todo host e negado':'');
  el.innerHTML=h.length?h.map(function(x){
    var a=String(x.Action||'').toLowerCase();
    var deny=(a.indexOf('neg')>=0)||(a.indexOf('deny')>=0);
    return '<span class="host'+(deny?' deny':'')+'"><i></i><b class="mono">'+esc(x.Mac)+'</b> '+
      '<span class="mut">'+esc(x.Ip||'-')+' - '+esc(x.Type||'')+' - '+esc(hhmm(x.At))+'</span></span>'}).join('')
    :'<div class="empty">nenhum host visto ainda (DHCP/TFTP/boot)</div>';
  document.getElementById('devsWrap').innerHTML=tbl(
    [['MAC',function(r){return r.mac}],['Perfil',function(r){return r.profile||'(padrao)'}],
     ['Acao no boot',function(r){return r.action==='Menu'?'Mostrar menu':(r.action==='Deny'?'Negado':'Iniciar direto')},true],
     ['Modelo',function(r){return r.model||'-'},true],['Observacao',function(r){return r.note||'-'},true],
     ['',function(r){return '<button class="sm d" onclick="rmDev(&quot;'+esc(r.mac)+'&quot;)">remover</button>'}]],
    devs,'nenhum equipamento cadastrado - no modo AllowList todo host sera negado');
  var sel=document.getElementById('dprof'),names=[];
  (d.profiles||[]).forEach(function(p){if(names.indexOf(p.Name)<0)names.push(p.Name)});
  var cur=sel.value,html=names.map(function(n){return '<option>'+esc(n)+'</option>'}).join('');
  if(sel.innerHTML!==html){sel.innerHTML=html;if(names.indexOf(cur)>=0)sel.value=cur}
}
function events(d){
  var e=d.events||{};
  document.getElementById('boots').innerHTML=tbl(
    [['Hora',function(r){return hhmm(r.At)}],['MAC',function(r){return r.Mac}],['IP',function(r){return r.Ip}],
     ['Decisao',function(r){return r.Action+(r.Reason?' ('+r.Reason+')':'')},true]],
    (e.boots||[]).slice().reverse(),'nenhum boot atendido');
  document.getElementById('dhcp').innerHTML=tbl(
    [['Hora',function(r){return hhmm(r.At)}],['MAC',function(r){return r.Mac}],['Tipo',function(r){return r.Type}],
     ['Boot file',function(r){return r.BootFile||'-'},true]],
    (e.dhcp||[]).slice().reverse(),'nenhum evento DHCP');
  document.getElementById('tftp').innerHTML=tbl(
    [['Hora',function(r){return hhmm(r.At)}],['IP',function(r){return r.Ip}],['Arquivo',function(r){return r.File},true],
     ['Bytes',function(r){return bytes(r.Bytes)}]],
    (e.tftp||[]).slice().reverse(),'nenhum evento TFTP');
}
function render(d){D=d;head(d);media(d);envlist(d);policy(d);devices(d);events(d)}
function load(manual){
  return api('/pxe/api/status').then(function(d){
    render(d);
    if(manual){clearDirty();toast('Console atualizado')}
  }).catch(function(e){
    document.getElementById('dot').className='dot off';
    document.getElementById('statustext').textContent='sem resposta do servico';
  });
}
function savePolicy(){
  var mode=document.getElementById('pmode').value;
  var def=document.getElementById('pdef').value;
  if(!mode||!def){toast('Escolha as duas opcoes',true);return}
  post('/pxe/api/policy.set',{mode:mode,'default':def}).then(function(d){
    delete DIRTY.pmode;delete DIRTY.pdef;
    render(d);toast('Politica aplicada: '+(mode==='Open'?'todos':'somente cadastrados')+' / '+(def==='Deny'?'negar':'iniciar direto'))})
    .catch(function(e){toast(e.message,true)});
}
function saveMedia(){
  var body={dir:document.getElementById('midir').value.trim(),iso:document.getElementById('miso').value,slug:document.getElementById('mslug').value.trim()};
  post('/pxe/api/media.set',body).then(function(d){
    clearDirty();render(d);toast('Midia salva. Use "Construir midia" para gerar o WinPE.')})
    .catch(function(e){toast(e.message,true)});
}
function scanMedia(){
  var dir=document.getElementById('midir').value.trim();
  if(!dir){toast('Informe a pasta da ISO',true);return}
  post('/pxe/api/media.set',{dir:dir}).then(function(d){
    clearDirty();render(d);
    var n=(d.mediaCfg&&d.mediaCfg.Isos||[]).length;
    toast(n?('Pasta ok - '+n+' imagem(ns) .iso encontrada(s)'):'Pasta ok, mas nenhuma imagem .iso encontrada',!n)})
    .catch(function(e){toast(e.message,true)});
}
function buildMedia(){
  if(!confirm('Montar a ISO e construir o WinPE agora? Pode levar alguns minutos e exige Administrador.'))return;
  post('/pxe/api/media.build',{}).then(function(r){
    toast(r.message||'Construindo midia em segundo plano')})
    .catch(function(e){toast(e.message,true)});
}
function addDev(){
  var b={mac:document.getElementById('dmac').value.trim(),profile:document.getElementById('dprof').value,
         action:document.getElementById('dact').value,model:document.getElementById('dmodel').value.trim(),
         note:document.getElementById('dnote').value.trim()};
  if(!b.mac){toast('Informe o MAC',true);return}
  post('/pxe/api/device.add',b).then(function(d){
    ['dmac','dmodel','dnote'].forEach(function(i){document.getElementById(i).value=''});
    render(d);toast('Equipamento cadastrado')}).catch(function(e){toast(e.message,true)});
}
function rmDev(mac){
  if(!confirm('Remover '+mac+' da allowlist?'))return;
  post('/pxe/api/device.remove',{mac:mac}).then(function(d){render(d);toast('Removido')}).catch(function(e){toast(e.message,true)});
}
function ctl(a){
    if(!confirm('Reiniciar o servidor ServidorPXE? O console fica indisponivel por alguns segundos.'))return;
    post('/pxe/api/service.'+a,{}).then(function(r){
      document.getElementById('ctlmsg').textContent=r.message;toast(r.message);
      setTimeout(function(){load()},4000)}).catch(function(e){toast(e.message,true)});
  }
function sair(){
    if(!confirm('Encerrar a sessao neste navegador?'))return;
    post('/pxe/api/logout',{}).then(function(){sessionStorage.removeItem('dorpxe_t');location.href='/pxe/admin'})
      .catch(function(){location.href='/pxe/admin'});
  }
[].forEach.call(document.querySelectorAll('.stepbtn'),function(b){
  b.addEventListener('click',function(){showStep(b.getAttribute('data-go'))})});
var STEP=1,h=(location.hash||'').replace('#p','');
if(h&&+h>=1&&+h<=3)STEP=+h;else{var s=localStorage.getItem('dorpxe_step');if(s&&+s<=3)STEP=+s}
showStep(STEP);
load();
setInterval(function(){if(document.getElementById('auto').checked&&!isDirty()&&!document.hidden)load()},3000);
</script>
</body>
</html>
"@
}
