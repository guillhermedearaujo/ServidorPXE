[CmdletBinding()]
param(
    [string]$Config,
    [string]$ServerAddress,
    [int]$HttpPort = 0,
    [string]$Share = '',
    [string]$Startup = 'ScheduledTask',
    [ValidateSet('ScheduledTask', 'StartupFolder', 'Service', 'None')]
    [string]$Mode = $Startup,
    [string]$TaskName = 'ServidorPXE',
    [string]$TaskUser = 'SYSTEM',
    [string[]]$TaskArgs = @(),
    [switch]$NoFirewall,
    [switch]$NoUrlAcl,
    [switch]$NoShare,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
foreach ($f in (Get-ChildItem -Path (Join-Path $root 'lib\*.ps1') | Sort-Object Name)) { . $f.FullName }

$paths = Get-DorPXEPath
$configPath = if ($Config) { $Config } else { $paths.ConfigFile }
$cfg = Import-DorPXEConfig -Path $configPath
if ($ServerAddress) { $cfg.Server['Address'] = $ServerAddress }
if ($HttpPort -gt 0) { $cfg.Server['HttpPort'] = $HttpPort }
if ($Share) { $cfg.Media['Share'] = $Share }
if (-not (Test-DorPXEAdmin)) { throw 'Execute este script como administrador.' }
$ip = if ($cfg.Server.Address -and $cfg.Server.Address -ne 'auto') { $cfg.Server.Address } else { Get-DorPXEIPv4 -BindAddress $cfg.Dhcp.BindAddress }
if (-not $ip) { throw 'Nao foi possivel determinar o IPv4. Use -ServerAddress.' }
$cfg.Server['Address'] = $ip
$httpPort = [int]$cfg.Server.HttpPort
$tftpPort = [int]$cfg.Server.TftpPort
$shareName = $cfg.Media.Share
$folder = Join-Path $root (Join-Path $cfg.Server.HttpRoot '')
if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
$mediaDir = Join-Path $folder '_dorpxe'
New-Item -ItemType Directory -Path $mediaDir -Force | Out-Null
$autoexec = Join-Path $folder 'autoexec.ipxe'
if (-not (Test-Path -LiteralPath $autoexec)) { Write-DorPXEAutoExec -Config $cfg | Out-Null }
Save-DorPXEConfig -Config $cfg -Path $configPath | Out-Null

function Invoke-Net {
    param([string[]]$NetArgs)
    $out = & netsh @NetArgs 2>&1
    Write-Host ("netsh " + ($NetArgs -join ' '))
    foreach ($l in $out) { if ("$l".Trim()) { Write-Host "   $l" } }
    return $out
}

Write-Host ''
Write-Host '=== ServidorPXE - instalacao ===' -ForegroundColor Cyan
Write-Host ("raiz      : {0}" -f $root)
Write-Host ("servidor  : {0} ({1})" -f $cfg.Server.Name, $ip)
Write-Host ("http      : porta {0}   url: {1}" -f $httpPort, "http://${ip}:${httpPort}/pxe/health.txt")
Write-Host ("tftp      : porta {0}" -f $tftpPort)
Write-Host ("dhcp      : modo {0}  (endereamento continua no Windows Server DHCP)" -f $cfg.Dhcp.Mode)
Write-Host ("politica  : {0} / {1}" -f $cfg.Policy.Mode, $cfg.Policy.DefaultAction)
Write-Host ("compart.  : \\{0}\{1}  ->  {2}" -f $ip, $shareName, $mediaDir)Write-Host ''

if ($Uninstall) {
    Write-Host 'Removendo instalacao...' -ForegroundColor Yellow
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Write-Host "tarefa $TaskName removida" } catch { Write-Host "tarefa ${TaskName}: nao encontrada" }
    foreach ($u in @("http://+:$httpPort/", "http://*:$httpPort/", "https://+:$httpPort/")) {
        Invoke-Net @('http', 'delete', 'urlacl', "url=$u") | Out-Null
    }
    foreach ($r in @(@('ServidorPXE-HTTP', 'TCP'), @('ServidorPXE-TFTP', 'UDP'), @('ServidorPXE-DHCP', 'UDP'))) {
        try { Remove-NetFirewallRule -DisplayName $r[0] -ErrorAction Stop; Write-Host "firewall $($r[0]) removido" } catch { }
    }
    try { Remove-SmbShare -Name $shareName -Force -ErrorAction Stop; Write-Host "share ${shareName} removido" } catch { Write-Host "share ${shareName}: nao encontrado" }
    Write-Host 'Concluido.'
    exit 0
}

# --- firewall -------------------------------------------------------------
if (-not $NoFirewall) {
    Write-Host '[1/5] Firewall' -ForegroundColor Green
    if (Test-DorPXEPortFree -Port $httpPort -Protocol TCP) { }
    Add-DorPXEFirewallRule -Name 'ServidorPXE-HTTP' -Protocol TCP -LocalPort $httpPort -Action Allow -Profile Any -Remove:$false | Out-Null
    Add-DorPXEFirewallRule -Name 'ServidorPXE-TFTP' -Protocol UDP -LocalPort $tftpPort -Action Allow -Profile Any -Remove:$false | Out-Null
    if ($cfg.Dhcp.Enabled) {
        Add-DorPXEFirewallRule -Name 'ServidorPXE-DHCP' -Protocol UDP -LocalPort 67 -Action Allow -Profile Any -Remove:$false | Out-Null
    }
    Write-Host '  regras: ServidorPXE-HTTP, ServidorPXE-TFTP, ServidorPXE-DHCP' -ForegroundColor DarkGray
}

