$script:DorPXEVersion = '1.0.0'
$script:DorPXEBasePath = Split-Path -Parent $PSScriptRoot
$script:DorPXELibPath = Join-Path $script:DorPXEBasePath 'lib'
$script:DorPXELogFile = $null
$script:DorPXELevel = 1

$script:DorPXELevels = @{ 0 = 'Error'; 1 = 'Warn'; 2 = 'Info'; 3 = 'Debug' }

function Get-DorPXEVersion { $script:DorPXEVersion }

function Get-DorPXEPath {
    $base = $script:DorPXEBasePath
    [pscustomobject]@{
        Base       = $base
        Lib        = Join-Path $base 'lib'
        Config     = Join-Path $base 'config'
        ConfigFile = Join-Path $base 'config\ServidorPXE.config.psd1'
        Www        = Join-Path $base 'www'
        Ipxe       = Join-Path $base 'www\ipxe'
        Pxe        = Join-Path $base 'www\pxe'
        WinPe      = Join-Path $base 'www\winpe'
        Media      = Join-Path $base 'www\_dorpxe\media'   # mesma pasta de Get-DorPXEMediaRoot
        Profiles   = Join-Path $base 'www\_dorpxe\profiles'
          State      = Join-Path $base 'state'
          Devices    = Join-Path $base 'state\devices.json'
          Logs       = Join-Path $base 'logs'
          LogFile    = Join-Path $base 'servidorpxe.log'
        Mount      = Join-Path $base 'state\mount'
    }
}

function New-DorPXEConfig {
    $p = Get-DorPXEPath
    @{
        Server = @{
            Name         = 'DOR-PXE'
            Address      = 'auto'
            HttpPort     = 8080
            TftpPort     = 69
            HttpRoot     = 'www'
            Https        = $false
            HttpsThumbprint = ''
        }
        Dhcp = @{
            Enabled      = $true
            Mode         = 'Proxy'
            BindAddress  = 'auto'
            NextServer   = 'auto'
            ProxyAck     = $true
            ExtraOptions = @{}
        }
        Policy = @{
            Mode            = 'AllowList'
            DefaultAction   = 'Local'
            Devices         = @()
            Models          = @()
            Prefixes        = @()
            MenuProfiles    = @()
            MenuSeconds     = 30
            MessageDenied   = 'DorPXE: este equipamento nao esta autorizado para boot via rede.'
        }
        Profiles = @(
            @{
                Name         = 'win11pro'
                Title        = 'Windows 11 Pro'
                ImageName    = 'Windows 11 Pro'
                ImageIndex   = 0
                Scheme       = 'Auto'
                SystemSizeMB = 0
                ProductKey   = ''
                SkipRgc      = 'Target'
                TimeZone     = 'E. South America Standard Time'
                ComputerName = '*'
                UserName     = 'deploy'
                UserPassword = ''
                UserGroup    = 'Administrators'
                Locale       = 'pt-BR'
                SkipOOBE     = $true
                Drivers      = @()
            }
        )
          Media = @{
              Iso                 = @()
              IsoDir              = ''
              Slug                = 'win11'
            Share               = 'DorPXE'
            ShareAuth           = 'Everyone'
            SetupUser           = ''
            SetupPassword       = ''
            SkipDynamicUpdate   = $true
            KeepExtracted       = $true
        }
        WinPe = @{
            Source          = 'MediaIso'
            CustomBootWim   = ''
            Modes           = @('Uefi')
            Architectures   = @('x86_64')
            IncludeBcd      = $true
            IncludeSdi      = $true
            IncludeFonts    = $true
            AddPowerShell   = $false
        }
        Security = @{
            HttpAllow        = @()
            TftpAllow        = @()
            MaxConcurrentTftp = 24
            MaxConcurrentHttp = 24
            LoopMax          = 3
            LoopWindowSec    = 60
        }
        Log = @{
            Level    = 'Info'
            KeepDays = 30
        }
    }
}

