function Get-DorPXEDeviceDb {
    [CmdletBinding()]
    param([string]$Path)
    $p = Get-DorPXEPath
    if (-not $Path) { $Path = $p.Devices }
    $db = @{ Devices = @(); Models = @(); Prefixes = @() }
    if (Test-Path -LiteralPath $Path) {
        try {
            $raw = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
            if ($raw.devices) { $db.Devices = @($raw.devices) }
            if ($raw.models) { $db.Models = @($raw.models) }
            if ($raw.prefixes) { $db.Prefixes = @($raw.prefixes) }
        }
        catch {
            Write-DorPXELog "Device DB invalido em '$Path': $($_.Exception.Message)" -Level Error -Component policy
        }
    }
    return $db
}

function Save-DorPXEDeviceDb {
    [CmdletBinding()]
    param($Database, [string]$Path)
    $p = Get-DorPXEPath
    if (-not $Path) { $Path = $p.Devices }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $obj = [pscustomobject]@{
        devices  = @($Database.Devices)
        models   = @($Database.Models)
        prefixes = @($Database.Prefixes)
    }
    $json = $obj | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
    return $Path
}

function Add-DorPXEDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mac,
        [string]$Profile,
        [ValidateSet('Boot', 'Menu', 'Deny')][string]$Action = 'Boot',
        [string]$Model,
        [string]$Note
    )
    $m = ConvertTo-DorPXEMac $Mac
    if (-not $m) { throw "MAC invalido: '$Mac'" }
    $db = Get-DorPXEDeviceDb
    $entry = @{}
    foreach ($d in $db.Devices) { if ((ConvertTo-DorPXEMac $d.mac) -eq $m) { $entry = $d } }
    $entry['mac'] = $m
    if ($PSBoundParameters.ContainsKey('Profile')) { $entry['profile'] = $Profile }
    if ($PSBoundParameters.ContainsKey('Model')) { $entry['model'] = $Model }
    if ($PSBoundParameters.ContainsKey('Note')) { $entry['note'] = $Note }
    $entry['action'] = $Action
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($d in $db.Devices) { if ((ConvertTo-DorPXEMac $d.mac) -ne $m) { $list.Add($d) } }
    $list.Add([pscustomobject]$entry)
    $db.Devices = $list.ToArray()
    Save-DorPXEDeviceDb -Database $db | Out-Null
    return [pscustomobject]$entry
}

function Remove-DorPXEDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Mac)
    $m = ConvertTo-DorPXEMac $Mac
    $db = Get-DorPXEDeviceDb
    $before = @($db.Devices).Count
    $db.Devices = @($db.Devices | Where-Object { (ConvertTo-DorPXEMac $_.mac) -ne $m })
    Save-DorPXEDeviceDb -Database $db | Out-Null
    return ($before -ne @($db.Devices).Count)
}

function Add-DorPXEModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Oui,
        [string]$Vendor,
        [string]$Profile
    )
    $o = (($Oui -replace '[^0-9A-Fa-f]', '').ToUpperInvariant())
    if ($o.Length -ne 6) { throw "OUI invalido: '$Oui' (use 6 hex, ex. D4:BE:D9)" }
    $key = (($o -split '(.{2})' | Where-Object { $_ }) -join ':')
    $db = Get-DorPXEDeviceDb
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($x in $db.Models) { if ((($x.oui -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()) -ne $o) { $list.Add($x) } }
    $list.Add([pscustomobject]@{ oui = $key; vendor = $Vendor; profile = $Profile })
    $db.Models = $list.ToArray()
    Save-DorPXEDeviceDb -Database $db | Out-Null
    return $key
}

function Add-DorPXEPrefix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [string]$Profile
    )
    $m = ConvertTo-DorPXEMac $Prefix
    if (-not $m) { throw "Prefixo invalido: '$Prefix'" }
    $db = Get-DorPXEDeviceDb
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($x in $db.Prefixes) { if ((ConvertTo-DorPXEMac $x.prefix) -ne $m) { $list.Add($x) } }
    $list.Add([pscustomobject]@{ prefix = $m; profile = $Profile })
    $db.Prefixes = $list.ToArray()
    Save-DorPXEDeviceDb -Database $db | Out-Null
    return $m
}

