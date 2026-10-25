[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Help', 'Init', 'Start', 'Restart', 'Stop', 'Status', 'Install', 'Build-Media', 'Device', 'Test', 'Health', 'Admin', 'Uninstall')]
    [string]$Verb = 'Help',
    [string]$Config,
    [switch]$Admin,
    [string[]]$Iso,
    [switch]$Minimal,
    [string[]]$Modes,
    [string[]]$Architectures,
    [switch]$SkipIso,
    [ValidateSet('List', 'Add', 'Remove', 'Model', 'Prefix', 'Policy')]
    [string]$Action = 'List',
    [string]$Mac,
    [ValidateSet('Boot', 'Menu', 'Deny')]
    [string]$DeviceAction = 'Boot',
    [string]$Profile,
    [string]$Model,
    [string]$Oui,
    [string]$Prefix,
    [string]$Note,
    [ValidateSet('AllowList', 'Open')]
    [string]$Mode,
    [ValidateSet('Local', 'Menu', 'Deny')]
    [string]$DefaultAction,
    [string]$WinPeSource,
    [int]$DurationSec = 0,
    [int]$Port = 0,
    [switch]$NoDhcp,
    [switch]$NoTftp,
    [switch]$AllowNonAdmin,
    [switch]$Background,
    [switch]$Force,
    [switch]$Json,
    [switch]$Examples
)

$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

foreach ($f in (Get-ChildItem -Path (Join-Path $script:Root 'lib\*.ps1') | Sort-Object Name)) {
    . $f.FullName
}

$script:Mutex = $null
$script:Service = $null

function Get-DorPXEConfig2 {
    param([string]$Path)
    return (Import-DorPXEConfig -Path $Path)
}