function Import-DorPXEConfig {
    [CmdletBinding()]
    param([string]$Path, [switch]$Merge)
    $p = Get-DorPXEPath
    if (-not $Path) { $Path = $p.ConfigFile }
    $cfg = New-DorPXEConfig
    if (Test-Path -LiteralPath $Path) {
        $user = $null
        $txt = [IO.File]::ReadAllText($Path)
        try { $user = Invoke-Expression $txt } catch { throw "Falha ao ler configuracao '$Path': $($_.Exception.Message)" }
        if ($null -eq $user) { throw "Configuracao '$Path' vazia ou invalida." }
        $cfg = Merge-DorPXEHash -Base $cfg -Override $user
    }
    # normaliza valores invalidos de configuracoes antigas (menu sem timeout travava o boot)
    $ms = 0
    if (-not [int]::TryParse([string]$cfg.Policy.MenuSeconds, [ref]$ms)) { $ms = 0 }
    $cfg.Policy['MenuSeconds'] = [Math]::Min(600, [Math]::Max(5, $ms))
    if (-not $cfg.Server.TftpPort -or [int]$cfg.Server.TftpPort -lt 1) { $cfg.Server['TftpPort'] = 69 }
    if (-not $cfg.Server.HttpPort -or [int]$cfg.Server.HttpPort -lt 1) { $cfg.Server['HttpPort'] = 8080 }
    return $cfg
}

function Merge-DorPXEHash {
    param($Base, $Override)
    if ($null -eq $Override) { return $Base }
    $isMap = ($Base -is [System.Collections.IDictionary])
    if ($isMap) {
        $out = @{}
        foreach ($k in $Base.Keys) { $out[$k] = $Base[$k] }
        foreach ($k in $Override.Keys) {
            if ($out.ContainsKey($k) -and $out[$k] -is [System.Collections.IDictionary] -and $Override[$k] -is [System.Collections.IDictionary]) {
                $out[$k] = Merge-DorPXEHash -Base $out[$k] -Override $Override[$k]
            }
            else { $out[$k] = $Override[$k] }
        }
        return $out
    }
    return $Override
}

function Save-DorPXEConfig {
    [CmdletBinding()]
    param($Config, [string]$Path)
    $p = Get-DorPXEPath
    if (-not $Path) { $Path = $p.ConfigFile }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# DorPXE $script:DorPXEVersion - configuracao (edite a mao, recarregue com -Verb Start)")
    $lines.Add('#')
    $lines.Add('# ATENCAO - SEGREDOS: ProductKey, Profiles[].UserPassword e Media.SetupPassword')
    $lines.Add('# entram NESTA imagem. Nao versione esta imagem em repositorio publico.')
    $lines.Add('# Use o prompt de credencial / GPO / gerenciador de segredos e mantenha')
    $lines.Add('# estes campos vazios no arquivo.')
    $lines.Add('#')
    $lines.Add('@{')
    foreach ($section in $Config.Keys) {
        $lines.Add("    $section = " + (ConvertTo-DorPXELiteral -Value $Config[$section] -Indent 4))
    }
    $lines.Add('}')
    [IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
    return $Path
}

function ConvertTo-DorPXELiteral {
    param($Value, [int]$Indent = 0)
    $pad = ' ' * $Indent
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return [string]$Value }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '@{}' }
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add('@{')
        foreach ($k in $Value.Keys) {
            $out.Add(($pad + '    ' + $k + ' = ' + (ConvertTo-DorPXELiteral -Value $Value[$k] -Indent ($Indent + 4))))
        }
        $out.Add($pad + '}')
        return ($out -join "`r`n")
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $list = @($Value)
        if ($list.Count -eq 0) { return '@()' }
        $items = @()
        foreach ($i in $list) { $items += (ConvertTo-DorPXELiteral -Value $i -Indent $Indent) }
        return '@(' + ($items -join ', ') + ')'
    }
    return "'" + ([string]$Value -replace "'", "''") + "'"
}

  function Initialize-DorPXELog {
      [CmdletBinding()]
      param([string]$Level = 'Info', [string]$Directory)
      $p = Get-DorPXEPath
      if (-not $Directory) { $Directory = $p.Logs }
      New-Item -ItemType Directory -Path $Directory -Force | Out-Null
      $script:DorPXELevel = switch ($Level) { 'Error' { 0 } 'Warn' { 1 } 'Info' { 2 } 'Debug' { 3 } default { 2 } }
      # log ativo: UM arquivo de texto na raiz do projeto (servidorpxe.log).
      # O arquivo do dia anterior vai para logs\dorpxe-AAAAMMDD.log.
      Move-DorPXEStaleLog -File $p.LogFile -Archive $Directory
      $script:DorPXELogFile = $p.LogFile
      Remove-DorPXEOldLog -Directory $Directory
      return $script:DorPXELogFile
  }

  function Move-DorPXEStaleLog {
      [CmdletBinding()]
      param([string]$File, [string]$Archive)
      if (-not $File -or -not $Archive) { return }
      if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return }
      try {
          $fi = Get-Item -LiteralPath $File
          if ($fi.LastWriteTime.Date -eq (Get-Date).Date) { return }
          $dest = Join-Path $Archive ('dorpxe-{0}.log' -f $fi.LastWriteTime.ToString('yyyyMMdd'))
          Move-Item -LiteralPath $File -Destination $dest -Force -ErrorAction Stop
      }
      catch { }
  }