function Get-DorPXEProfiles {
    [CmdletBinding()]
    param($Config)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($pr in @($Config.Profiles)) {
        if (-not $pr.Name) { continue }
        $out.Add([pscustomobject]@{
                Name         = $pr.Name
                Title        = $(if ($pr.Title) { $pr.Title } else { $pr.Name })
                ImageName    = $pr.ImageName
                ImageIndex   = [int]$pr.ImageIndex
                Scheme       = $(if ($pr.Scheme) { $pr.Scheme } else { 'Auto' })
                SystemSizeMB = [int]$pr.SystemSizeMB
                ProductKey   = $pr.ProductKey
                SkipRgc      = $pr.SkipRgc
                TimeZone     = $pr.TimeZone
                ComputerName = $(if ($pr.ComputerName) { $pr.ComputerName } else { '*' })
                UserName     = $pr.UserName
                UserPassword = $pr.UserPassword
                UserGroup    = $(if ($pr.UserGroup) { $pr.UserGroup } else { 'Administrators' })
                Locale       = $(if ($pr.Locale) { $pr.Locale } else { 'pt-BR' })
                SkipOOBE     = [bool]$pr.SkipOOBE
                Drivers      = @($pr.Drivers)
            })
    }
    return $out
}

function Get-DorPXEProfile {
    [CmdletBinding()]
    param($Config, [string]$Name)
    Get-DorPXEProfiles -Config $Config | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Resolve-DorPXEDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$Mac,
        [string]$Ip
    )
    $m = if ($Mac) { ConvertTo-DorPXEMac $Mac } else { $null }
    $dec = [pscustomobject]@{
        Mac       = $m
        Ip        = $Ip
        Allowed   = $false
        Action    = 'Deny'
        Profile   = $null
        Model     = $null
        Vendor    = $null
        Source    = 'none'
        Reason    = ''
        Default   = ($false)
    }
    $db = Get-DorPXEDeviceDb
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($Config.Policy.Devices)) { if ($d) { $all.Add($d) } }
    foreach ($d in @($db.Devices)) { if ($d) { $all.Add($d) } }
    $allModels = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($Config.Policy.Models)) { if ($d) { $allModels.Add($d) } }
    foreach ($d in @($db.Models)) { if ($d) { $allModels.Add($d) } }
    $allPrefixes = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($Config.Policy.Prefixes)) { if ($d) { $allPrefixes.Add($d) } }
    foreach ($d in @($db.Prefixes)) { if ($d) { $allPrefixes.Add($d) } }

    if ($m) {
        foreach ($d in $all) {
            if ((ConvertTo-DorPXEMac $d.mac) -eq $m) {
                $dec.Allowed = $true
                $dec.Source = 'device'
                $dec.Model = $d.model
                $dec.Profile = $d.profile
                $dec.Action = $(if ($d.action) { $d.action } else { 'Boot' })
                $dec.Reason = "MAC cadastrado$($(if ($d.note) { ' - ' + $d.note } else { '' }))"
                return $dec
            }
        }
        foreach ($pf in $allPrefixes) {
            $p = ConvertTo-DorPXEMac $pf.prefix
            if ($p -and $m.StartsWith($p)) {
                $dec.Allowed = $true
                $dec.Source = 'prefix'
                $dec.Profile = $pf.profile
                $dec.Action = 'Boot'
                $dec.Reason = "Prefixo MAC $p"
                return $dec
            }
        }
        $oui = Get-DorPXEOui $m
        foreach ($mo in $allModels) {
            $o = $mo.oui -replace '[^0-9A-Fa-f]', ''
            if ($o.Length -eq 6) {
                $onorm = ((($o.ToUpperInvariant()) -split '(.{2})' | Where-Object { $_ }) -join ':')
                if ($onorm -eq $oui) {
                    $dec.Allowed = $true
                    $dec.Source = 'model'
                    $dec.Model = $mo.model
                    $dec.Vendor = $mo.vendor
                    $dec.Profile = $mo.profile
                    $dec.Action = 'Boot'
                    $dec.Reason = "Modelo/fabricante $($mo.vendor) (OUI $oui)"
                    return $dec
                }
            }
        }
        if (-not $dec.Vendor) { $dec.Vendor = Get-DorPXEMacVendor -Mac $m }
    }

    $mode = if ($Config.Policy.Mode) { $Config.Policy.Mode } else { 'AllowList' }
    if ($mode -eq 'Open') {
        $dec.Allowed = $true
        $dec.Default = $true
        $dec.Source = 'open'
        $dec.Action = $(if ($Config.Policy.DefaultAction) { $Config.Policy.DefaultAction } else { 'Menu' })
        if ($dec.Action -ne 'Deny') { $dec.Profile = (Get-DorPXEProfiles -Config $Config | Select-Object -First 1).Name }
        $dec.Reason = 'Boot aberto (Policy.Mode=Open)'
        return $dec
    }
    $da = if ($Config.Policy.DefaultAction) { $Config.Policy.DefaultAction } else { 'Local' }
    $dec.Allowed = $false
    $dec.Source = 'denied'
    $dec.Reason = "Nao consta na allowlist (padrao: $da)"
    if ($da -eq 'Menu') { $dec.Allowed = $true; $dec.Action = 'Menu'; $dec.Reason += ' - exibindo menu' }
    return $dec
}