# --- urlacl ---------------------------------------------------------------
if (-not $NoUrlAcl) {
    Write-Host '[2/5] Reserva de URL (urlacl) para HttpListener' -ForegroundColor Green
    foreach ($u in @("http://+:$httpPort/")) {
        $exists = $false
        try { $null = (netsh http show urlacl | Select-String -SimpleMatch $u); $exists = $true } catch { }
        if ($exists) {
            Invoke-Net @('http', 'delete', 'urlacl', "url=$u") | Out-Null
        }
        Invoke-Net @('http', 'add', 'urlacl', "url=$u", "user=$($cfg.Media.ShareAuth)", 'grant=administrators') | Out-Null
    }
}

# --- share SMB ------------------------------------------------------------
if (-not $NoShare) {
    Write-Host '[3/5] Compartilhamento SMB (somente leitura)' -ForegroundColor Green
    $existing = $null
    try { $existing = Get-SmbShare -Name $shareName -ErrorAction Stop } catch { }
    if ($existing) { Write-Host "  share '$shareName' ja existe" -ForegroundColor DarkGray }
    else {
        $null = New-SmbShare -Name $shareName -Path $mediaDir -ReadAccess 'Everyone' -Description 'ServidorPXE - midia de instalacao (somente leitura)' -ErrorAction Stop
        Write-Host "  share criado: $shareName" -ForegroundColor DarkGray
    }
    try { Grant-SmbShareAccess -Name $shareName -AccountName 'Everyone' -AccessRight Read -Force | Out-Null } catch { }
    try { Revoke-SmbShareAccess -Name $shareName -AccountName 'Administrators' -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
    try { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
    $acl = Get-Acl -LiteralPath $mediaDir
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('Everyone', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $mediaDir -AclObject $acl
    Write-Host "  Everyone: leitura apenas ($mediaDir)" -ForegroundColor DarkGray
}

# --- inicializacao --------------------------------------------------------
Write-Host '[4/5] Modo de inicializacao' -ForegroundColor Green
switch ($Mode) {
    'ScheduledTask' {
        $script = Join-Path $root 'ServidorPXE.ps1'
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", 'Start')
        if ($TaskArgs.Count -gt 0) { $argList += $TaskArgs }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argList -join ' ')
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = if ($TaskUser -eq 'SYSTEM') { New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest } else { New-ScheduledTaskPrincipal -UserId $TaskUser -RunLevel Highest -LogonType Password }
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Servidor PXE nativo (ServidorPXE)'
        Write-Host "  tarefa registrada: $TaskName (inicializacao + reinicio automatico)" -ForegroundColor DarkGray
    }
    'StartupFolder' {
        $sh = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
        New-Item -ItemType Directory -Path $sh -Force | Out-Null
        $lnk = Join-Path $sh 'ServidorPXE.cmd'
        Set-Content -LiteralPath $lnk -Encoding ASCII -Value ("@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"{0}`" Start >> `"{1}`" 2>&1" -f (Join-Path $root 'ServidorPXE.ps1'), (Join-Path $paths.Logs 'startup.log'))
        Write-Host "  atalho criado: $lnk" -ForegroundColor DarkGray
    }
    'Service' {
        $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $out = & sc.exe create ServidorPXE binPath= "`"$exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $root 'ServidorPXE.ps1')`" Start" start= auto DisplayName= "ServidorPXE (PXE server)" 2>&1
        Write-Host "  $out" -ForegroundColor DarkGray
        $out2 = & sc.exe description ServidorPXE "Servidor PXE nativo (proxyDHCP + TFTP + HTTP)" 2>&1
        Write-Host "  $out2" -ForegroundColor DarkGray
        $out3 = & sc.exe failure ServidorPXE reset= 86400 actions= restart/5000/restart/10000/restart/20000 2>&1
        Write-Host "  $out3" -ForegroundColor DarkGray
    }
    'None' { Write-Host '  sem inicializacao automatica' -ForegroundColor DarkGray }
}

# --- validacao -----------------------------------------------------------
Write-Host '[5/5] Validacao' -ForegroundColor Green
$free = Test-DorPXEPortFree -Port 67 -Protocol UDP
Write-Host ("  UDP/67 livre           : {0}" -f $free)
$free = Test-DorPXEPortFree -Port $tftpPort -Protocol UDP
Write-Host ("  UDP/{0} livre          : {1}" -f $tftpPort, $free)
$free = Test-DorPXEPortFree -Port $httpPort -Protocol TCP
Write-Host ("  TCP/{0} livre          : {1}" -f $httpPort, $free)
foreach ($f in @('www\ipxe\x86_64-pcbios\undionly.kpxe', 'www\ipxe\x86_64-efi\ipxe.efi', 'www\ipxe\wimboot\x86_64\wimboot', 'www\autoexec.ipxe')) {
    $p = Join-Path $root $f
    Write-Host ("  {0,-46}: {1}" -f $f, $(if (Test-Path -LiteralPath $p) { 'presente' } else { 'AUSENTE' }))
}
$mediaOk = Test-Path -LiteralPath (Join-Path $mediaDir 'media')
Write-Host ("  midia extraida         : {0}" -f $(if ($mediaOk) { 'presente ( rode Build-Media )' } else { 'ainda nao - rode: .\ServidorPXE.ps1 Build-Media -Iso <iso>' }))
Write-Host ''
Write-Host 'Instalacao concluida.' -ForegroundColor Cyan
Write-Host '  .\ServidorPXE.ps1 Test          # testes locais de codec/politica'
Write-Host '  .\ServidorPXE.ps1 Start         # sobe os servicos (Ctrl+C encerra)'
Write-Host '  .\ServidorPXE.ps1 Health        # valida HTTP/TFTP/DHCP'
Write-Host '  cliente: PXE em rede (USB/Ethernet) -> deve aparecer ServidorPXE'
Write-Host ''