function Set-DorPXELogTarget {
    param([string]$File, [string]$Level = 'Info')
    if ($File) { $script:DorPXELogFile = $File }
    $script:DorPXELevel = switch ($Level) { 'Error' { 0 } 'Warn' { 1 } 'Info' { 2 } 'Debug' { 3 } default { 2 } }
}

function Remove-DorPXEOldLog {
    param([string]$Directory, [int]$KeepDays = 30)
    try {
        Get-ChildItem -LiteralPath $Directory -Filter 'dorpxe-*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

function Write-DorPXELog {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('Error', 'Warn', 'Info', 'Debug')][string]$Level = 'Info',
        [string]$Component = 'core'
    )
    $lvl = switch ($Level) { 'Error' { 0 } 'Warn' { 1 } 'Info' { 2 } 'Debug' { 3 } default { 2 } }
    $color = switch ($Level) { 'Error' { 'Red' } 'Warn' { 'Yellow' } 'Info' { 'Gray' } 'Debug' { 'DarkGray' } }
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    $line = "{0} [{1,-5}] {2,-8} {3}" -f $ts, $Level.ToUpper(), $Component, $Message
    if ($lvl -le $script:DorPXELevel) {
        Write-Host ("{0} [{1,-5}] {2,-8} {3}" -f $ts, $Level.ToUpper(), $Component, $Message) -ForegroundColor $color
    }
    if ($script:DorPXELogFile) {
        # UTF-8 com BOM: o Windows (Get-Content, type, Notepad) le os acentos corretamente.
        # O BOM so e escrito na criacao do arquivo; os anexos seguintes nao repetem.
        try {
            if (-not $script:DorPXELogEncoding) { $script:DorPXELogEncoding = New-Object Text.UTF8Encoding($true) }
            [IO.File]::AppendAllText($script:DorPXELogFile, $line + "`r`n", $script:DorPXELogEncoding)
        }
        catch { }
    }
}

function ConvertTo-DorPXEMac {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    $hex = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($hex.Length -ne 12) { return $null }
    (($hex -split '(.{2})' | Where-Object { $_ }) -join ':')
}

function Get-DorPXEOui {
    param([string]$Mac)
    $m = ConvertTo-DorPXEMac $Mac
    if (-not $m) { return $null }
    ($m -split ':')[0..2] -join ':'
}

function Import-DorPXEOuiMap {
    param([string]$Path)
    $p = Get-DorPXEPath
    if (-not $Path) { $Path = Join-Path $p.State 'oui-map.tsv' }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $n = 0
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadLines($Path)) {
        $t = $line.Trim()
        if (-not $t) { continue }
        $parts = $t -split "`t", 2
        if ($parts.Count -ne 2) { $parts = $t -split '\s{2,}', 2 }
        if ($parts.Count -ne 2) { continue }
        $key = $parts[0].Trim().ToUpperInvariant()
        if ($key -notmatch '^[0-9A-F]{2}([:-][0-9A-F]{2}){2}$' -and $key -notmatch '^[0-9A-F]{6}$') { continue }
        $key = ConvertTo-DorPXEMac ($key + '000000')
        $key = ($key -split ':')[0..2] -join ':'
        $out.Add("$key`t$($parts[1].Trim())")
        $n++
    }
    [IO.File]::WriteAllLines($Path, $out)
    return $n
}

function Get-DorPXEMacVendor {
    param([string]$Mac)
    $oui = Get-DorPXEOui $Mac
    if (-not $oui) { return $null }
    if (-not $script:DorPXEMacVendorMap) { $script:DorPXEMacVendorMap = Get-DorPXEMacVendorList -Path (Join-Path (Get-DorPXEPath).State 'oui-map.tsv') }
    if ($script:DorPXEMacVendorMap.ContainsKey($oui)) { return $script:DorPXEMacVendorMap[$oui] }
    return $null
}