function Get-DorPXEBaseUrl {
    param($Config, [string]$Address)
    $port = [int]$Config.Server.HttpPort
    $hostName = if ($Address) { $Address } else { $Config.Server.Address }
    if (-not $hostName -or $hostName -eq 'auto') {
        $hostName = Get-DorPXEIPv4 -BindAddress $Config.Dhcp.BindAddress
    }
    if ($port -eq 80) { return "http://$hostName" }
    return "http://${hostName}:$port"
}

function Get-DorPXEAutoExecScript {
    [CmdletBinding()]
    param($Config)
    $ip = if ($Config.Server.Address -and $Config.Server.Address -ne 'auto') { $Config.Server.Address } else { '<PXE-IP>' }
    $port = [int]$Config.Server.HttpPort
    $suffix = if ($port -eq 80) { '' } else { ":$port" }
    @(
        '#!ipxe',
        '# ServidorPXE - 2o estagio. Este script e buscado pelo proprio iPXE via TFTP',
        '# (o arquivo "autoexec.ipxe") ou pelo boot file devolvido no DHCP.',
        'isset ${next-server} && set pxe ${next-server} || set pxe ' + $ip,
        'isset ${net0/mac} && set mymac ${net0/mac} || set mymac 00:00:00:00:00:00',
        'isset ${net0/ip} && set myip ${net0/ip} || set myip 0.0.0.0',
        'chain http://${pxe}' + $suffix + '/pxe/boot.ipxe?mac=${mymac}&ip=${myip}&ver=' + (Get-DorPXEVersion)
    ) -join "`r`n"
}

function Get-DorPXEDenyScript {
    [CmdletBinding()]
    param($Config, $Decision)
    $msg = if ($Config.Policy.MessageDenied) { $Config.Policy.MessageDenied } else { 'Acesso negado.' }
    $msg = ($msg -replace '[^\x20-\x7E]', '')
    @(
        '#!ipxe',
        '# ServidorPXE - acesso negado',
        'echo ---------------------------------------------',
        'echo ' + $msg,
        ('echo MAC: {0}   IP: {1}' -f $Decision.Mac, $Decision.Ip),
        'echo Motivo: ' + $Decision.Reason,
        'echo ---------------------------------------------',
        'echo O computador ira iniciar pelo disco local.',
        'prompt --key 0x02 --timeout 3000 Pressione Ctrl-B para o shell do iPXE && shell || exit',
        'exit'
    ) -join "`r`n"
}