function Start-DorPXEStatusWriter {
    param($Job, [string]$Path)
    $obj = [ordered]@{
        pid        = $PID
        version    = (Get-DorPXEVersion)
        server     = $Job.ServerName
        address    = $Job.ServerAddress
        started    = $Job.State.StartTime.ToString('o')
        updated    = (Get-Date).ToString('o')
        dhcp       = $Job.Config.Dhcp.Enabled -and -not $NoDhcp
        tftp       = -not $NoTftp
        http       = $true
        httpPort   = $Job.Config.Server.HttpPort
        policy     = $Job.Config.Policy.Mode
        default    = $Job.Config.Policy.DefaultAction
        profiles   = @((Get-DorPXEProfiles -Config $Job.Config | ForEach-Object { $_.Name }))
        stats      = $Job.State.Stats
    }
    $json = [pscustomobject]$obj
    [IO.File]::WriteAllText($Path, ($json | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

function Stop-DorPXEService {
    param($Job)
    if (-not $Job) { return }
    Write-DorPXELog 'ServidorPXE: encerrando...' -Level Info -Component core
    $errs = New-Object System.Collections.ArrayList
    # 1) cancela: os loops de accept (HTTP) e de socket (DHCP/TFTP) observam o token
    #    e saem em menos de 1s, fechando listener e sockets.
    try { $Job.Stop.Cancel() } catch { [void]$errs.Add("cancel: $($_.Exception.Message)") }
    # 2) nao usamos RunspacePool.Stop()/Close(): eles esperam os runspaces ocupados
    #    terminarem e travam o encerramento. O pool e liberado com o fim do processo.
    try { $Job.State['Running'] = $false } catch { [void]$errs.Add("state: $($_.Exception.Message)") }
    $deadline = (Get-Date).AddMilliseconds(1500)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 150
        if ($Job.State -and $Job.State.Pool -and $Job.State.Pool.Information.State -eq 'Closed') { break }
    }
    try { $Job.Stop.Dispose() } catch { [void]$errs.Add("dispose: $($_.Exception.Message)") }
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { [void]$errs.Add("mutex: $($_.Exception.Message)") } }
    $sf = Join-Path (Get-DorPXEPath).State 'status.json'
    if (Test-Path -LiteralPath $sf) { try { Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue } catch { } }
    if ($errs.Count -gt 0) { Write-DorPXELog ('ServidorPXE: avisos ao encerrar: ' + ($errs -join ' | ')) -Level Warn -Component core }
    Write-DorPXELog 'ServidorPXE: encerrado.' -Level Info -Component core
}

# Encerra a instancia registrada em state\status.json (outro processo).
# Devolve @{ Stopped; Pid; Message } em vez de escrever no pipeline, para que
# o chamador decida o que exibir e possa abortar quando o processo persiste.
function Stop-DorPXERunningInstance {
    param()
    $f = Join-Path (Get-DorPXEPath).State 'status.json'
    if (-not (Test-Path -LiteralPath $f)) {
        return @{ Stopped = $true; Pid = 0; Message = 'Nenhum servico registrado em state\status.json.' }
    }
    $st = [IO.File]::ReadAllText($f) | ConvertFrom-Json
    if (-not (Get-Process -Id $st.pid -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        return @{ Stopped = $true; Pid = 0; Message = 'O processo nao esta mais rodando; os servicos foram liberados ao sair.' }
    }
    try { Stop-Process -Id $st.pid -Force -ErrorAction Stop }
    catch {
        return @{ Stopped = $false; Pid = $st.pid; Message = ("ATENCAO: nao foi possivel encerrar o PID {0} - execute como Administrador. ({1})" -f $st.pid, $_.Exception.Message) }
    }
    Start-Sleep -Milliseconds 400
    if (Get-Process -Id $st.pid -ErrorAction SilentlyContinue) {
        return @{ Stopped = $false; Pid = $st.pid; Message = "ATENCAO: o PID $($st.pid) continua ativo apos o pedido de parada." }
    }
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    return @{ Stopped = $true; Pid = $st.pid; Message = "ServidorPXE (PID $($st.pid)) encerrado." }
}

function Start-DorPXEService {
    param($Cfg, [int]$Port = 0)
    $needsAdmin = ($Cfg.Dhcp.Enabled -and -not $NoDhcp)
    if ($needsAdmin -and -not (Test-DorPXEAdmin)) {
        if (-not $AllowNonAdmin) { throw 'Execute como administrador (necessario para UDP/67, UDP/69 e regras de firewall). Use -AllowNonAdmin apenas para diagnostico.' }
        Write-DorPXELog 'AVISO: sem elevacao - o firewall nao sera liberado e o socket de UDP/67 pode falhar (somente diagnostico).' -Level Warn -Component core
    }
    if ($needsAdmin) {
        foreach ($pt in @(@(67, 'UDP'), @([int]$Cfg.Server.TftpPort, 'UDP'))) {
            if (-not $NoTftp -or $pt[0] -eq 67) {
                if (-not (Test-DorPXEPortFree -Port $pt[0] -Protocol $pt[1])) {
                    Write-DorPXELog ("AVISO: porta {0}/{1} ja esta em uso (outro servidor DHCP/TFTP?). O processo pode nao conseguir abrir o socket." -f $pt[0], $pt[1]) -Level Warn -Component core
                }
            }
        }
    }
    $p = Get-DorPXEPath
    $address = if ($Cfg.Server.Address -and $Cfg.Server.Address -ne 'auto') { $Cfg.Server.Address } else { Get-DorPXEIPv4 -BindAddress $Cfg.Dhcp.BindAddress }
    if (-not $address) { throw 'Nao foi possivel determinar o IPv4 do servidor. Defina Server.Address no config.' }
    # Congela o endereco resolvido na config em memoria: evita que cada thread (runspace)
    # refaca Get-NetAdapter/Get-NetRoute (~3s de CIM) ao montar os scripts iPXE.
    if (-not $Cfg.Server.Address -or $Cfg.Server.Address -eq 'auto') { $Cfg.Server['Address'] = $address }
    if ($Port -gt 0) { $Cfg.Server['HttpPort'] = $Port }

    $script:Mutex = New-Object Threading.Mutex($false, 'Global\ServidorPXE-Server')
    if (-not $script:Mutex.WaitOne(0)) { throw 'Ja existe uma instancia do ServidorPXE em execucao (use -Verb Status ou Restart).' }

    # preflight HTTP (depois do mutex: o proprio ServidorPXE usa http.sys, dont PID 4)
    $httpPort = [int]$Cfg.Server.HttpPort
    if (-not (Test-DorPXEPortFree -Port $httpPort -Protocol 'TCP')) {
        $who = Get-DorPXEProcessOnPort -Port $httpPort -Protocol 'TCP'
        if (-not $who -or $who -match 'PID 4') { $who = 'http.sys (listener HTTP do Windows)' }
        $alt = if ($httpPort -ne 8080) { 8080 } else { 8081 }
        try { $script:Mutex.ReleaseMutex() } catch { }
        throw ("Porta HTTP {0} ocupada por {1}. Use outra porta: .\ServidorPXE.ps1 Start -Port {2} (ou altere Server.HttpPort no config)." -f $httpPort, $who, $alt)
    }

    $state = New-DorPXEState
    $job = [pscustomobject]@{
        Config       = $Cfg
        State        = $state
        ServerName   = $Cfg.Server.Name
        ServerAddress = $address
        Components   = @{ Http = $true; Dhcp = [bool]($Cfg.Dhcp.Enabled -and -not $NoDhcp); Tftp = [bool](-not $NoTftp) }
        Stop         = (New-Object Threading.CancellationTokenSource)
    }
    $script:Service = $job

    $blocking = @()
    if ($Cfg.Dhcp.Enabled -and -not $NoDhcp) {
        $blocking += @{ Code = 'param($x) Start-DorPXEDhcpServer @x'; Args = @{ Job = $job } }
    }
    if (-not $NoTftp) {
        $blocking += @{ Code = 'param($x) Start-DorPXETftpServer @x'; Args = @{ Job = $job } }
    }
    $blocking += @{ Code = 'param($x) Start-DorPXEHttpServer @x'; Args = @{ Job = $job } }

    $min = [Math]::Max(2, [int]$Cfg.Security.MaxConcurrentHttp)
    $max = [Math]::Max($min, [int]$Cfg.Security.MaxConcurrentTftp)
    $pool = New-DorPXERunspacePool -Name 'dorpxe' -Min $min -Max $max -BlockingScripts $blocking -LogFile $script:DorPXELogFile -LogLevel ([string]$Cfg.Log.Level)
    $state['Pool'] = $pool
    $pool.Start()
    Write-DorPXEAutoExec -Config $Cfg | Out-Null
    $statusFile = Join-Path $p.State 'status.json'
    Start-Sleep -Milliseconds 800
    Write-DorPXELog "=== ServidorPXE $(Get-DorPXEVersion) iniciado em $address (PID $PID) ===" -Level Info -Component core
    Write-DorPXELog "DHCP=$(($blocking | Where-Object { $_.Code -match 'Dhcp' }).Count) HTTP=1 URL=$(Get-DorPXEBaseUrl -Config $Cfg)/pxe/health.txt" -Level Info -Component core
    Write-Output ''
    Write-Output "PXE    : $(Get-DorPXEBaseUrl -Config $Cfg)/pxe/boot.ipxe?mac=00:00:00:00:00:01"
    Write-Output "console: $(Get-DorPXEAdminUrl -Config $Cfg -Port ([int]$Cfg.Server.HttpPort))  (login com usuario local do Windows)"
    Write-Output ''
    try {
        Start-DorPXEStatusWriter -Job $job -Path $statusFile
    }
    catch { Write-DorPXELog "status.json: falha ao gravar - $($_.Exception.Message)" -Level Warn -Component core }
    try {
        $end = if ($DurationSec -gt 0) { (Get-Date).AddSeconds($DurationSec) } else { $null }
        while ($true) {
            if ($end -and (Get-Date) -gt $end) { break }
            Start-Sleep -Seconds 2
            try { Start-DorPXEStatusWriter -Job $job -Path $statusFile } catch { }
        }
    }
    finally {
        # nunca deixa o shutdown pela metade: se a funcao nao estiver visivel,
        # faz a limpeza na mão
        if (Get-Command Stop-DorPXEService -ErrorAction SilentlyContinue) { Stop-DorPXEService -Job $job }
        else {
            Write-DorPXELog 'ServidorPXE: Stop-DorPXEService indisponivel; limpeza direta.' -Level Warn -Component core
            try { $job.Stop.Cancel() } catch { }
            if ($job.State -and $job.State.Pool) { try { $job.State.Pool.Stop() } catch { } }
            if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { } }
        }
    }
}

function Show-DorPXEStatus {
    param($Cfg, [switch]$AsJson)
    $p = Get-DorPXEPath
    $f = Join-Path $p.State 'status.json'
    $st = $null
    if (Test-Path -LiteralPath $f) {
        try { $st = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { }
    }
    if (-not $st) {
        Write-Output 'ServidorPXE: nenhum servico em execucao (sem state\status.json).'
        return
    }
    if ($AsJson) { $st | ConvertTo-Json -Depth 5; return }
    $up = (Get-Date) - [datetime]$st.started
    Write-Output ("ServidorPXE {0}  PID {1}  {2} ({3})" -f $st.version, $st.pid, $st.server, $st.address)
    Write-Output ("em execucao : {0:hh\:mm\:ss}  (atualizado {1})" -f $up, $st.updated)
    Write-Output ("servicos    : DHCP={0} TFTP={1} HTTP={2} (porta {3})" -f $st.dhcp, $st.tftp, $st.http, $st.httpPort)
    Write-Output ("politica    : {0} (padrao {1})  perfis: {2}" -f $st.policy, $st.default, ($st.profiles -join ', '))
    $s = $st.stats
    Write-Output ("estatisticas: dhcp req={0} oferta={1} negada={2} | tftp req={3} bytes={4} | http req={5} bytes={6} | boots={7}" -f `
            $s.DhcpRequests, $s.DhcpOffers, $s.DhcpDenied, $s.TftpRequests, $s.TftpBytes, $s.HttpRequests, $s.HttpBytes, $s.Boots)
    $url = "http://$($st.address):$($st.httpPort)/pxe/log.json?last=15"
    Write-Output "log json     : $url"
}

function Invoke-DorPXEDeviceCommand {
    param($Cfg)
    switch ($Action) {
        'List' {
            $db = Get-DorPXEDeviceDb
            Write-Output 'Dispositivos cadastrados:'
            if (@($db.Devices).Count -eq 0) { Write-Output '  (nenhum)' }
            foreach ($d in $db.Devices) {
                Write-Output ("  {0}  perfil={1} acao={2} modelo={3} {4}" -f $d.mac, $d.profile, $d.action, $d.model, $d.note)
            }
            Write-Output 'Modelos (OUI):'
            if (@($db.Models).Count -eq 0) { Write-Output '  (nenhum)' }
            foreach ($m in $db.Models) { Write-Output ("  {0}  {1}  perfil={2}" -f $m.oui, $m.vendor, $m.profile) }
            Write-Output 'Prefixos MAC:'
            if (@($db.Prefixes).Count -eq 0) { Write-Output '  (nenhum)' }
            foreach ($m in $db.Prefixes) { Write-Output ("  {0}  perfil={1}" -f $m.prefix, $m.profile) }
            Write-Output ''
            Write-Output ("politica atual: Mode={0} DefaultAction={1}" -f $Cfg.Policy.Mode, $Cfg.Policy.DefaultAction)
        }
        'Add' {
            if (-not $Mac) { throw 'Informe -Mac AA:BB:CC:DD:EE:FF' }
            $e = Add-DorPXEDevice -Mac $Mac -Profile $Profile -Action $DeviceAction -Model $Model -Note $Note
            Write-Output ("cadastrado: {0} -> perfil {1} acao {2}" -f $e.mac, $e.profile, $e.action)
        }
        'Remove' {
            if (-not $Mac) { throw 'Informe -Mac AA:BB:CC:DD:EE:FF' }
            $ok = Remove-DorPXEDevice -Mac $Mac
            Write-Output $(if ($ok) { "removido: $Mac" } else { "nao encontrado: $Mac" })
        }
        'Model' {
            if (-not $Oui) { throw 'Informe -Oui D4:BE:D9 (6 hex)' }
            $k = Add-DorPXEModel -Oui $Oui -Vendor $Model -Profile $Profile
            Write-Output ("modelo cadastrado: OUI {0} perfil {1}" -f $k, $Profile)
        }
        'Prefix' {
            if (-not $Prefix) { throw 'Informe -Prefix F8:32:E4' }
            $k = Add-DorPXEPrefix -Prefix $Prefix -Profile $Profile
            Write-Output ("prefixo cadastrado: {0} perfil {1}" -f $k, $Profile)
        }
        'Policy' {
            if ($Cfg.Policy.Mode -eq 'AllowList' -and $Mode -eq 'Open') {
                $Cfg.Policy.Mode = 'Open'
                $Cfg.Policy.DefaultAction = $(if ($DefaultAction) { $DefaultAction } else { 'Menu' })
            }
            elseif ($Mode -eq 'AllowList') { $Cfg.Policy.Mode = 'AllowList' }
            if ($DefaultAction) { $Cfg.Policy.DefaultAction = $DefaultAction }
            Save-DorPXEConfig -Config $Cfg -Path $script:ConfigPath | Out-Null
            Write-Output ("politica salva: Mode={0} DefaultAction={1}" -f $Cfg.Policy.Mode, $Cfg.Policy.DefaultAction)
        }
    }
}

function Invoke-DorPXETest {
    param($Cfg)
    $fail = 0
    function Check($name, $cond, $detail) {
        if ($cond) { Write-Output ("  [OK]   {0}" -f $name) }
        else { Write-Output ("  [FALHA] {0} {1}" -f $name, $detail); $script:TestFail++ }
    }
    $script:TestFail = 0

    Write-Output '1) MAC / OUI'
    Check 'ConvertTo-DorPXEMac' ((ConvertTo-DorPXEMac 'a4-b1-c2-d3-e4-f5') -eq 'A4:B1:C2:D3:E4:F5') (ConvertTo-DorPXEMac 'a4-b1-c2-d3-e4-f5')
    Check 'MAC invalida' (-not (ConvertTo-DorPXEMac 'zz:11')) ''
    Check 'Get-DorPXEOui' ((Get-DorPXEOui 'A4:B1:C2:11:22:33') -eq 'A4:B1:C2') ''

    Write-Output '2) Configuracao'
    $tmp = Join-Path (Get-DorPXEPath).State 'test-config.psd1'
    Save-DorPXEConfig -Config $Cfg -Path $tmp | Out-Null
    $back = Import-DorPXEConfig -Path $tmp
    Check 'round-trip perfis' (@($back.Profiles).Count -eq @($Cfg.Profiles).Count) "@($($back.Profiles).Count)"
    Check 'round-trip TftpPort' ($back.Server.TftpPort -eq $Cfg.Server.TftpPort) "$($back.Server.TftpPort)"
    Check 'round-trip profile name' ((@($back.Profiles)[0].Name) -eq (@($Cfg.Profiles)[0].Name)) ''
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

    Write-Output '3) Politica'
    # MAC aleatorio: o teste nao pode depender nem sobrescrever state\devices.json
    $tb = New-Object byte[] 3
    (New-Object Random).NextBytes($tb)
    $tMac = '02:0A:0B:' + (($tb | ForEach-Object { $_.ToString('X2') }) -join ':')
    $iso = Import-DorPXEConfig
    $iso.Policy['Mode'] = 'AllowList'
    $iso.Policy['DefaultAction'] = 'Local'
    $iso.Policy['Devices'] = @()
    $d1 = Resolve-DorPXEDecision -Config $iso -Mac $tMac -Ip '10.0.0.5'
    Check 'sem cadastro e allowlist => negado' ((-not $d1.Allowed) -and $d1.Action -eq 'Deny') $d1.Reason
    $iso.Policy['Devices'] = @([pscustomobject]@{ Mac = $tMac; Profile = 'win11pro'; Action = 'Boot'; Model = ''; Note = 'teste' })
    $d2 = Resolve-DorPXEDecision -Config $iso -Mac $tMac -Ip '10.0.0.5'
    Check 'MAC cadastrada => liberada' ($d2.Allowed -and $d2.Profile -eq 'win11pro') $d2.Reason
    $d3 = Resolve-DorPXEDecision -Config $iso -Mac '02:0A:0B:FF:FF:FF' -Ip '10.0.0.6'
    Check 'MAC nao cadastrada => negada' ((-not $d3.Allowed) -and $d3.Action -eq 'Deny') $d3.Reason
    $iso.Policy['Devices'] = @([pscustomobject]@{ Mac = $tMac; Profile = 'win11pro'; Action = 'Menu'; Model = ''; Note = 'teste' })
    $d4 = Resolve-DorPXEDecision -Config $iso -Mac $tMac -Ip '10.0.0.5'
    Check 'acao Menu liberada' ($d4.Allowed -and $d4.Action -eq 'Menu') "$($d4.Action)"

    Write-Output '4) DHCP codec'
    $req = New-Object byte[] 300
    $req[0] = 1; $req[1] = 1; $req[2] = 6
    $req[4] = 1; $req[5] = 2; $req[6] = 3; $req[7] = 4
    $macHex = 'AABBCCDDEEFF'
    for ($i = 0; $i -lt 6; $i++) { $req[28 + $i] = [Convert]::ToByte($macHex.Substring($i * 2, 2), 16) }
    $req[236] = 99; $req[237] = 130; $req[238] = 83; $req[239] = 99
    $pk = 240
    $req[$pk++] = 53; $req[$pk++] = 1; $req[$pk++] = 1
    $req[$pk++] = 93; $req[$pk++] = 2; $req[$pk++] = 0; $req[$pk++] = 0
    $req[$pk++] = 60; $req[$pk++] = 9
    foreach ($ch in ([Text.Encoding]::ASCII.GetBytes('PXEClient'))) { $req[$pk++] = $ch }
    $req[$pk++] = 255
    $p = ConvertFrom-DorPXEDhcpPacket -Bytes ([byte[]]$req[0..($pk - 1)])
    Check 'parse DISCOVER' ($p -and $p.Mac -eq 'AA:BB:CC:DD:EE:FF') "$($p.Mac)"
    Check 'parse msgtype' ((Get-DorPXEDhcpOptionU16 -Options $p.Options -Code 53) -eq 1) ''
    Check 'parse arch' ((Get-DorPXEDhcpOptionU16 -Options $p.Options -Code 93) -eq 0) ''
    Check 'parse vendor' ((Get-DorPXEDhcpOptionText -Options $p.Options -Code 60) -eq 'PXEClient') ''
    Check 'detecta PXE' (Test-DorPXEPxeClient -Packet $p) ''
    Check 'nao iPXE' ((-not (Test-DorPXEIpxeClient -Packet $p))) ''
    $reply = New-DorPXEDhcpReply -Request $p -MessageType 2 -ServerId '10.0.0.10' -NextServer '10.0.0.10' -BootFile 'x86_64-efi/ipxe.efi'
    $rp2 = ConvertFrom-DorPXEDhcpPacket -Bytes $reply -AllowReply
    Check 'reply OFFER' ($rp2 -and (Get-DorPXEDhcpOptionU16 -Options $rp2.Options -Code 53) -eq 2) ''
    Check 'reply file 67' ((Get-DorPXEDhcpOptionText -Options $rp2.Options -Code 67) -eq 'x86_64-efi/ipxe.efi') (Get-DorPXEDhcpOptionText -Options $rp2.Options -Code 67)
    Check 'reply next 66' ((Get-DorPXEDhcpOptionText -Options $rp2.Options -Code 66) -eq '10.0.0.10') ''
    Check 'reply sem yiaddr' ($rp2.Yiaddr -eq '0.0.0.0') $rp2.Yiaddr
    Check 'reply sem opcao 1' (-not (Get-DorPXEDhcpOptionBytes -Options $rp2.Options -Code 1)) ''
    Check 'reply sem opcao 3' (-not (Get-DorPXEDhcpOptionBytes -Options $rp2.Options -Code 3)) ''
    Check 'reply sem opcao 6' (-not (Get-DorPXEDhcpOptionBytes -Options $rp2.Options -Code 6)) ''
    Check 'reply sem opcao 51' (-not (Get-DorPXEDhcpOptionBytes -Options $rp2.Options -Code 51)) ''
    Check 'echo arch 93' ((Get-DorPXEDhcpOptionU16 -Options $rp2.Options -Code 93) -eq 0) ''
    $plan = Get-DorPXEDhcpBootPlan -Config $Cfg -Packet $p
    Check 'plano BIOS (op93=0)' ($plan.BootFile -eq 'ipxe\x86_64-pcbios\undionly.kpxe') "$($plan.BootFile)"
    Check 'plano UEFI (op93=7)' ((Get-DorPXEArchBootFile -Architecture 7) -eq 'ipxe\x86_64-efi\ipxe.efi') ''
    Check 'plano UEFI (op93=9)' ((Get-DorPXEArchBootFile -Architecture 9) -eq 'ipxe\x86_64-efi\ipxe.efi') ''
    Check 'plano UEFI32 (op93=6)' ((Get-DorPXEArchBootFile -Architecture 6) -eq 'ipxe\i386-efi\ipxe.efi') ''
    $pk77 = ConvertFrom-DorPXEDhcpPacket -Bytes ([byte[]]$req[0..($pk - 1)])
    $pk77.Options[77] = [byte[]]@(105, 80, 88, 69)
    $plan2 = Get-DorPXEDhcpBootPlan -Config $Cfg -Packet $pk77
    Check '2o estagio iPXE => autoexec.ipxe' ($plan2.IsIpxe -and $plan2.BootFile -eq 'autoexec.ipxe') "$($plan2.BootFile)"

    Write-Output '5) TFTP codec'
    $b = New-Object System.Collections.Generic.List[byte]
    $b.Add(0); $b.Add(1)
    foreach ($c in ([Text.Encoding]::ASCII.GetBytes('autoexec.ipxe'))) { $b.Add($c) }
    $b.Add(0)
    foreach ($c in ([Text.Encoding]::ASCII.GetBytes('octet'))) { $b.Add($c) }
    $b.Add(0)
    foreach ($c in ([Text.Encoding]::ASCII.GetBytes('blksize'))) { $b.Add($c) }
    $b.Add(0)
    foreach ($c in ([Text.Encoding]::ASCII.GetBytes('1400'))) { $b.Add($c) }
    $b.Add(0)
    $b.Add(0)
    $t = ConvertFrom-DorPXETftpRequest -Bytes $b.ToArray()
    Check 'RRQ file' ($t.File -eq 'autoexec.ipxe') $t.File
    Check 'RRQ mode' ($t.Mode -eq 'octet') $t.Mode
    Check 'RRQ opcao' ($t.Options['blksize'] -eq '1400') "$($t.Options['blksize'])"
    $neg = Get-DorPXETftpNegotiated -Request $t -FileSize 76064
    Check 'negocia blksize' ($neg['blksize'] -eq 1400) "$($neg['blksize'])"
    Check 'tsize sem pedido => ausente' (-not $neg.ContainsKey('tsize')) ''
    $tTsize = ConvertFrom-DorPXETftpRequest -Bytes ([byte[]]@(0, 1) + [Text.Encoding]::ASCII.GetBytes('x.bin') + [byte[]]@(0) + [Text.Encoding]::ASCII.GetBytes('octet') + [byte[]]@(0) + [Text.Encoding]::ASCII.GetBytes('tsize') + [byte[]]@(0) + [byte[]]@(0))
    $negT = Get-DorPXETftpNegotiated -Request $tTsize -FileSize 4096
    Check 'negocia tsize real' ($negT['tsize'] -eq '4096') "$($negT['tsize'])"
    $oack = New-DorPXETftpOack -Options $neg
    Check 'OACK opcode' ($oack[0] -eq 0 -and $oack[1] -eq 6) ''
    $d1b = New-DorPXETftpData -Block 1 -Data ([byte[]]@(1, 2, 3, 4))
    Check 'DATA opcode' ($d1b[0] -eq 0 -and $d1b[1] -eq 3 -and $d1b[2] -eq 0 -and $d1b[3] -eq 1 -and $d1b.Length -eq 8) ''
    $ackb = New-DorPXETftpAck -Block 1
    Check 'ACK opcode' ($ackb[0] -eq 0 -and $ackb[1] -eq 4 -and $ackb[2] -eq 0 -and $ackb[3] -eq 1) ''
    $errb = New-DorPXETftpError -Code 1 -Message 'nao encontrado'
    Check 'ERROR opcode' ($errb[0] -eq 0 -and $errb[1] -eq 5 -and $errb[2] -eq 0 -and $errb[3] -eq 1) ''
    $t2 = ConvertFrom-DorPXETftpRequest -Bytes ([byte[]]@(0, 4, 0, 1))
    Check 'RRQ invalido rejeitado' ($null -eq $t2) ''

    Write-Output '5b) Progresso por IP (TFTP)'
    $st = New-DorPXEState
    Check 'estado nasce com TftpByIp' ($null -ne $st.TftpByIp -and $st.TftpByIp.Count -eq 0) 'TftpByIp nao inicializou'
    Add-DorPXETftpClientBytes -State $st -Ip '10.0.0.5' -Bytes 1024 -File 'a'
    Add-DorPXETftpClientBytes -State $st -Ip '10.0.0.5' -Bytes 2048 -File 'b'
    Add-DorPXETftpClientBytes -State $st -Ip '10.0.0.6' -Bytes 512 -File 'a'
    Check 'bytes somam por IP' ($st.TftpByIp['10.0.0.5'].Bytes -eq 3072) "$($st.TftpByIp['10.0.0.5'].Bytes)"
    Check 'contagem separada por IP' ($st.TftpByIp['10.0.0.6'].Bytes -eq 512) "$($st.TftpByIp['10.0.0.6'].Bytes)"
    Check 'arquivos contados por IP' ($st.TftpByIp['10.0.0.5'].Files -eq 2) "$($st.TftpByIp['10.0.0.5'].Files)"
    Check 'IP desconhecido e ignorado' ($null -eq (Add-DorPXETftpClientBytes -State $st -Ip '' -Bytes 10)) ''

    # o payload de boot e a soma dos arquivos que o cliente baixa por TFTP
    $pay = Get-DorPXEBootPayloadBytes -Config $Cfg
    Check 'payload de boot e um inteiro' ($pay.Bytes -ge 0 -and $pay.Bytes -eq [long]$pay.Bytes) "$($pay.Bytes)"
    Check 'payload nunca inclui o install.wim' ((@($pay.Items | Where-Object { $_ -match 'install\.wim' })).Count -eq 0) 'install.wim entrou no payload'

    Write-Output '6) Scripts iPXE'
    $ae = Get-DorPXEAutoExecScript -Config $Cfg
    Check 'autoexec ipxe' ($ae.StartsWith('#!ipxe') -and $ae -match '/pxe/boot\.ipxe\?mac=') ''
    Check 'autoexec ASCII' (-not ($ae -match '[^\x00-\x7F]')) ''
    $prof = Get-DorPXEProfile -Config $Cfg -Name 'win11pro'
    $bs = Get-DorPXEBootScript -Config $Cfg -Profile $prof -Decision $d1
    Check 'boot ipxe (sem midia)' (($bs.StartsWith('#!ipxe')) -and ($bs -match 'ainda nao publicado')) ''
    $made = @()
    $sharedUefi = Join-Path (Get-DorPXEPath).WinPe 'shared\uefi'
    $profUefi = Join-Path (Get-DorPXEPath).WinPe 'profiles\win11pro\uefi'
    foreach ($f in @((Join-Path $sharedUefi 'BCD'), (Join-Path $sharedUefi 'boot.sdi'), (Join-Path $sharedUefi 'Fonts\segmono_boot.ttf'), (Join-Path $profUefi 'boot.wim'), (Join-Path $profUefi 'boot.i386.wim'))) {
        if (-not (Test-Path -LiteralPath $f)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $f) -Force | Out-Null
            [IO.File]::WriteAllBytes($f, [byte[]]@(0x41, 0x42))
            $made += $f
        }
    }
    $bs2 = Get-DorPXEBootScript -Config $Cfg -Profile $prof -Decision $d1
    Check 'boot ipxe (com midia)' (($bs2.StartsWith('#!ipxe')) -and ($bs2 -match 'wimboot')) ''
    Check 'boot ASCII' (-not ($bs2 -match '[^\x00-\x7F]')) ''
    Check 'boot tem ${mode}' ($bs2 -match '\$\{mode\}') ''
    Check 'boot tem BCD/boot.wim' (($bs2 -match 'initrd --name BCD') -and ($bs2 -match 'initrd --name boot.wim')) ''
    Check 'boot.wim canonico como padrao' ($bs2 -match 'set wim \S*\$\{mode\}/boot\.wim') 'sem set wim padrao'
    # cada arquitetura extra gera UMA linha, mesmo com uefi e bios prontos:
    # o ${mode} e do iPXE, nao do servidor, entao iterar por modo duplicava.
    $linhasI386 = @([regex]::Matches($bs2, '(?m)^isset \$\{arch\} && match \$\{arch\} i386\* && set wim .*$'))
    Check 'extras sem duplicar (i386)' ($linhasI386.Count -eq 1) "linhas i386=$($linhasI386.Count) (esperado 1)"
    $qualquerExtra = @([regex]::Matches($bs2, '(?m)^isset \$\{arch\} && match \$\{arch\} .*&& set wim .*$'))
    Check 'nenhuma linha de boot repetida' ((@($bs2 -split "`n" | Where-Object { $_ -match '\S' } | Group-Object | Where-Object { $_.Count -gt 1 })).Count -eq 0) 'ha linhas duplicadas no boot.ipxe'
    # PXE_DUMP_BOOT=1 imprime o boot.ipxe gerado: e o arquivo exato que o cliente
    # recebe, util para conferir o que a maquina vai ver no boot.
    if ($env:PXE_DUMP_BOOT -eq '1') {
        Write-Output '--- boot.ipxe gerado (PXE_DUMP_BOOT=1) ---'
        Write-Output $bs2
        Write-Output '--- fim ---'
    }
    Check 'initrd usa o boot.wim escolhido' ($bs2 -match 'initrd --name boot\.wim \$\{wim\} boot\.wim') 'initrd sem \${wim}'
    Check 'boot escolhe por arquitetura' ($bs2 -match 'match \$\{arch\} i386') 'sem selecao de arquitetura'
    Check 'boot sem acento' (-not ($bs2 -match '[\u00C0-\u00FF]')) ''
    foreach ($f in $made) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    $mn = Get-DorPXEMenuScript -Config $Cfg -Decision $d1
    Check 'menu ipxe' ($mn -match 'choose' -and $mn -match 'item chain') ''
    Check 'menu tem item local' ($mn -match 'item local exit' -and $mn -match 'choose --default local') ''
    $den = Get-DorPXEDenyScript -Config $Cfg -Decision $d1
    Check 'deny ipxe' ($den -match 'acesso negado' -or $den -match 'ACESSO NEGADO') ''
    $mnTimeout = Get-DorPXEMenuScript -Config $Cfg -Decision $d1
    Check 'menu com timeout limitado' ($mnTimeout -match '--timeout (?:[5-9]|[1-9][0-9]|[1-5][0-9][0-9]|600)\b') ''

    Write-Output '7) Caminhos / estaticos'
    $root = Join-Path (Get-DorPXEPath).Www ''
    Check 'safe path ok' ((Resolve-DorPXESafePath -Root $root -Path 'ipxe/version.txt') -eq (Join-Path $root 'ipxe\version.txt')) ''
    Check 'safe path bloqueia ../' (-not (Resolve-DorPXESafePath -Root $root -Path '../../Windows/System32/drivers/etc/hosts')) ''
    $ipx = Join-Path $root 'ipxe'
    foreach ($f in @('x86_64-pcbios\undionly.kpxe', 'x86_64-efi\ipxe.efi', 'wimboot\x86_64\wimboot')) {
        Check "binario $f" (Test-Path -LiteralPath (Join-Path $ipx $f)) 'ausente'
    }

    Write-Output ''
    Write-Output '8) Console / admin'
    $html = Get-DorPXEAdminHtml -Config $cfg
    Check 'html do console nao vazio' ($html.Length -gt 20000) "tamanho=$($html.Length)"
    foreach ($m in @('stepbtn', 'showStep', 'prefers-color-scheme', 'midir', 'miso', 'mslug',
            'id="pmode"', 'id="pdef"', 'policyHint', 'saveMedia', 'buildMedia',
            'addDev', 'rmDev', 'loglink', 'Ativos', 'Politica de boot', 'id="envlist"')) {
        Check "marcador $m" ($html.Contains($m)) 'ausente no HTML'
    }
    Check 'tres abas apenas' (@([regex]::Matches($html, 'class="stepbtn"')).Count -eq 2) 'numero de abas diferente de 2'
    Check 'aba Atividade removida' (-not $html.Contains('showStep(5)') -and -not $html.Contains('data-step="5"')) 'aba 5 ainda presente'
    Check 'aba 3 eliminada' (-not $html.Contains('data-step="3"') -and -not $html.Contains('showStep(3)') -and -not $html.Contains('data-go="3"')) 'aba 3 ainda presente'
    Check 'politica na barra de status' ($html -match '(?s)<div class="pbar">.*?id="pmode".*?id="pdef".*?</header>') 'seletores de politica fora da barra superior'
    # Fluxo: 1 Politica de boot (barra superior), 2 Midia (ISO), 3 Ativos.
    # No DOM o data-step=1 e Midia e o data-step=2 e Ativos; o numero exibido
    # no botao e o do fluxo, nao o do data-step.
    $step1 = [regex]::Match($html, '(?s)<section class="step" data-step="1">(.*?)</section>').Value
    $stepAt = [regex]::Match($html, '(?s)<section class="step" data-step="2"[^>]*>(.*?)</section>').Value
    Check 'so a primeira aba vem aberta' ($html.Contains('<section class="step" data-step="1">') -and $html.Contains('<section class="step" data-step="2" hidden>')) 'as duas abas abrem juntas ou nenhuma'
    Check 'ordem do fluxo: Midia antes de Ativos' ($html.IndexOf('<h2>2. Midia (ISO)</h2>') -ge 0 -and $html.IndexOf('<h2>2. Midia (ISO)</h2>') -lt $html.IndexOf('<h2>3. Ativos</h2>')) 'Midia nao vem antes de Ativos'
    Check 'nav: Midia e o numero 2' ($html -match '<span class="n">2</span><span><b>Midia \(ISO\)</b>') 'nav nao numera Midia como 2'
    Check 'nav: Ativos e o numero 3' ($html -match '<span class="n">3</span><span><b>Ativos</b>') 'nav nao numera Ativos como 3'
    Check 'politica de boot e o passo 1 do fluxo' ($html -match '<label><b class="flownum">1</b>\s*Politica de boot</label>') 'linha da politica sem o numero 1'
    Check 'stepDone de Midia verifica boot.wim' ($html -match "(?s)function stepDone.*?if\(n===1\).*?BootWim") 'stepDone de Midia fora de ordem'
    Check 'navegacao invertida' ($html.Contains('showStep(2)">Proximo: Ativos') -and $html.Contains('showStep(1)">Voltar: Midia (ISO)')) 'botoes de navegacao nao acompanharam a inversao'
    Check 'passo de Ativos com as tabelas de evento' ($stepAt.Contains('id="boots"') -and $stepAt.Contains('id="dhcp"') -and $stepAt.Contains('id="tftp"')) 'tabelas de evento fora do passo de Ativos'
    Check 'passo de Ativos chamado Ativos' ($html.Contains('<h2>3. Ativos</h2>') -and $html.Contains('<b>Ativos</b>')) 'aba de Ativos fora de ordem'
    Check 'passo de Ativos com descricao Dispositivos e atividade' ($html.Contains('<small>Dispositivos e atividade</small>') -and $html.Contains('<span class="sub">Dispositivos e atividade</span>')) 'descricao do passo de Ativos divergente'
    Check 'containers removidos do passo de Ativos' (-not $html.Contains('Servico e ativos') -and -not $html.Contains('<h2>Componentes</h2>') -and -not $html.Contains('<h2>Contadores</h2>') -and -not $html.Contains('id="tiles"') -and -not $html.Contains('id="stats"') -and -not $html.Contains('id="uptime"') -and -not $html.Contains('id="updlbl"')) 'container antigo ainda presente'
    Check 'ativos dentro do passo de Ativos' ($stepAt.Contains('id="hosts"') -and $stepAt.Contains('id="dmac"') -and $stepAt.Contains('id="devsWrap"')) 'cards de dispositivos fora do passo de Ativos'
    Check 'atividade antes dos dispositivos' ($stepAt.IndexOf('id="boots"') -lt $stepAt.IndexOf('id="hosts"') -and $stepAt.IndexOf('id="boots"') -ge 0) 'Dispositivos aparece antes da atividade'
    # Progresso por ativo: mede a fase TFTP do WinPE, nunca o install.wim.
    Check 'container de transferencia em andamento' ($html.Contains('id="xfer"') -and $html.Contains('por ativo conectado')) 'card de transferencia ausente'
    Check 'progresso usa a tabela por IP' ($html.Contains('d.bootPayloadBytes') -and $html.Contains('d.ativos') -and $html.Contains('x.Pct')) 'barra de progresso nao le o payload por ativo'
    Check 'aviso de que o install.wim vem pelo share' ($html.Contains('install.wim vem pelo share SMB') -and $html.Contains('nao e medido aqui')) 'sem aviso sobre o install.wim'
    Check 'tabela TftpByIp no estado compartilhado' (Select-String -Path (Join-Path (Split-Path -Parent $root) 'lib\Common.ps1') -Pattern "\['TftpByIp'\]" -Quiet) 'tabela TftpByIp ausente do estado'
    Check 'TFTP acumula bytes por IP durante o envio' ((Select-String -Path (Join-Path (Split-Path -Parent $root) 'lib\Tftp.ps1') -Pattern 'Add-DorPXETftpClientBytes' -AllMatches).Matches.Count -ge 2) 'acumulo por IP ausente no loop de blocos'
    # Barra de status em duas linhas: contadores em cima, imagem e servico embaixo.
    $sb = [regex]::Match($html, '(?s)<div class="pbar">(.*?)</div>\s*<div class="pbar polbar">').Value
    Check 'barra de status com duas linhas' ($sb.Contains('id="chips"') -and $sb.Contains('id="chips2"') -and -not $sb.Contains('class="chips"')) 'linhas da barra de status NAO separadas'
    Check 'linhas separadas por borda' ($html.Contains('.sbrow+.sbrow{border-top:1px solid var(--line)')) 'sem separador entre as linhas'
    # Linha 1: Imagem, Servico e Uptime, no mesmo formato. Linha 2: os contadores
    # de conexao de rede. Ambos montados por JS dentro de head().
    $top = [regex]::Match($html, '(?s)var top=\[(.*?)\];').Value
    Check 'linha 1: array de imagem/servico/uptime' ($top.Length -gt 0) 'array top nao encontrado'
    foreach ($c in @("'Imagem',", "'Servico',", "'Uptime',")) {
        Check "linha 1 com $($c.Trim(','))" ($top.Contains($c)) "item $c fora da linha 1"
    }
    Check 'linha 1 sem contadores' (-not ($top -match "'DHCP',|'Ofertas',|'TFTP',|'HTTP',|'Boots',|'Negados',|'Hosts ativos',")) 'contadores na linha 1'
    Check 'servico com ponto de status' ($html.Contains("id=""dot""") -and $html.Contains("id=""statustext""") -and $top.Contains("'srv'")) 'pill de servico nao virou chip'
    Check 'linha 1 renderiza em chips' ($html.Contains("document.getElementById('chips').innerHTML=top.map")) 'linha 1 nao renderiza'
    $linha2 = [regex]::Match($html, '(?s)var chips=\[(.*?)\];').Value
    Check 'linha 2: array de contadores' ($linha2.Length -gt 0) 'array chips nao encontrado'
    foreach ($c in @('DHCP', 'Ofertas', 'TFTP', 'HTTP', 'Boots', 'Negados', 'Hosts ativos')) {
        Check "linha 2 com $c" ($linha2.Contains("'$c',")) "contador $c fora da linha 2"
    }
    Check 'linha 2 sem Imagem e sem Uptime' (-not $linha2.Contains("'Imagem',") -and -not $linha2.Contains("'Uptime',")) 'imagem/uptime ainda na linha 2'
    Check 'linha 2 renderiza em chips2' ($html.Contains("document.getElementById('chips2').innerHTML=chips.map")) 'linha 2 nao renderiza'
    # a barra precisa ter fallback estatico: head() so roda depois do 1o load
    Check 'barra com fallback antes do 1o load' ($html.Contains('<div class="sbrow" id="chips"><span class="chip">')) 'sem fallback estatico na linha 1'
    Check 'erro do load nao quebra sem dot' ($html.Contains("if(d){d.className='dot off'}") -and $html.Contains('sem resposta do servico')) 'caminho de erro sem guarda'
    Check 'usuario abaixo dos botoes' ($html -match '(?s)<div class="toolrow">.*?</div>\s*<span class="who" id="who"') 'usuario nao esta abaixo de Atualizar/Reiniciar'
    Check 'botao Parar removido' (-not $html.Contains("ctl('stop')")) 'ainda chama ctl(stop)'
    Check 'reiniciar disponivel' ($html.Contains("ctl('restart')")) 'sem botao reiniciar'
    # politica em lista suspensa (os toggles deslizantes que voltavam ao valor anterior)
    $selMode = [regex]::Match($html, '(?s)<select id="pmode".*?</select>').Value
    $selDef = [regex]::Match($html, '(?s)<select id="pdef".*?</select>').Value
    Check 'politica em dropdown (pmode)' ($selMode -match 'value="AllowList"' -and $selMode -match 'value="Open"') 'opcoes de modo fora de um select'
    Check 'politica em dropdown (pdef)' ($selDef -match 'value="Local"' -and $selDef -match 'value="Deny"') 'opcoes de acao fora de um select'
    Check 'sem radio de politica' (-not $html.Contains('type="radio"')) 'ainda ha radios de politica'
    Check 'sem estilo de toggle' (-not $html.Contains('.tg')) 'CSS de toggle deslizante ainda presente'
    Check 'dropdown marca alteracao pendente' ($html.Contains("markDirty('pmode')") -and $html.Contains("delete DIRTY.pmode")) 'auto-refresh sobrescreve a escolha do usuario'
    Check 'politica sem menu' (-not $html.Contains('value="Menu"')) 'opcao Menu ainda exposta'
    Check 'diagnostico de ambiente' ($html.Contains('Diagnostico do ambiente') -and $html.Contains('function envlist')) 'sem relatorio de ambiente'
    Check 'barra de status com midState' ($html.Contains('midState') -and $html.Contains("id='chips2'") -or $html.Contains('midState') -and $html.Contains('id="chips2"')) 'sem status da imagem na barra'
    Check 'usuario autenticado no cabecalho' ($html.Contains('id="who"') -and $html.Contains('function sair')) 'sem botao Sair/usuario'
    Check 'atualizacao a 3s' ($html.Contains('},3000);')) 'intervalo de atualizacao alterado'
    Check 'sem painel de log no console' (-not $html.Contains('id="logBox"') -and -not $html.Contains('loadLog(')) 'painel de log antigo ainda presente'
    Check 'html sem interpolacao PowerShell quebrada' (-not ($html -match '\$\{|\$\(')) 'template literal JS vazando para o here-string'
    Check 'css responsivo' ($html.Contains('max-width:1000px') -and $html.Contains('grid-template-columns')) 'sem breakpoints'
    Check 'reducao de movimento respeitada' ($html.Contains('prefers-reduced-motion')) 'sem regra de prefers-reduced-motion'
    # --- autenticacao por usuario local do Windows (modelo ByFace) ---
    $login = Get-DorPXEAdminLoginHtml -Reason 'teste'
    Check 'login pede usuario e senha' ($login.Contains('type="password"') -and $login.Contains('/pxe/api/login') -and $login.Contains('id="u"')) 'sem formulario de usuario/senha'
    Check 'login tem lembrar acesso' ($login.Contains('Lembrar meu acesso') -and $login.Contains('remember')) 'sem opcao lembrar acesso'
    Check 'login nao pede token' (-not $login.Contains('admin-token.txt')) 'login ainda pede o token em arquivo'
    $sess = New-DorPXESessionToken -Config $cfg -User 'tester'
    Check 'sessao com 3 partes' (@($sess.Split('|')).Count -eq 3) "token invalido: $sess"
    $rq = [pscustomobject]@{ Headers = @{ cookie = "x=1; dorpxe_session=$sess" } }
    Check 'cookie de sessao valido' ((Get-DorPXESessionUser -Config $cfg -Request $rq) -eq 'tester') 'sessao nao reconhecida'
    $rqF = [pscustomobject]@{ Headers = @{ cookie = 'dorpxe_session=tester|99999999999|fake' } }
    Check 'assinatura adulterada negada' (-not (Get-DorPXESessionUser -Config $cfg -Request $rqF)) 'aceitou token forjado'
    $rqV = [pscustomobject]@{ Headers = @{ cookie = 'dorpxe_session=tester|1|fake' } }
    Check 'sessao expirada negada' (-not (Get-DorPXESessionUser -Config $cfg -Request $rqV)) 'aceitou sessao expirada'
    Check 'senha errada nao autentica' (-not (Invoke-DorPXEAuthenticate -Config $cfg -User $env:USERNAME -Password 'senha-inexistente-xyz').Ok) 'aceitou senha errada'
    $ctxReal = New-DorPXEPrincipalContext -Type Machine
    Check 'assembly de autenticacao carregado' (Initialize-DorPXEAuth) 'sem System.DirectoryServices.AccountManagement todo login volta 401'
    Check 'contexto de contas do Windows criado' ($null -ne $ctxReal) 'PrincipalContext local indisponivel - nenhum login funciona'
    Check 'usuario local autorizado' (Test-DorPXEUserAuthorized -Config $cfg -User $env:USERNAME -Context $ctxReal) 'usuario local logado nao autorizado - ajuste Server.AuthGroups/AuthUsers'
    Check 'grupo de autenticacao padrao' (@(Get-DorPXEAuthGroups -Config $cfg) -contains 'Administrators') 'grupos padrao ausentes'
    # o Windows em portugues chama o grupo de "Administradores": a comparacao
    # por SID e o que faz "Administrators" (do config) valer em qualquer idioma.
    Check 'grupo Administrators em ingles vira SID' ((ConvertTo-DorPXEGroupSid -Name 'Administrators') -eq 'S-1-5-32-544') (ConvertTo-DorPXEGroupSid -Name 'Administrators')
    Check 'grupo Administrators em portugues vira SID' ((ConvertTo-DorPXEGroupSid -Name 'Administradores') -eq 'S-1-5-32-544') (ConvertTo-DorPXEGroupSid -Name 'Administradores')
    Check 'grupo inexistente nao vira SID' (-not (ConvertTo-DorPXEGroupSid -Name 'GrupoQueNaoExisteZzz')) 'grupo inexistente resolveu'
    $ctxLocal = New-DorPXEPrincipalContext -Type Machine
    Check 'SID do grupo Administradores reconhecido' (Test-DorPXEGroupMember -Context $ctxLocal -User $env:USERNAME -Group 'Administrators') 'usuario logado nao bate no SID S-1-5-32-544'
    Check 'grupo restrito nega o usuario' (-not (Test-DorPXEUserAuthorized -Config @{ Server = @{ AuthGroups = @('GrupoQueNaoExisteZzz'); AuthUsers = @() } } -User $env:USERNAME -Context $ctxLocal)) 'deveria negar'
    Check 'AuthUsers autoriza pelo nome' (Test-DorPXEUserAuthorized -Config @{ Server = @{ AuthGroups = @('GrupoQueNaoExisteZzz'); AuthUsers = @($env:USERNAME) } } -User $env:USERNAME -Context $ctxLocal) 'deveria autorizar pela lista'
    Check 'config de auth e lido do arquivo' ((Get-DorPXEAuthOption -Config $cfg -Name 'RememberDays' -Default 0) -ne 0) 'AuthGroups/AuthUsers/RememberDays do config estao sendo ignorados'
    Check 'config de auth em hashtable' ((Get-DorPXEAuthOption -Config @{ Server = @{ RememberDays = 7 } } -Name 'RememberDays' -Default 0) -eq 7) 'leitura de hashtable falhou'
    Check 'url do console sem token' (-not (Get-DorPXEAdminUrl -Config $cfg).Contains('?t=')) 'URL ainda embuta token'
    Check 'url de automacao com token' ((Get-DorPXEAdminUrl -Config $cfg -WithToken).Contains('?t=')) 'URL de automacao sem token'
    $ctxL = [pscustomobject]@{
        Request = [pscustomobject]@{
            RemoteEndPoint = [Net.IPEndPoint]::new([Net.IPAddress]::Parse('127.0.0.1'), 5000)
            Headers        = @{}; Url = [uri]'http://127.0.0.1:8080/pxe/admin'
        }
    }
    $aL = Test-DorPXEAdminRequest -Config $cfg -Context $ctxL
    Check 'sem sessao e sem token nega' (-not $aL.Ok) 'console aberto sem login'
    $ctxS = [pscustomobject]@{
        Request = [pscustomobject]@{
            RemoteEndPoint = [Net.IPEndPoint]::new([Net.IPAddress]::Parse('127.0.0.1'), 5000)
            Headers        = @{ cookie = "dorpxe_session=$sess" }
            Url            = [uri]'http://127.0.0.1:8080/pxe/admin'
        }
    }
    $aS = Test-DorPXEAdminRequest -Config $cfg -Context $ctxS
    Check 'sessao libera o console' ($aS.Ok -and $aS.User -eq 'tester') 'sessao nao liberou o console'
    # rota do log exige o mesmo login do console
    $http = [IO.File]::ReadAllText((Join-Path (Get-DorPXEPath).Lib 'Http.ps1'))
    $i = $http.IndexOf("'^servidorpxe\.log`$'")
    Check 'rota servidorpxe.log existe' ($i -gt 0) 'rota nao encontrada'
    if ($i -gt 0) {
        $bloco = $http.Substring($i, [Math]::Min(700, $http.Length - $i))
        Check 'rota do log protegida' ($bloco.Contains('Test-DorPXEAdminRequest')) 'log servido sem login'
    }
    Check 'rotas de login/sessao' ($http.Contains("'^api/login`$'") -and $http.Contains("'^api/session`$'") -and $http.Contains("'^api/logout`$'")) 'rotas de autenticacao ausentes'
    # ambiente novo: preflight e pastas do projeto
    $rep = @(Get-DorPXEEnvironmentReport -Config $cfg -Job ([pscustomobject]@{ Components = @{ http = $true; dhcp = $true; tftp = $true } }))
    Check 'preflight lista o ambiente' ($rep.Count -ge 8) "itens=$($rep.Count)"
    foreach ($n in @('Binarios iPXE', 'Pasta de midia', 'Imagem WinPE', 'ISO do Windows 11', 'DHCP', 'Escopo da rede', 'Firewall', 'Execucao de scripts', 'Privilegio', 'Politica x cadastro')) {
        Check "preflight: $n" (@($rep | Where-Object { $_.Name -eq $n }).Count -eq 1) 'item ausente'
    }
    Check 'preflight sem ipxe _e_ falha' ((@($rep | Where-Object { $_.Name -eq 'Binarios iPXE' -and $_.Level -eq 'ok' }).Count) -eq 1) 'iPXE nao encontrado em www\ipxe'
    Check 'preflight antes da midia nao quebra' ((@($rep | Where-Object { $_.Name -eq 'Imagem WinPE' }).Count) -eq 1) 'preflight quebrou sem ISO'
    # midia: defaults e resolucao de boot.wim
    Check 'Media.IsoDir no default' ((New-DorPXEConfig).Media.IsoDir -eq '') 'default sem IsoDir'
    $mw = Get-DorPXEMediaBootWimDir -Config $cfg
    Check 'fonte do WinPE coerente' ($mw -eq $null -or (Test-Path -LiteralPath $mw)) "caminho inexistente: $mw"
    $bs = Get-DorPXEBootScript -Config $cfg -Profile (Get-DorPXEProfile -Config $cfg -Name ($cfg.Profiles | Select-Object -First 1).Name)
    $st3 = Get-DorPXEModeState -Config $cfg -ProfileName ($cfg.Profiles | Select-Object -First 1).Name
    Check 'modestate expoe arquiteturas extras' (@($st3.Values)[0].PSObject.Properties.Name -contains 'Extras') 'campo Extras ausente'
    Check 'media.set registrada' ((Get-Content (Join-Path (Get-DorPXEPath).Lib 'Admin.ps1') -Raw).Contains("'media.set'")) 'acao ausente'
    Check 'media.build registrada' ((Get-Content (Join-Path (Get-DorPXEPath).Lib 'Admin.ps1') -Raw).Contains("'media.build'")) 'acao ausente'
    Check 'Stop de outra instancia' ((Get-Content (Join-Path $script:Root 'ServidorPXE.ps1') -Raw).Contains('function Stop-DorPXERunningInstance')) 'helper ausente'
    # iniciar.bat: Execution Policy liberada antes de rodar qualquer coisa
    $bat = [IO.File]::ReadAllText((Join-Path $script:Root 'iniciar.bat'))
    Check 'bat aplica Execution Policy' ($bat.Contains('Set-ExecutionPolicy -Scope CurrentUser') -and $bat.Contains('Set-ExecutionPolicy -Scope LocalMachine')) 'bat nao ajusta Execution Policy'
    Check 'bat remove Mark of the Web' ($bat.Contains('Unblock-File')) 'bat nao roda Unblock-File'
    Check 'bat cria pastas do projeto' ($bat.Contains('www\_dorpxe\media') -and $bat.Contains('state\mount')) 'bat nao cria as pastas'
    Check 'bat segue auto-elevado' ($bat.Contains('Verb RunAs') -and $bat.Contains('DORPXE_SKIP_ELEVATE')) 'bat sem autoelevacao'

    Write-Output ''
    Write-Output '9) Projeto, licenca e Git'
    $lic = Join-Path $script:Root 'LICENSE'
    Check 'LICENSE presente' (Test-Path -LiteralPath $lic) 'arquivo LICENSE ausente'
    if (Test-Path -LiteralPath $lic) {
        $lt = [IO.File]::ReadAllText($lic)
        Check 'LICENSE e a GPL-3.0' ($lt.Contains('GNU GENERAL PUBLIC LICENSE') -and $lt.Contains('Version 3, 29 June 2007')) 'LICENSE nao e a GPL-3.0'
        Check 'LICENSE sem corrupcao' ($lt.Length -gt 30000 -and $lt.Contains('GNU GENERAL PUBLIC LICENSE')) 'LICENSE truncada'
    }
    $rd = [IO.File]::ReadAllText((Join-Path $script:Root 'README.md'))
    Check 'README cita a GPL' ($rd.Contains('GPL-3.0') -and $rd.Contains('iPXE') -and $rd.Contains('wimboot')) 'README nao explica a licenca'
    Check 'README avisa que nao foi testado em hardware' ($rd.Contains('hardware real') -and $rd.Contains('ADK')) 'faltando aviso de status'
    Check 'nome do projeto no README' ($rd.StartsWith('# ServidorPXE')) 'README nao abre com # ServidorPXE'
    foreach ($f in @('.gitignore', '.gitattributes', '.editorconfig')) {
        Check "$f presente" (Test-Path -LiteralPath (Join-Path $script:Root $f)) 'ausente'
    }
    foreach ($f in @('DorPXE.ps1', 'Install-DorPXE.ps1', 'config\DorPXE.config.psd1')) {
        Check "nome antigo $f removido" (-not (Test-Path -LiteralPath (Join-Path $script:Root $f))) 'ainda existe'
    }
    foreach ($f in @('ServidorPXE.ps1', 'Install-ServidorPXE.ps1', 'config\ServidorPXE.config.psd1')) {
        Check "nome novo $f" (Test-Path -LiteralPath (Join-Path $script:Root $f)) 'ausente'
    }
    $gi = [IO.File]::ReadAllText((Join-Path $script:Root '.gitignore'))
    Check 'gitignore bloqueia estado e midia' ($gi.Contains('state/') -and $gi.Contains('*.log') -and $gi.Contains('www/_dorpxe/')) 'gitignore permissivo demais'
    Check 'gitignore nao versiona midia gerada' ($gi.Contains('*.iso') -and $gi.Contains('*.wim')) 'gitignore nao bloqueia .iso/.wim'

    # O renome "so no nome visivel" ja deixou 3 nomes de runtime divergentes:
    # share padrao, regra de firewall e nome de servico no sc.exe. Cada par
    # writer/reader tem que concordar, senao o efeito e silencioso (config
    # reescrito, diagnostico cego, sc.exe em servico inexistente).
    $inst = [IO.File]::ReadAllText((Join-Path $script:Root 'Install-ServidorPXE.ps1'))
    $adm = [IO.File]::ReadAllText((Join-Path $script:Root 'lib\Admin.ps1'))
    $cmn = [IO.File]::ReadAllText((Join-Path $script:Root 'lib\Common.ps1'))
    $fwInst = @([regex]::Matches($inst, "Add-DorPXEFirewallRule -Name '(ServidorPXE-\w+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $fwDiag = @([regex]::Matches(($inst + "`n" + $adm + "`n" + $cmn), 'DisplayName ["''](ServidorPXE\*|ServidorPXE-\w+)["'']') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Check 'firewall: 3 regras criadas' ($fwInst.Count -eq 3) "criadas=$($fwInst.Count) (esperado 3)"
    Check 'firewall: diagnostico casa com o instalador' (($fwDiag.Count -gt 0) -and (@($fwDiag | Where-Object { $_ -ne 'ServidorPXE*' }).Count -eq 0)) "diagnostico=$($fwDiag -join ',')"
    $scAlvo = @([regex]::Matches($inst, 'sc\.exe (?:description|failure) (\S+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Check 'sc.exe aponta para o servico ServidorPXE' (($scAlvo.Count -gt 0) -and (@($scAlvo | Where-Object { $_ -ne 'ServidorPXE' }).Count -eq 0)) "alvo=$($scAlvo -join ',')"
    $shareDefault = [regex]::Match($cmn, "Share\s*=\s*'(\w+)'").Groups[1].Value
    Check 'share padrao do config = ServidorPXE' ($shareDefault -eq 'ServidorPXE') "padrao='$shareDefault'"
    $logArq = [regex]::Match($cmn, "'(servidorpxe-\{0\}\.log)'").Groups[1].Value
    $logLeitura = @([regex]::Matches($cmn + "`n" + $adm, "Filter '(servidorpxe-\*\.log)'|'servidorpxe-\*\.log'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Check 'log arquivado: escrita e leitura com o mesmo prefixo' (($logArq -eq 'servidorpxe-{0}.log') -and ($logLeitura.Count -gt 0)) "escrita='$logArq' leitura='$($logLeitura -join ',')"

    # Nenhum texto de runtime pode dizer o nome antigo com D maiusculo. Case
    # SENSITVEL de proposito: "ServidorPXE" contem "dorPXE" e nao pode casar.
    # O marcador e montado em runtime para este proprio bloco nao se detectar.
    $marca = 'Dor' + 'PXE'
    $internos = 'Get-DorPXE|New-DorPXE|Set-DorPXE|Add-DorPXE|Test-DorPXE|Write-DorPXE|Invoke-DorPXE|Resolve-DorPXE|Save-DorPXE|Import-DorPXE|Stop-DorPXE|Start-DorPXE|Move-DorPXE|Update-DorPXE|Initialize-DorPXE|ConvertFrom-DorPXE|ConvertTo-DorPXE|Expand-DorPXE|Build-DorPXE|Copy-DorPXE|Remove-DorPXE|Show-DorPXE|X-DorPXE|DorPXE[A-Z]|DorPXE\.ps1|Install-DorPXE\.ps1|DorPXE\.config|dorpxe_session|dorpxe_t|dorpxe_step|_dorpxe|DORPXE_SKIP'
    $visiveis = @()
    # -Path com wildcard (e nao -LiteralPath) para o -Include valer de fato.
    foreach ($f in (Get-ChildItem -Path (Join-Path $script:Root '*') -Recurse -Include *.ps1, *.bat, *.psd1, .editorconfig, .gitattributes, .gitignore -File -Force | Where-Object { $_.FullName -notmatch '\\(state|logs|www)\\' })) {
        $ln = 0
        foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
            $ln++
            if ($line -cmatch $marca -and $line -cnotmatch $internos) {
                $visiveis += ("{0}:{1}: {2}" -f $f.Name, $ln, $line.Trim())
            }
        }
    }
    Check 'nenhum nome antigo visivel no codigo' ($visiveis.Count -eq 0) ($visiveis -join ' /// ')
    # O config carregado em runtime precisa concordar com o default do
    # New-DorPXEConfig: divergencia aqui sobrescreve o usuario em silencio.
    $cfgFile = Join-Path $script:Root 'config\ServidorPXE.config.psd1'
    if (Test-Path -LiteralPath $cfgFile) {
        $cfgTxt = [IO.File]::ReadAllText($cfgFile)
        $cfgShare = [regex]::Match($cfgTxt, "(?m)^\s*Share\s*=\s*'(\w+)'").Groups[1].Value
        $cfgMsg = [regex]::Match($cfgTxt, "MessageDenied\s*=\s*'(\w+)").Groups[1].Value
        Check 'config: Share = ServidorPXE' ($cfgShare -eq 'ServidorPXE') "config tem '$cfgShare'"
        Check 'config: MessageDenied = ServidorPXE' ($cfgMsg -eq 'ServidorPXE') "config tem '$cfgMsg'"
    }
    # README nao pode documentar um caminho de log que nao existe mais.
    Check 'README documenta o log arquivado atual' ($rd.Contains('logs\servidorpxe-AAAAMMDD.log')) 'README ainda cita logs\dorpxe-AAAAMMDD.log'

    Write-Output ''
    if ($script:TestFail -eq 0) { Write-Output 'RESULTADO: todos os testes passaram.' }
    else { Write-Output ("RESULTADO: {0} falha(s)." -f $script:TestFail) }
}

function Show-DorPXEHealth {
    param($Cfg)
    # usa a instancia em execucao (state\status.json) e nao apenas a config, para respeitar -Port
    $status = $null
    $sf = Join-Path (Get-DorPXEPath).State 'status.json'
    if (Test-Path -LiteralPath $sf) {
        try { $status = [IO.File]::ReadAllText($sf) | ConvertFrom-Json } catch { $status = $null }
    }
    $address = if ($status -and $status.address) { $status.address }
               elseif ($Cfg.Server.Address -and $Cfg.Server.Address -ne 'auto') { $Cfg.Server.Address }
               else { Get-DorPXEIPv4 -BindAddress $Cfg.Dhcp.BindAddress }
    $port = if ($status -and $status.httpPort) { [int]$status.httpPort } else { [int]$Cfg.Server.HttpPort }
    Write-Output "servidor: $address   perfil: http://${address}:$port/pxe/health.txt"
    Write-Output ("console : {0}" -f (Get-DorPXEAdminUrl -Config $Cfg -Port $port))
    if ($status) {
        Write-Output ("instancia: PID {0} desde {1} | dhcp={2} tftp={3} http={4}:{5}" -f $status.pid, $status.started, $status.dhcp, $status.tftp, $status.http, $port)
    }
    Write-Output ''
    # sem elevacao o HttpListener cai para loopback; tenta 127.0.0.1 e depois o endereco de rede
    $targets = @('127.0.0.1')
    if ($address -ne '127.0.0.1') { $targets += $address }
    $h = $null; $hHost = $null
    foreach ($t in $targets) {
        $x = Test-DorPXEHttpProbe -ServerAddress $t -Port $port -Path '/pxe/health.txt'
        if ($x.Ok) { $h = $x; $hHost = $t; break }
        if (-not $h) { $h = $x }
    }
    Write-Output ("HTTP  : {0} {1} (via {2})" -f $(if ($h.Ok) { 'OK  ' } else { 'FALHA' }), $h.Preview, $(if ($hHost) { $hHost } else { $targets -join '/' }))
    $t = $null; $tHost = $null
    foreach ($t2 in $targets) {
        $x = Test-DorPXETftpProbe -ServerAddress $t2
        if ($x.Ok) { $t = $x; $tHost = $t2; break }
        if (-not $t) { $t = $x }
    }
    Write-Output ("TFTP  : {0} {1} ({2} bytes, via {3}) {4}" -f $(if ($t.Ok) { 'OK  ' } else { 'FALHA' }), $t.Reply, $t.Bytes, $(if ($tHost) { $tHost } else { $targets -join '/' }), $t.Preview)
    if ($t.Ok -and -not $tHost) {
        Write-Output '       (so loopback respondeu: rode como administrador para liberar UDP/69 no firewall)'
    }
    $d = Test-DorPXEDhcpProbe -ServerAddress $(if ($status -and $status.dhcp) { '127.0.0.1' } else { '255.255.255.255' })
    $dh = if ($d.Received) { 'OK  ' } else { 'FALHA' }
    Write-Output ("DHCP  : {0} {1} de {2} serverid={3} siaddr={4} next={5} boot={6} {7}" -f $dh, $d.Type, $d.From, $d.ServerId, $d.Siaddr, $d.NextServer, $d.BootFile, $d.Error)
    if ($d.Received -and -not $d.BootFile) {
        Write-Output '       (OFFER sem opcoes 66/67: MAC fora da allowlist, conforme DefaultAction=Local)'
    }
    $bh = $null
    foreach ($t2 in $targets) {
        $x = Test-DorPXEHttpProbe -ServerAddress $t2 -Port $port -Path '/pxe/boot.ipxe?mac=00:00:00:00:00:01'
        if ($x.Ok) { $bh = $x; break }
        if (-not $bh) { $bh = $x }
    }
    Write-Output ('BOOT  : ' + (($bh.Preview -split ' / ') -join ' / '))
    $ph = $null
    foreach ($t2 in $targets) {
        $x = Test-DorPXEHttpProbe -ServerAddress $t2 -Port $port -Path '/pxe/policy.txt?mac=00:00:00:00:00:01'
        if ($x.Ok) { $ph = $x; break }
        if (-not $ph) { $ph = $x }
    }
    Write-Output ('POLICY: ' + ($ph.Preview -replace "`n", ' | '))
}

function Show-DorPXEHelp {
    Write-Output @"
ServidorPXE $(Get-DorPXEVersion) - servidor PXE nativo (PowerShell 5.1) para Windows 11

USO
  .\ServidorPXE.ps1 <Verbo> [opcoes]

VERBOS
  Init          Cria/atualiza config\ServidorPXE.config.psd1 e a arvore de diretorios
  Start         Inicia proxyDHCP + TFTP + HTTP (Ctrl+C encerra)
  Start -Background   Inicia em segundo plano e devolve o controle
  Restart       Para a instancia e sobe outra em segundo plano
  Admin         Mostra a URL do console e quem pode fazer login
  Stop          Encerra a instancia em execucao
  Status        Mostra o estado do servico (state\status.json)
  Install       Executa Install-ServidorPXE.ps1 (firewall, urlacl, share, tarefa)
  Build-Media   Extrai a ISO, monta WinPE por perfil e gera o autounattend
  Device        Lista/cadastra/remove MAC, OUI e prefixos
  Test          Testes locais de codec DHCP/TFTP, politica e scripts iPXE
  Health        Testa HTTP/TFTP/DHCP contra o servidor em execucao
  Help          Esta ajuda

EXEMPLOS
  .\ServidorPXE.ps1 Init
  .\ServidorPXE.ps1 Build-Media -Iso 'D:\ISOs\Win11_24H2_.iso' -VerboseLog
  .\ServidorPXE.ps1 Device -Action Add -Mac AA:BB:CC:DD:EE:FF -Profile win11pro
  .\ServidorPXE.ps1 Device -Action Model -Oui D4:BE:D9 -Model 'OptiPlex 7090' -Profile win11pro
  .\ServidorPXE.ps1 Device -Action Policy -Mode Open -DefaultAction Menu
  .\ServidorPXE.ps1 Start -DurationSec 60
  .\ServidorPXE.ps1 Start -Background -Port 8080      # so HTTP/TFTP, sem UDP/67, em 2o plano
  .\ServidorPXE.ps1 Restart
  .\ServidorPXE.ps1 Admin
  .\ServidorPXE.ps1 Health
  .\ServidorPXE.ps1 Test
"@
}

# ---------------------------------------------------------------- execucao ---
$script:ConfigPath = $Config
if (-not $script:ConfigPath) { $script:ConfigPath = (Get-DorPXEPath).ConfigFile }
  $paths = Get-DorPXEPath
  # Em ambiente novo (projeto baixado do git, sem midia) estas pastas nao existem.
  # Criar aqui evita qualquer erro em cascata no HTTP/TFTP/DHCP.
  $dirs = @(
      $paths.Www, $paths.State, $paths.Logs, $paths.Config, (Split-Path -Parent $paths.ConfigFile)
      $paths.Ipxe, $paths.Pxe, $paths.WinPe, $paths.Media, $paths.Profiles, $paths.Mount
      (Join-Path $paths.WinPe 'profiles'), (Join-Path $paths.WinPe 'shared')
  )
  foreach ($d in $dirs) {
      if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  }
$cfg = Import-DorPXEConfig -Path $script:ConfigPath
if ($WinPeSource) { $cfg.WinPe['Source'] = $WinPeSource }
Initialize-DorPXELog -Level $cfg.Log.Level -Directory $paths.Logs | Out-Null

try {
    switch ($Verb) {
        'Help' { Show-DorPXEHelp }
        'Init' {
            Save-DorPXEConfig -Config $cfg -Path $script:ConfigPath | Out-Null
            Write-DorPXEAutoExec -Config $cfg | Out-Null
            Write-Output "config : $script:ConfigPath"
            Write-Output "www    : $($paths.Www)"
            Write-Output "log    : $($paths.Logs)"
            Write-Output ''
            Write-Output 'Proximo passo: .\ServidorPXE.ps1 Build-Media -Iso "D:\...\Win11.iso"'
        }
        'Start' {
            if ($Background) {
                $me = $MyInvocation.MyCommand.Path
                $argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $me, 'Start')
                if ($Config) { $argl += @('-Config', $Config) }
                if ($Port -gt 0) { $argl += @('-Port', "$Port") }
                if ($NoDhcp) { $argl += '-NoDhcp' }
                if ($NoTftp) { $argl += '-NoTftp' }
                $sf = Join-Path $paths.State 'status.json'
                if (Test-Path -LiteralPath $sf) {
                    try {
                        $st = [IO.File]::ReadAllText($sf) | ConvertFrom-Json
                        if (Get-Process -Id $st.pid -ErrorAction SilentlyContinue) {
                            throw "Ja existe uma instancia em execucao (PID $($st.pid)). Use Stop ou Restart."
                        }
                        Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue
                    }
                    catch { }
                }
                $out = Join-Path $paths.Logs 'service.out.log'
                Start-Process powershell -WindowStyle Hidden -ArgumentList $argl -RedirectStandardOutput $out -RedirectStandardError (Join-Path $paths.Logs 'service.err.log')
                Write-Output "ServidorPXE iniciado em segundo plano (saida: $out)"
                $sf2 = Join-Path $paths.State 'status.json'
                for ($i = 0; $i -lt 40; $i++) {
                    Start-Sleep -Milliseconds 500
                    if (Test-Path -LiteralPath $sf2) {
                        try {
                            $st2 = [IO.File]::ReadAllText($sf2) | ConvertFrom-Json
                            if (Get-Process -Id $st2.pid -ErrorAction SilentlyContinue) { break }
                        }
                        catch { }
                    }
                }
                if (Test-Path -LiteralPath $sf2) { Show-DorPXEStatus -Cfg $cfg }
                else {
                    Write-Output 'A instancia nao registrou status.json; veja logs\service.err.log.'
                    Get-Content (Join-Path $paths.Logs 'service.err.log') -Tail 5 -ErrorAction SilentlyContinue
                }
                exit 0
            }
            Start-DorPXEService -Cfg $cfg -Port $Port
            # o pool de runspaces segura threads de foreground: nem `exit` nem o fim do
            # script encerram o processo. Environment.Exit -> ExitProcess, que libera
            # sockets, http.sys e o mutex do kernel na hora.
            [Environment]::Exit(0)
        }
        'Restart' {
            $r = Stop-DorPXERunningInstance
            Write-Output $r.Message
            if (-not $r.Stopped) {
                throw "A instancia anterior (PID $($r.Pid)) continua rodando. Execute como Administrador para poder reiniciar o servico."
            }
            Start-Sleep -Seconds 2
            $rp = @{ Verb = 'Start'; Background = $true }
            if ($Config) { $rp['Config'] = $Config }
            if ($Port -gt 0) { $rp['Port'] = $Port }
            if ($NoDhcp) { $rp['NoDhcp'] = $true }
            if ($NoTftp) { $rp['NoTftp'] = $true }
            if ($AllowNonAdmin) { $rp['AllowNonAdmin'] = $true }
            & (Join-Path $script:Root 'ServidorPXE.ps1') @rp
        }
        'Admin' {
            $url = Get-DorPXEAdminUrl -Config $cfg -Port $Port
            Write-Output ("console : {0}" -f $url)
            Write-Output ("login   : usuario local do Windows ({0})" -f ((Get-DorPXEAuthGroups -Config $cfg) -join ' | '))
            Write-Output ("usuarios: {0}" -f ((Get-DorPXEAuthUsers -Config $cfg) -join ', '))
            $f = Join-Path $paths.State 'admin-token.txt'
            if (Test-Path -LiteralPath $f) {
                Write-Output ("automacao (localhost): {0}?t={1}" -f $url, ([IO.File]::ReadAllText($f).Trim()))
            }
        }
        'Stop' { Write-Output (Stop-DorPXERunningInstance).Message }
        'Status' { Show-DorPXEStatus -Cfg $cfg -AsJson:$Json }
        'Install' {
            $inst = Join-Path $script:Root 'Install-ServidorPXE.ps1'
            if (-not (Test-Path -LiteralPath $inst)) { throw 'Install-ServidorPXE.ps1 nao encontrado.' }
            & $inst -Config $script:ConfigPath -Verbose:$VerbosePreference
        }
        'Build-Media' {
            $m = if ($Modes) { $Modes } else { @($cfg.WinPe.Modes) }
            $a = if ($Architectures) { $Architectures } else { @($cfg.WinPe.Architectures) }
            $slugBefore = $cfg.Media.Slug
            $r = Build-DorPXEMedia -Config $cfg -Iso $Iso -Modes $m -Architectures $a -Minimal:$Minimal -SkipIso:$SkipIso
            if ($cfg.Media.Slug -ne $slugBefore) { Save-DorPXEConfig -Config $cfg -Path $script:ConfigPath | Out-Null }
            Write-Output ''
            Write-Output ("midia   : {0}" -f $r.Source)
            Write-Output ("compart : {0}" -f $r.Unc)
            Write-Output ("perfis  : {0}" -f ($r.Profiles -join ', '))
            Write-Output ("modos   : {0}  arqs: {1}" -f ($r.Modes -join ', '), ($r.Architectures -join ', '))
            Write-Output ''
            Write-Output 'Para publicar: .\ServidorPXE.ps1 Install'
        }
        'Device' { Invoke-DorPXEDeviceCommand -Cfg $cfg }
        'Test' { Invoke-DorPXETest -Cfg $cfg; if ($script:TestFail -gt 0) { exit 1 } }
        'Health' { Show-DorPXEHealth -Cfg $cfg }
        'Uninstall' {
            & (Join-Path $script:Root 'Install-ServidorPXE.ps1') -Uninstall -Config $script:ConfigPath
        }
    }
}
catch {
    Write-DorPXELog ("ERRO: {0}" -f $_.Exception.Message) -Level Error -Component core
    if ($_.ScriptStackTrace) { Write-DorPXELog $_.ScriptStackTrace -Level Error -Component core }
    Write-Error $_
    exit 1
}