function ConvertTo-DorPXEIpBytes {
    param([Parameter(Position = 0)][string]$IP)
    if (-not $IP) { return (New-Object byte[] 4) }
    , ([Net.IPAddress]::Parse($IP)).GetAddressBytes()
}

function ConvertFrom-DorPXEIpBytes {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -ne 4) { return '0.0.0.0' }
    return ([Net.IPAddress]::new([byte[]]$Bytes)).ToString()
}

function ConvertTo-DorPXEI32 {
    param([string]$IP)
    $b = ConvertTo-DorPXEIpBytes $IP
    [uint32](($b[0] -shl 24) -bor ($b[1] -shl 16) -bor ($b[2] -shl 8) -bor $b[3])
}

function ConvertTo-DorPXEIpFromI32 {
    param([uint32]$Value)
    , ([byte[]]@(($Value -shr 24) -band 0xFF, ($Value -shr 16) -band 0xFF, ($Value -shr 8) -band 0xFF, $Value -band 0xFF))
}

function Test-DorPXEIpInRange {
    param([string]$IP, [string]$Start, [string]$End)
    $a = ConvertTo-DorPXEI32 $IP; $s = ConvertTo-DorPXEI32 $Start; $e = ConvertTo-DorPXEI32 $End
    ($a -ge $s -and $a -le $e)
}

function Test-DorPXEIpAllowed {
    param([string]$IP, $AllowList)
    if ($null -eq $AllowList -or @($AllowList).Count -eq 0) { return $true }
    foreach ($e in $AllowList) {
        if ($e -eq '*') { return $true }
        if ($e -eq $IP) { return $true }
        if ($e -match '/(\d+)$') {
            $bits = [int]$Matches[1]
            $mask = if ($bits -eq 0) { [uint32]0 } else { [uint32](0xFFFFFFFF -shl (32 - $bits)) }
            if (((ConvertTo-DorPXEI32 $IP) -band $mask) -eq ((ConvertTo-DorPXEI32 $e) -band $mask)) { return $true }
        }
    }
    return $false
}

function Get-DorPXEIPv4 {
    [CmdletBinding()]
    param([string]$BindAddress = 'auto', [string]$InterfaceAlias, [int]$CacheSeconds = 300, [switch]$Force)
    if ($BindAddress -and $BindAddress -ne 'auto') {
        $null = [Net.IPAddress]::Parse($BindAddress)
        return $BindAddress
    }
    # Get-NetAdapter/Get-NetRoute/Get-NetIPAddress custam ~1s cada (WMI/CIM): o resultado
    # e cacheado por processo para nao atrasar cada requisicao HTTP em segundos.
    $key = if ($InterfaceAlias) { $InterfaceAlias } else { '*' }
    if (-not $Force -and $script:DorPXEIPv4Cache) {
        $c = $script:DorPXEIPv4Cache[$key]
        if ($c -and ((Get-Date) - $c.At).TotalSeconds -lt $CacheSeconds) { return $c.Ip }
    }
    $candidates = New-Object System.Collections.ArrayList
    $phys = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    if ($InterfaceAlias) { $phys = @($phys | Where-Object { $_.Name -eq $InterfaceAlias -or $_.InterfaceDescription -eq $InterfaceAlias }) }
    foreach ($gw in (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -ne '0.0.0.0' } | Sort-Object -Property RouteMetric)) {
        foreach ($ip in (Get-NetIPAddress -InterfaceIndex $gw.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' })) {
            if (-not $candidates.Contains($ip.IPAddress)) { [void]$candidates.Add($ip.IPAddress) }
        }
    }
    foreach ($ad in $phys) {
        foreach ($ip in (Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' })) {
            if (-not $candidates.Contains($ip.IPAddress)) { [void]$candidates.Add($ip.IPAddress) }
        }
    }
    if ($candidates.Count -gt 0) {
        if (-not $script:DorPXEIPv4Cache) { $script:DorPXEIPv4Cache = @{} }
        $script:DorPXEIPv4Cache[$key] = @{ Ip = $candidates[0]; At = Get-Date }
        return $candidates[0]
    }
    return $null
}

function Get-DorPXEMacVendorList {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if (-not $line.Trim()) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2) { $map[$parts[0].Trim().ToUpper()] = $parts[1].Trim() }
    }
    return $map
}