function Get-DorPXEModeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$ProfileName
    )
    $p = Get-DorPXEPath
    $res = @{}
    foreach ($mode in @('uefi', 'bios')) {
        $wim = Join-Path $p.WinPe (Join-Path ('profiles\' + $ProfileName) (Join-Path $mode 'boot.wim'))
        $shared = Join-Path $p.WinPe (Join-Path 'shared' $mode)
        $fonts = @()
        $fdir = Join-Path $shared 'Fonts'
        foreach ($f in @('segmono_boot.ttf', 'segoe_slboot.ttf', 'segoeui_slboot.ttf', 'wgl4_boot.ttf')) {
            if (Test-Path -LiteralPath (Join-Path $fdir $f)) { $fonts += $f }
        }
        # arquiteturas extras publicadas: boot.i386.wim, boot.arm64.wim, ...
        $extras = @()
        $pdir = Join-Path $p.WinPe (Join-Path ('profiles\' + $ProfileName) $mode)
        foreach ($f in @(Get-ChildItem -LiteralPath $pdir -Filter 'boot.*.wim' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $extras += [pscustomobject]@{ Arch = $f.BaseName.Substring(5); File = $f.Name }
        }
        $res[$mode] = [pscustomobject]@{
            Mode   = $mode
            Ready  = ((Test-Path -LiteralPath $wim) -and (Test-Path -LiteralPath (Join-Path $shared 'BCD')) -and ($fonts.Count -gt 0))
            Wim    = $wim
            Bcd    = (Test-Path -LiteralPath (Join-Path $shared 'BCD'))
            Sdi    = (Test-Path -LiteralPath (Join-Path $shared 'boot.sdi'))
            Fonts  = $fonts
            Extras = $extras
        }
    }
    return $res
}

function Get-DorPXEBootScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Profile,
        $Decision,
        [switch]$Quiet
    )
    $base = Get-DorPXEBaseUrl -Config $Config
    $state = Get-DorPXEModeState -Config $Config -ProfileName $Profile.Name
    $ready = @($state.Values | Where-Object { $_.Ready } | ForEach-Object { $_.Mode })
    if ($ready.Count -eq 0) {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('#!ipxe')
        $lines.Add('# ServidorPXE ' + (Get-DorPXEVersion) + ' - perfil ainda nao publicado')
        $lines.Add('echo [ServidorPXE] O perfil ' + $Profile.Name + ' ainda nao tem WinPE publicado.')
        $lines.Add('echo [ServidorPXE] No servidor: .\ServidorPXE.ps1 Build-Media -Iso "...\Win11.iso"')
        $lines.Add('echo [ServidorPXE] MAC: ' + $(if ($Decision) { $Decision.Mac } else { '?' }))
        $lines.Add('prompt --key 0x02 --timeout 5000 Pressione Ctrl-B para o shell do iPXE && shell || exit')
        $lines.Add('shell || exit')
        $lines.Add('exit')
        return ($lines -join "`r`n")
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('#!ipxe')
    $lines.Add('# ServidorPXE ' + (Get-DorPXEVersion) + ' - perfil: ' + $Profile.Name)
    if ($Decision) {
        $lines.Add(('# MAC {0} | modelo {1} | perfil {2} | origem {3}' -f `
                    $Decision.Mac, $(if ($Decision.Model) { $Decision.Model } else { '?' }), $Profile.Name, $Decision.Source))
    }
    $lines.Add('set base ' + $base)
    $lines.Add('isset ${platform} && echo [ServidorPXE] platform=${platform} arch=${arch} || echo [ServidorPXE] platform=? arch=${arch}')
    if ($ready.Count -eq 1) { $lines.Add('set mode ' + $ready[0]) }
    else {
        $lines.Add("isset `${platform} && ! match `${platform} pcbios && set mode uefi || set mode bios")
    }
    if (-not $Quiet) {
        $lines.Add('prompt --key 0x02 --timeout 2000 Pressione Ctrl-B para o shell do iPXE && shell || true')
    }
    $lines.Add('echo [ServidorPXE] booting perfil ' + $Profile.Name + ' (' + $Profile.Title + ') modo ${mode}')
    $lines.Add('echo [ServidorPXE] origem: ' + $(if ($Decision) { $Decision.Reason } else { 'n/d' }))
    $lines.Add('kernel ${base}/ipxe/wimboot/${arch}/wimboot initrd=boot.wim')
    $lines.Add('initrd --name BCD ${base}/winpe/shared/${mode}/BCD BCD')
    $lines.Add('initrd --name boot.sdi ${base}/winpe/shared/${mode}/boot.sdi boot.sdi')
    $allFonts = @('segmono_boot.ttf', 'segoe_slboot.ttf', 'segoeui_slboot.ttf', 'wgl4_boot.ttf')
    foreach ($f in $allFonts) {
        if (($ready | ForEach-Object { $state[$_].Fonts }) -contains $f) {
            $lines.Add("initrd --name $f `${base}/winpe/shared/`${mode}/Fonts/$f $f")
        }
    }
    # boot.wim canonico (x86_64) em boot.wim; arquiteturas extras em boot.<arch>.wim.
    # o iPXE escolhe pelo ${arch} do cliente, sem pedir arquivo extra ao servidor.
    # A URL usa ${mode} (variavel do iPXE), nao o modo do servidor: portanto o que
    # importa e o conjunto de architectures extras, nao quantos modos estao
    # prontos. Deduplicar por arquivo evita emitir a mesma linha N vezes (uma por
    # modo pronto) e evita referenciar um extra que so foi publicado em um modo.
    $purl = '${base}/winpe/profiles/' + $Profile.Name + '/${mode}'
    $lines.Add('set wim ' + $purl + '/boot.wim')
    $extras = @{}
    foreach ($mode2 in $ready) {
        foreach ($x in @($state[$mode2].Extras)) {
            if (-not $x -or -not $x.Arch -or -not $x.File) { continue }
            $extras[$x.File] = $x.Arch
        }
    }
    foreach ($file in ($extras.Keys | Sort-Object)) {
        $archName = $extras[$file]
        $lines.Add("isset `${arch} && match `${arch} $archName* && set wim $purl/$file || true")
    }
    $lines.Add('initrd --name boot.wim ${wim} boot.wim')
    $lines.Add('imgstat')
    $lines.Add('boot || goto fail')
    $lines.Add(':fail')
    $lines.Add('echo [ServidorPXE] FALHA ao iniciar o WinPE do perfil ' + $Profile.Name)
    $lines.Add('echo [ServidorPXE] abrindo menu de perfis...')
    $lines.Add('chain ${base}/pxe/menu.ipxe || exit')
    return ($lines -join "`r`n")
}

function Get-DorPXEMenuScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        $Decision
    )
    $base = Get-DorPXEBaseUrl -Config $Config
    $names = @($Config.Policy.MenuProfiles)
    $profiles = Get-DorPXEProfiles -Config $Config
    if ($names.Count -gt 0) { $profiles = @($profiles | Where-Object { $_.Name -in $names }) }
    if ($profiles.Count -eq 0) { $profiles = @($profiles | Select-Object -First 1) }
    $timeout = [int]$Config.Policy.MenuSeconds
    if ($timeout -lt 5) { $timeout = 5 }
    if ($timeout -gt 600) { $timeout = 600 }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('#!ipxe')
    $lines.Add('# ServidorPXE ' + (Get-DorPXEVersion) + ' - menu de instalacao')
    $lines.Add('set base ' + $base)
    if ($Decision) {
        $lines.Add(('# MAC {0} | modelo {1} | origem {2}' -f `
                    $Decision.Mac, $(if ($Decision.Model) { $Decision.Model } else { '?' }), $Decision.Source))
    }
    $lines.Add('echo.')
    $lines.Add('echo  ============================================================')
    $lines.Add('echo     ServidorPXE - escolha o perfil de instalacao')
    $lines.Add('echo  ============================================================')
    $i = 1
    $lines.Add('item local exit')
    foreach ($pr in $profiles) {
        $lines.Add('item chain ${base}/pxe/boot.ipxe?profile=' + $pr.Name + '   ' + $i + '. ' + $pr.Title + ' [' + $pr.Name + ']')
        $i++
    }
    $lines.Add('item exit  ' + $i + '. Inicializar pelo disco local (sair do PXE)')
    $lines.Add('echo  ------------------------------------------------------------')
    $lines.Add('echo  MAC: ${net0/mac}   IP: ${net0/ip}   Arq: ${arch}')
    $lines.Add('echo  ============================================================')
    $lines.Add(('choose --default local --timeout {0} <<< Digite o numero e pressione ENTER >>>' -f $timeout))
    $lines.Add('${selected} || exit')
    $lines.Add('exit')
    return ($lines -join "`r`n")
}

function Get-DorPXEStatusScript {
    [CmdletBinding()]
    param($Config, $Decision)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('#!ipxe')
    $lines.Add('set base ' + (Get-DorPXEBaseUrl -Config $Config))
    $lines.Add('echo [ServidorPXE] nenhum perfil configurado para este equipamento.')
    $lines.Add('chain ${base}/pxe/health.txt || exit')
    $lines.Add('exit')
    return ($lines -join "`r`n")
}