function Test-DorPXEAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal $id
    $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DorPXEMimeType {
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.ipxe' { 'text/plain' }
        '.txt' { 'text/plain' }
        '.xml' { 'text/xml' }
        '.json' { 'application/json' }
        '.log' { 'text/plain' }
        '.wim' { 'application/octet-stream' }
        '.iso' { 'application/octet-stream' }
        '.esd' { 'application/octet-stream' }
        '.efi' { 'application/octet-stream' }
        '.kpxe' { 'application/octet-stream' }
        '.pxe' { 'application/octet-stream' }
        '.ttf' { 'application/octet-stream' }
        '.bcd' { 'application/octet-stream' }
        '.sdi' { 'application/octet-stream' }
        '.html' { 'text/html' }
        '.css' { 'text/css' }
        '.js' { 'application/javascript' }
        '.png' { 'image/png' }
        '.jpg' { 'image/jpeg' }
        default { 'application/octet-stream' }
    }
}

function New-DorPXEState {
    $s = [hashtable]::Synchronized(@{})
    $s['StartTime'] = Get-Date
    $s['Version'] = $script:DorPXEVersion
    $s['Stats'] = [hashtable]::Synchronized(@{
            DhcpRequests = 0; DhcpOffers = 0; DhcpDenied = 0
            TftpRequests = 0; TftpBytes = 0; TftpDenied = 0; TftpLoop = 0
            HttpRequests = 0; HttpBytes = 0; HttpDenied = 0
            Boots = 0
        })
    $s['BootLog'] = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $s['DhcpLog'] = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $s['TftpLog'] = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $s['TftpSeen'] = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $s['Pool'] = $null
    $s['Running'] = $true
    $s['Workers'] = @{}
    return $s
}

function Add-DorPXEBootLog {
    param($State, [hashtable]$Entry)
    $Entry['At'] = Get-Date
    $State.BootLog.Add($Entry)
    while ($State.BootLog.Count -gt 400) { $State.BootLog.RemoveAt(0) | Out-Null }
}

function Get-DorPXEBootLog {
    param($State, [int]$Last = 50)
    $n = [Math]::Min($Last, $State.BootLog.Count)
    if ($n -le 0) { return @() }
    @($State.BootLog[($State.BootLog.Count - $n)..($State.BootLog.Count - 1)])
}

function ConvertFrom-DorPXEQueryString {
    [CmdletBinding()]
    param([string]$Query)
    $out = @{}
    if (-not $Query) { return $out }
    if ($Query.StartsWith('?')) { $Query = $Query.Substring(1) }
    foreach ($pair in ($Query -split '&')) {
        if (-not $pair) { continue }
        $i = $pair.IndexOf('=')
        if ($i -lt 0) { $out[[Uri]::UnescapeDataString($pair)] = '' }
        else {
            $k = [Uri]::UnescapeDataString($pair.Substring(0, $i))
            $v = [Uri]::UnescapeDataString($pair.Substring($i + 1))
            $v = $v.Replace('+', ' ')
            $out[$k] = $v
        }
    }
    return $out
}

function Update-DorPXECounter {
    # Atualizacao deliberadamente sem lock: usar Monitor sobre um hashtable sincronizado
    # trava as threads do pool (o SyncRoot do wrapper e o mesmo objeto indexado pelo wrapper).
    # A contagem e apenas informativa (Health); aceitavel perder um incremento em disputa.
    param($Counters, [string]$Name, [int]$Delta = 1)
    $v = [int]$Counters[$Name] + $Delta
    if ($v -lt 0) { $v = 0 }
    $Counters[$Name] = $v
}

function Start-DorPXEPoolWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Pool)
    $idle = 40
    while ($true) {
        if ($Pool.Token.IsSet) { break }
        $item = $null
        if ($Pool.Queue.Count -gt 0) {
            try { $item = $Pool.Queue.Dequeue() } catch { $item = $null }
        }
        if ($null -eq $item) {
            if (-not $Pool.Running) { break }
            Start-Sleep -Milliseconds $idle
            continue
        }
        Update-DorPXECounter -Counters $Pool.Counters -Name Active
        Update-DorPXECounter -Counters $Pool.Counters -Name Total
        Write-DorPXELog ("worker executando: {0}" -f ($item.Code -replace '\s+', ' ')) -Level Debug -Component pool
        try {
            $sb = [scriptblock]::Create($item.Code)
            & $sb $item.Args
        }
        catch {
            $msg = "pool '$($Pool.Name)': $($_.Exception.Message)"
            $Pool.Errors.Add([pscustomobject]@{ At = Get-Date; Error = $msg })
            while ($Pool.Errors.Count -gt 50) { $Pool.Errors.RemoveAt(0) | Out-Null }
            Write-DorPXELog $msg -Level Error -Component pool
        }
        finally { Update-DorPXECounter -Counters $Pool.Counters -Name Active -Delta -1 }
    }
}

function New-DorPXERunspacePool {
    [CmdletBinding()]
    param(
        [string]$Name = 'pool',
        [int]$Min = 2,
        [int]$Max = 8,
        $BlockingScripts = @(),
        [string[]]$Libraries,
        [string]$LogFile,
        [string]$LogLevel = 'Info'
    )
    if (-not $Libraries) { $Libraries = @((Get-ChildItem -Path (Join-Path $script:DorPXELibPath '*.ps1') | ForEach-Object { $_.FullName })) }
    $pool = [pscustomobject]@{
        Name            = $Name
        Libraries       = @($Libraries)
        LogFile         = $LogFile
        LogLevel        = $LogLevel
        Min             = [Math]::Max(1, $Min)
        Max             = [Math]::Max(1, $Max)
        Queue           = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
        Counters        = [hashtable]::Synchronized(@{ Active = 0; Total = 0; Queued = 0 })
        Errors          = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        BlockingScripts = @($BlockingScripts)
        Runspaces       = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Powers          = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Handles         = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Token           = (New-Object Threading.CancellationTokenSource)
        Running         = $false
    }
    $pool | Add-Member -MemberType ScriptMethod -Name AddRunner -Value {
        param($Code, $Arguments)
        $this.Queue.Enqueue(@{ Code = $Code; Args = $Arguments; Enqueued = (Get-Date) })
        $this.Counters.Queued = $this.Queue.Count
    }
    $pool | Add-Member -MemberType ScriptMethod -Name Start -Value {
        $this.Running = $true
        $boot = ($this.Libraries | ForEach-Object { ". '$(($_ -replace "'", "''"))'" }) -join '; '
        if ($this.LogFile) { $boot += "; Set-DorPXELogTarget -File '$($this.LogFile -replace "'", "''")' -Level '$($this.LogLevel)'" }
        $threadCode = 'param($code, $x) try { & ([scriptblock]::Create($code)) $x } catch { Write-DorPXELog ("thread encerrada: " + $_.Exception.Message) -Level Error -Component thread }'
        foreach ($b in $this.BlockingScripts) {
            $rs = [runspacefactory]::CreateRunspace()
            $rs.ApartmentState = 'MTA'
            $rs.ThreadOptions = 'ReuseThread'
            $rs.Open()
            [void]$rs.SessionStateProxy.InvokeCommand.InvokeScript($false, ([scriptblock]::Create($boot)), $null)
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript($threadCode).AddArgument($b.Code).AddArgument($b.Args)
            [void]$this.Runspaces.Add($rs)
            [void]$this.Powers.Add($ps)
            [void]$this.Handles.Add($ps.BeginInvoke())
        }
        $workerCode = 'param($p) try { Write-DorPXELog "worker iniciado" -Level Debug -Component pool; Start-DorPXEPoolWorker -Pool $p } catch { Write-DorPXELog ("worker encerrado: " + $_.Exception.Message) -Level Error -Component pool }'
        for ($i = 0; $i -lt $this.Min; $i++) {
            $rs = [runspacefactory]::CreateRunspace()
            $rs.ApartmentState = 'MTA'
            $rs.ThreadOptions = 'ReuseThread'
            $rs.Open()
            [void]$rs.SessionStateProxy.InvokeCommand.InvokeScript($false, ([scriptblock]::Create($boot)), $null)
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript($workerCode).AddArgument($this)
            [void]$this.Runspaces.Add($rs)
            [void]$this.Powers.Add($ps)
            [void]$this.Handles.Add($ps.BeginInvoke())
        }
    }
    $pool | Add-Member -MemberType ScriptMethod -Name Stop -Value {
        $this.Running = $false
        try { $this.Token.Cancel() } catch { }
        foreach ($ps in $this.Powers) { try { $ps.Stop() } catch { } }
        foreach ($ps in $this.Powers) { try { $ps.Dispose() } catch { } }
        foreach ($rs in $this.Runspaces) { try { $rs.Close() } catch { } }
        foreach ($rs in $this.Runspaces) { try { $rs.Dispose() } catch { } }
    }
    return $pool
}

function Resolve-DorPXESafePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root, [AllowEmptyString()][string]$Path = '')
    $req = $Path -replace '\\', '/'
    $req = $req.TrimStart('/')
    if ($req -eq '') { return $null }
    $parts = @()
    foreach ($seg in $req.Split('/')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') { return $null }
        if ($seg -match '[:*?"<>|]') { return $null }
        $parts += $seg
    }
    if ($parts.Count -eq 0) { return $null }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $Root ($parts -join '\')))
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-Path -LiteralPath $full)) { return $null }
    return $full
}

function Add-DorPXEFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Direction = 'Inbound',
        [string]$Protocol = 'TCP',
        [int[]]$LocalPort = @(),
        [string]$Profile = 'Any',
        [switch]$Remove
    )
    Get-NetFirewallRule -DisplayName "DorPXE*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $Name } | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    if ($Remove) { return }
    $params = @{
        DisplayName = $Name
        Direction   = $Direction
        Action      = 'Allow'
        Profile     = $Profile
        Enabled     = $True
        Program     = 'Any'
    }
    if ($Protocol -eq 'TCP' -or $Protocol -eq 'UDP') {
        $params['Protocol'] = $Protocol
        if ($LocalPort.Count -gt 0) { $params['LocalPort'] = $LocalPort }
    }
    else { $params['Protocol'] = 'Any' }
    New-NetFirewallRule @params -ErrorAction Stop | Out-Null
}

function Get-DorPXEProcessOnPort {
    param([int]$Port, [string]$Protocol = 'TCP')
    try {
        if ($Protocol -eq 'TCP') {
            $conns = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        }
        else { $conns = @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) }
        foreach ($c in $conns) {
            $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if ($p) { return "$($p.ProcessName) (PID $($p.Id))" }
        }
    }
    catch { }
    return $null
}

function Test-DorPXEPortFree {
    param([int]$Port, [string]$Protocol = 'TCP')
    $inUse = $false
    try {
        if ($Protocol -eq 'TCP') {
            $s = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Tcp)
            try {
                $s.ExclusiveAddressUse = $false
                $s.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Loopback, $Port)))
                $s.Listen(1)
            }
            finally { $s.Close() }
        }
        else {
            $s = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
            try {
                $s.ExclusiveAddressUse = $false
                $s.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Loopback, $Port)))
            }
            finally { $s.Close() }
        }
    }
    catch { $inUse = $true }
    return (-not $inUse)
}

function Get-DorPXEArchBootFile {
    param([int]$Architecture)
    switch ($Architecture) {
        0 { 'ipxe\x86_64-pcbios\undionly.kpxe' }
        1 { 'ipxe\x86_64-pcbios\undionly.kpxe' }
        3 { 'ipxe\x86_64-pcbios\undionly.kpxe' }
        6 { 'ipxe\i386-efi\ipxe.efi' }
        7 { 'ipxe\x86_64-efi\ipxe.efi' }
        9 { 'ipxe\x86_64-efi\ipxe.efi' }
        10 { 'ipxe\arm64-efi\ipxe.efi' }
        11 { 'ipxe\arm64-efi\ipxe.efi' }
        15 { 'ipxe\x86_64-efi\ipxe.efi' }
        16 { 'ipxe\i386-efi\ipxe.efi' }
        18 { 'ipxe\arm64-efi\ipxe.efi' }
        default { $null }
    }
}

function Get-DorPXEArchName {
    param([int]$Architecture)
    switch ($Architecture) {
        0 { 'x86_64' } 1 { 'x86_64' } 3 { 'x86_64' }
        6 { 'i386' } 7 { 'x86_64' }
        9 { 'x86_64' }
        10 { 'arm64' } 11 { 'arm64' }
        15 { 'x86_64' } 16 { 'i386' } 18 { 'arm64' }
        default { 'x86_64' }
    }
}

function Test-DorPXEArmArchitecture {
    param([int]$Architecture)
    $Architecture -in @(10, 11, 18)
}

function Get-DorPXEUtcStamp { (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') }

function Get-DorPXESize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N1} KB' -f ($Bytes / 1KB) }
    else { "$Bytes B" }
}
