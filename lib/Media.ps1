function Get-DorPXEGenericKey {
    param([string]$ImageName)
    if (-not $ImageName) { return $null }
    $keys = @{
        'Windows 11 Pro'                      = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        'Windows 11 Pro N'                    = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        'Windows 11 Pro Education'            = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        'Windows 11 Pro for Workstations'     = 'TGCKF-N8MWG-2J8JG-P2JPT-F86Q2'
        'Windows 11 Pro for Enterprise'       = 'TGCKF-N8MWG-2J8JG-P2JPT-F86Q2'
        'Windows 11 Enterprise'               = 'TGCKF-N8MWG-2J8JG-P2JPT-F86Q2'
        'Windows 11 Home'                     = 'S-1-5-21-XXXXX-XXXXX-XXXXX-XXXXX'
        'Windows 11 Home N'                   = 'S-1-5-21-XXXXX-XXXXX-XXXXX-XXXXX'
        'Windows 11 Education'                = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        'Windows 10 Pro'                      = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        'Windows 10 Pro N'                    = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        'Windows 10 Enterprise'               = 'TGCKF-N8MWG-2J8JG-P2JPT-F86Q2'
        'Windows 10 Education'                = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
    }
    foreach ($k in $keys.Keys) {
        if ($ImageName -like "*$k*") { return $keys[$k] }
    }
    return $null
}

function Get-DorPXEShareUnc {
    [CmdletBinding()]
    param($Config)
    $ip = if ($Config.Server.Address -and $Config.Server.Address -ne 'auto') { $Config.Server.Address } else { Get-DorPXEIPv4 -BindAddress $Config.Dhcp.BindAddress }
    return "\\$ip\$($Config.Media.Share)"
}

function Get-DorPXEMediaRoot {
    [CmdletBinding()]
    param()
    Join-Path (Get-DorPXEPath).Www '_dorpxe\media'
}

# Diretorio de trabalho do WinPE quando WinPe.Source = 'MediaIso':
#   1) boot.wim ja extraido da ISO (www\_dorpxe\media\<slug>\sources\boot.wim)
#   2) a propria ISO configurada (Build-Media monta e extrai)
#   3) a pasta informada em Media.IsoDir
function Get-DorPXEMediaBootWimDir {
    [CmdletBinding()]
    param($Config)
    if (-not $Config) { $Config = Import-DorPXEConfig }
    $root = Get-DorPXEMediaRoot
    $best = $null
    $slug = [string]$Config.Media.Slug
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    # a midia configurada tem prioridade sobre as demais
    if ($slug) { $dirs = @($dirs | Sort-Object @{ e = { if ($_.Name -eq $slug) { 0 } else { 1 } } }, Name) }
    foreach ($slugDir in $dirs) {
        foreach ($rel in @('sources\boot.wim', 'winpe\boot.wim', 'boot.wim')) {
            $c = Join-Path $slugDir.FullName $rel
            if (Test-Path -LiteralPath $c -PathType Leaf) { if (-not $best) { $best = $c } }
        }
    }
    if ($best) { return $best }
    foreach ($i in @($Config.Media.Iso)) {
        if (-not $i) { continue }
        $dir = if (Test-Path -LiteralPath $i -PathType Container) { $i } else { Split-Path -Parent $i }
        if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) { return $dir }
    }
    $d = [string]$Config.Media.IsoDir
    if ($d -and (Test-Path -LiteralPath $d -PathType Container)) { return $d }
    return $null
}

function Get-DorPXEMediaSource {
    [CmdletBinding()]
    param($Config, [string]$Slug)
    if (-not $Slug) { $Slug = $Config.Media.Slug }
    return (Join-Path (Join-Path (Get-DorPXEMediaRoot) ('media\' + $Slug)) 'sources')
}

function Get-DorPXEImageNames {
    [CmdletBinding()]
    param([string]$InstallWim)
    $out = @()
    try {
        foreach ($i in (Get-WindowsImage -ImagePath $InstallWim -ErrorAction Stop)) {
            $out += [pscustomobject]@{ Index = $i.ImageIndex; Name = $i.ImageName; Arch = $i.Architecture; Lang = $i.ImageType }
        }
    }
    catch { Write-DorPXELog "Media: nao foi possivel ler '$InstallWim' - $($_.Exception.Message)" -Level Error -Component media }
    return $out
}

function Resolve-DorPXEInstallImage {
    [CmdletBinding()]
    param($Config, $Profile)
    $src = Get-DorPXEMediaSource -Config $Config
    $file = $null
    foreach ($n in @('install.wim', 'install.esd', 'install.swm')) {
        $c = Join-Path $src $n
        if (Test-Path -LiteralPath $c) { $file = $c; break }
    }
    if (-not $file) { throw "Media: nenhum install.wim/esd em '$src'. Rode: .\ServidorPXE.ps1 Build-Media -Iso 'D:\...\Win11_24H2.iso'" }
    if ($Profile.ImageIndex -gt 0) { return [pscustomobject]@{ Path = $file; Index = [int]$Profile.ImageIndex; Key = '/IMAGE/INDEX'; Value = [string]$Profile.ImageIndex; Name = $Profile.ImageName } }
    $names = Get-DorPXEImageNames -InstallWim $file
    $hit = $names | Where-Object { $_.Name -eq $Profile.ImageName } | Select-Object -First 1
    if (-not $hit) { $hit = $names | Where-Object { $_.Name -like "*$($Profile.ImageName)*" } | Select-Object -First 1 }
    if (-not $hit) {
        throw "Media: imagem '$($Profile.ImageName)' nao encontrada em '$file'. Disponiveis: $((($names | ForEach-Object { "$($_.Index)=$($_.Name)" }) -join ', '))"
    }
    return [pscustomobject]@{ Path = $file; Index = $hit.Index; Key = '/IMAGE/NAME'; Value = $hit.Name; Name = $hit.Name }
}

function Get-DorPXEPartitionXml {
    [CmdletBinding()]
    param([ValidateSet('Uefi', 'Bios')][string]$Mode, [int]$SystemSizeMB)
    if ($Mode -eq 'Uefi') {
        $efi = if ($SystemSizeMB -gt 0) { $SystemSizeMB } else { 260 }
        return @"
<CreatePartitions>
  <CreatePartition wcm:action="add"><Order>1</Order><Size>$efi</Size><Type>EFI</Type></CreatePartition>
  <CreatePartition wcm:action="add"><Order>2</Order><Size>16</Size><Type>MSR</Type></CreatePartition>
  <CreatePartition wcm:action="add"><Order>3</Order><Extend>true</Extend><Type>Primary</Type></CreatePartition>
</CreatePartitions>
<ModifyPartitions>
  <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Label>EFI</Label><Format>FAT32</Format><Active>true</Active></ModifyPartition>
  <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Label>MSR</Label></ModifyPartition>
  <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Label>Windows</Label><Format>NTFS</Format><Letter>C</Letter></ModifyPartition>
</ModifyPartitions>
"@
    }
    $sys = if ($SystemSizeMB -gt 0) { $SystemSizeMB } else { 500 }
    return @"
<CreatePartitions>
  <CreatePartition wcm:action="add"><Order>1</Order><Size>$sys</Size><Type>Primary</Type></CreatePartition>
  <CreatePartition wcm:action="add"><Order>2</Order><Extend>true</Extend><Type>Primary</Type></CreatePartition>
</CreatePartitions>
<ModifyPartitions>
  <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Label>System</Label><Format>NTFS</Format><Active>true</Active></ModifyPartition>
  <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Label>Windows</Label><Format>NTFS</Format><Letter>C</Letter></ModifyPartition>
</ModifyPartitions>
"@
}

function New-DorPXEUnattendXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Image,
        [ValidateSet('Uefi', 'Bios')][string]$Mode = 'Uefi',
        [string]$Unc
    )
    if (-not $Unc) { $Unc = Get-DorPXEShareUnc -Config $Config }
    $source = "$Unc\media\$($Config.Media.Slug)\sources"
    $self = "$Unc\profiles\$($Profile.Name)\autounattend.xml"
    $layout = Get-DorPXEPartitionXml -Mode $Mode -SystemSizeMB $Profile.SystemSizeMB
    $create = $layout.Substring(0, $layout.IndexOf('<ModifyPartitions>')).Trim()
    $modify = $layout.Substring($layout.IndexOf('<ModifyPartitions>')).Trim()
    $key = if ($Profile.ProductKey) { $Profile.ProductKey } else { Get-DorPXEGenericKey -ImageName $Image.Name }
    $keyXml = ''
    if ($key -and $key -notlike 'S-1-5-21*') {
        $keyXml = "<ProductKey><Key>$key</Key></ProductKey>"
    }
    $pass = (Get-DorPXEModePass -Mode $Mode)
    $arch = if ($pass) { 'amd64' } else { 'x86' }
    $oobe = '<OOBE><HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC>'
    if ($Profile.SkipOOBE) { $oobe += '<SkipMachineOOBE>true</SkipMachineOOBE>' }
    $oobe += '</OOBE>'
    $account = ''
    if ($Profile.UserName) {
        $pw = ''
        if ($Profile.UserPassword) {
            $pw = '<Password><Value>' + ([Security.SecurityElement]::Escape($Profile.UserPassword)) + '</Value><PlainText>true</PlainText></Password>'
        }
        $account = "<LocalAccount wcm:action=`"add`"><Group>$($Profile.UserGroup)</Group><Name>$($Profile.UserName)</Name>$pw</LocalAccount>"
    }
    $tz = $Profile.TimeZone
    $locale = $Profile.Locale
    $name = $Profile.ComputerName
    $dyn = if ($Config.Media.SkipDynamicUpdate) { '<DynamicUpdate><Enable>false</Enable><Source>None</Source></DynamicUpdate>' } else { '<DynamicUpdate><Source>WindowsUpdate</Source></DynamicUpdate>' }
    $imgMeta = if ($Image.Key -eq '/IMAGE/NAME') { "/IMAGE/NAME" } else { "/IMAGE/INDEX" }
    $imgVal = [Security.SecurityElement]::Escape($Image.Value)
    $drivePaths = ''
    if (@($Profile.Drivers).Count -gt 0) {
        $items = ''
        foreach ($d in $Profile.Drivers) {
            $items += "<DriverAndOEMScripts><PathAndCredentials wcm:action=`"add`"><Path>$([Security.SecurityElement]::Escape($d))</Path></PathAndCredentials></DriverAndOEMScripts>"
        }
        $drivePaths = "<DriverPaths>$items</DriverPaths>"
    }

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="$arch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage><UILanguage>$locale</UILanguage></SetupUILanguage>
      <InputLocale>$locale</InputLocale>
      <SystemLocale>$locale</SystemLocale>
      <UILanguage>$locale</UILanguage>
      <UserLocale>$locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="$arch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          $create
          $modify
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>$imgMeta</Key><Value>$imgVal</Value></MetaData>
            <UnattendSourcePath>$self</UnattendSourcePath>
          </InstallFrom>
          <InstallToAvailablePartition>false</InstallToAvailablePartition>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      $drivePaths
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>ServidorPXE</FullName>
        <Organization>ServidorPXE</Organization>
      </UserData>
      $dyn
      $keyXml
      <Restart>Reboot</Restart>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$arch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>$name</ComputerName>
      <TimeZone>$tz</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$arch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      $oobe
      <UserAccounts><LocalAccounts>$account</LocalAccounts></UserAccounts>
      <RegisteredOrganization>ServidorPXE</RegisteredOrganization>
    </component>
  </settings>
</unattend>
"@
    return $xml
}

function Get-DorPXEModePass {
    [CmdletBinding()]
    param([string]$Mode)
    return ($Mode -eq 'Uefi')
}

function New-DorPXEStartNetCmd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Profile,
        [string]$Unc
    )
    if (-not $Unc) { $Unc = Get-DorPXEShareUnc -Config $Config }
    $media = "$Unc\media\$($Config.Media.Slug)\sources"
    $unatt = "$Unc\profiles\$($Profile.Name)\autounattend.xml"
    $setup = "$media\sources\setup.exe"
    $lines = @(
        '@echo off',
        'title ServidorPXE - instalando ' + $Profile.Title,
        'wpeinit',
        'echo.',
        'echo [ServidorPXE] perfil : ' + $Profile.Title,
        'echo [ServidorPXE] midia  : ' + $media,
        'echo.',
        'net use Y: ' + $Unc + ' /persistent:no',
        'if errorlevel 1 goto semmedia',
        'echo [ServidorPXE] iniciando o Windows Setup...',
        'echo.',
        ('"' + $setup + '" /source:' + $media + ' /unattend:' + $unatt),
        'if errorlevel 1 goto falhou',
        'exit /b 0',
        ':semmedia',
        'echo.',
        'echo [ServidorPXE] FALHA: nao foi possivel montar ' + $Unc,
        'echo [ServidorPXE] verifique o compartilhamento e as credenciais.',
        'pause',
        'exit /b 1',
        ':falhou',
        'echo.',
        'echo [ServidorPXE] FALHA: o Windows Setup retornou erro.',
        'pause',
        'exit /b 1'
    )
    return (($lines -join "`r`n") + "`r`n")
}

function Get-DorPXEWinPeBase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$Arch = 'x86_64'
    )
    $cands = New-Object System.Collections.Generic.List[string]
    $src = $Config.WinPe.Source
    if ($src -eq 'MediaIso') { $src = Get-DorPXEMediaBootWimDir -Config $Config }
    if ($src) {
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            if ([IO.Path]::GetFileName($src).ToLowerInvariant() -eq 'boot.wim') { $cands.Add((Resolve-Path -LiteralPath $src).Path) }
        }
        elseif (Test-Path -LiteralPath $src -PathType Container) {
            $hits = Get-ChildItem -LiteralPath $src -Filter 'boot.wim' -Recurse -ErrorAction SilentlyContinue
            foreach ($h in $hits) {
                if ($Arch -eq 'x86_64' -and $h.FullName -match '(?i)amd64|x64|x86_64') { $cands.Insert(0, $h.FullName) }
                else { $cands.Add($h.FullName) }
            }
        }
    }
    $roots = @(
        "$env:ProgramFiles(x86)\Windows Kits\10\Deployment Tools",
        "$env:ProgramFiles\Windows Kits\10\Deployment Tools"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($r in $roots) {
        $want = if ($Arch -eq 'x86_64') { 'AMD64' } elseif ($Arch -eq 'i386') { 'x86' } else { 'ARM64' }
        $p = Join-Path $r (Join-Path $want 'WindowsPE')
        if (Test-Path -LiteralPath $p) {
            foreach ($h in (Get-ChildItem -LiteralPath $p -Filter 'boot.wim' -Recurse -ErrorAction SilentlyContinue)) { $cands.Add($h.FullName) }
        }
    }
    foreach ($c in $cands) {
        try {
            $img = Get-WindowsImage -ImagePath $c -Index 1 -ErrorAction Stop
            $a = ([string]$img.Architecture).ToLowerInvariant()
            if ($Arch -eq 'x86_64' -and $a -in @('x64')) { return $c }
            if ($Arch -eq 'i386' -and $a -in @('x86')) { return $c }
            if ($Arch -eq 'arm64' -and $a -in @('arm64')) { return $c }
        }
        catch { }
    }
    return $null
}

function Expand-DorPXEMediaIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Iso,
        [Parameter(Mandatory = $true)][string]$Target,
        [switch]$Minimal
    )
    if (-not (Test-Path -LiteralPath $Iso -PathType Leaf)) { throw "ISO nao encontrada: '$Iso'" }
    $img = Mount-DiskImage -ImagePath $Iso -Access ReadOnly -PassThru -ErrorAction Stop
    try {
        $vol = $img | Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Select-Object -First 1
        if (-not $vol) { throw "Nao foi possivel montar a ISO '$Iso'" }
        $src = "$($vol.DriveLetter):\"
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        Write-DorPXELog "Media: copiando conteudo de $src para $Target" -Level Info -Component media
        if ($Minimal) {
            foreach ($sub in @('sources', 'efi', 'boot', 'bootmgr', 'bootmgr.efi')) {
                $p = Join-Path $src $sub
                if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $Target -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
        else {
            Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $Target -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath (Join-Path $Target 'sources')) {
            $u = Join-Path (Join-Path $Target 'sources') 'sources\setup.exe'
            if (-not (Test-Path -LiteralPath $u)) { Write-DorPXELog "Media: AVISO - 'sources\sources\setup.exe' ausente; o startnet usara 'sources\setup.exe'" -Level Warn -Component media }
        }
    }
    finally {
        try { Dismount-DiskImage -ImagePath $Iso | Out-Null } catch { }
    }
}

function Copy-DorPXEWinPeBoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BaseWim,
        [Parameter(Mandatory = $true)][string]$SharedDir,
        $Config
    )
    New-Item -ItemType Directory -Path $SharedDir -Force | Out-Null
    $mount = Join-Path (Get-DorPXEPath).State 'mount-boot'
    New-Item -ItemType Directory -Path $mount -Force | Out-Null
    $vol = $null
    try {
        $vol = Mount-WindowsImage -ImagePath $BaseWim -Index 1 -ScratchDirectory $mount -ErrorAction Stop
        $dst = Join-Path $SharedDir ''
        $items = @{
            'BCD'         = 'BCD'
            'bootmgr'     = 'bootmgr'
            'bootmgr.efi' = 'bootmgr.efi'
        }
        foreach ($k in $items.Keys) {
            $p = Join-Path $vol $k
            if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dst -Force }
        }
        $sdi = Join-Path $vol 'Windows\Boot\Resources\boot.sdi'
        if (Test-Path -LiteralPath $sdi) { Copy-Item -LiteralPath $sdi -Destination $dst -Force }
        $fonts = Join-Path $vol 'Windows\Boot\Fonts'
        $fdst = Join-Path $dst 'Fonts'
        New-Item -ItemType Directory -Path $fdst -Force | Out-Null
        if (Test-Path -LiteralPath $fonts) {
            foreach ($f in @('segmono_boot.ttf', 'segoe_slboot.ttf', 'segoeui_slboot.ttf', 'wgl4_boot.ttf')) {
                $p = Join-Path $fonts $f
                if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $fdst -Force }
            }
        }
        if ($Config -and $Config.WinPe.IncludePowerShell) {
            $ps = Join-Path $vol 'Windows\System32\WindowsPowerShell'
            if (-not (Test-Path -LiteralPath $ps)) { Write-DorPXELog 'Media: WinPe.AddPowerShell exige um boot.wim do ADK com Windows PowerShell (Oc)' -Level Warn -Component media }
        }
    }
    finally {
        # -Save e -Discard sao mutuamente exclusivos. O boot.wim de origem (ADK ou ISO)
        # nao deve ser alterado por este build: descartamos as alteracoes.
        if ($vol) { try { Dismount-WindowsImage -ImagePath $BaseWim -Discard -ErrorAction SilentlyContinue | Out-Null } catch { } }
    }
}

function Build-DorPXEProfileWinPe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)][string]$BaseWim,
        [Parameter(Mandatory = $true)][ValidateSet('Uefi', 'Bios')][string]$Mode,
        [string[]]$Architectures = @('x86_64')
    )
    $p = Get-DorPXEPath
    $enc = New-Object Text.UTF8Encoding($false)
    $unattXml = $null
    $startNet = New-DorPXEStartNetCmd -Config $Config -Profile $Profile
    $built = @()
    foreach ($arch in $Architectures) {
        $image = Resolve-DorPXEInstallImage -Config $Config -Profile $Profile
        if ($unattXml -eq $null) { $unattXml = New-DorPXEUnattendXml -Config $Config -Profile $Profile -Image $image -Mode $Mode }
        $dir = Join-Path $p.WinPe (Join-Path ('profiles\' + $Profile.Name) $Mode)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # x86_64 (arquitetura primaria) publica em boot.wim; as demais em boot.<arch>.wim,
        # para que uma segunda arquitetura nao sobrescreva a primeira.
        $dst = if ($arch -eq 'x86_64') { Join-Path $dir 'boot.wim' } else { Join-Path $dir ('boot.' + $arch + '.wim') }
        Copy-Item -LiteralPath $BaseWim -Destination $dst -Force
        $mount = Join-Path $p.State ('mount-' + $Profile.Name)
        New-Item -ItemType Directory -Path $mount -Force | Out-Null
        $vol = $null
        try {
            $vol = Mount-WindowsImage -ImagePath $dst -Index 1 -ScratchDirectory $mount -ErrorAction Stop
            $panther = Join-Path $vol 'Windows\Panther'
            New-Item -ItemType Directory -Path $panther -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $panther 'unattend.xml'), $unattXml, $enc)
            [IO.File]::WriteAllText((Join-Path $panther 'autounattend.xml'), $unattXml, $enc)
            [IO.File]::WriteAllText((Join-Path $vol 'startnet.cmd'), $startNet, [Text.Encoding]::ASCII)
            $sys = Join-Path $vol 'Windows\System32'
            [IO.File]::WriteAllText((Join-Path $sys 'startnet.cmd'), $startNet, [Text.Encoding]::ASCII)
            $logo = Join-Path $p.Www 'logo.bmp'
            if (Test-Path -LiteralPath $logo) { Copy-Item -LiteralPath $logo -Destination (Join-Path $vol 'Windows\Web\Wallpaper\Windows\img0.jpg') -Force -ErrorAction SilentlyContinue }
            Dismount-WindowsImage -ImagePath $dst -Save | Out-Null
            $vol = $null
            $built += $dst
            Write-DorPXELog ("Media: perfil '{0}' ({1}, {2}) -> {3} ({4:N0} bytes)" -f `
                    $Profile.Name, $arch, $Mode, $dst, (Get-Item -LiteralPath $dst).Length) -Level Info -Component media
        }
        finally {
            if ($vol) { try { Dismount-WindowsImage -ImagePath $dst -Save -ErrorAction SilentlyContinue | Out-Null } catch { } }
        }
    }
    return $built
}

function New-DorPXEProfileFolder {
    [CmdletBinding()]
    param($Config, $Profile)
    $dir = Join-Path (Get-DorPXEMediaRoot) ('profiles\' + $Profile.Name)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Build-DorPXEMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string[]]$Iso,
        [ValidateSet('Uefi', 'Bios')][string[]]$Modes = @('Uefi'),
        [string[]]$Architectures = @('x86_64'),
        [switch]$Minimal,
        [switch]$SkipIso
    )
    if (-not (Test-DorPXEAdmin)) { throw 'Build-Media exige PowerShell como administrador (Mount-DiskImage / DISM).' }
    $p = Get-DorPXEPath
    $isos = @($Iso)
    if ($isos.Count -eq 0) { $isos = @($Config.Media.Iso) }
    if ($isos.Count -eq 0) { throw 'Informe -Iso "C:\...\Win11.iso" ou defina Media.Iso no config.' }
    $slug = $Config.Media.Slug
    $target = Join-Path (Get-DorPXEMediaRoot) ('media\' + $slug)

    if (-not $SkipIso) {
        foreach ($i in $isos) {
            $name = [IO.Path]::GetFileNameWithoutExtension($i)
            $t = if ($isos.Count -eq 1) { $target } else { (Join-Path (Get-DorPXEMediaRoot) ('media\' + $name)) }
            Expand-DorPXEMediaIso -Iso $i -Target $t -Minimal:$Minimal
            $Config.Media.Slug = [IO.Path]::GetFileName($t).Trim()
        }
        $slug = $Config.Media.Slug
    }
    $src = Get-DorPXEMediaSource -Config $Config
    if (-not (Test-Path -LiteralPath (Join-Path $src 'install.wim'))) { throw "Media: 'install.wim' nao encontrado em '$src' apos a extracao." }

    $profiles = Get-DorPXEProfiles -Config $Config
    if ($profiles.Count -eq 0) { throw 'Media: nenhum perfil configurado.' }
    foreach ($pr in $profiles) {
        $img = Resolve-DorPXEInstallImage -Config $Config -Profile $pr
        Write-DorPXELog ("Media: perfil '{0}' -> imagem {1} '{2}' (indice {3})" -f $pr.Name, $img.Key, $img.Name, $img.Index) -Level Info -Component media
        $pf = New-DorPXEProfileFolder -Config $Config -Profile $pr
        $xml = New-DorPXEUnattendXml -Config $Config -Profile $pr -Image $img -Mode $Modes[0]
        $enc = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $pf 'autounattend.xml'), $xml, $enc)
        [IO.File]::WriteAllText((Join-Path $pf 'unattend.xml'), $xml, $enc)
        foreach ($mode in $Modes) {
            foreach ($arch in $Architectures) {
                $base = Get-DorPXEWinPeBase -Config $Config -Arch $arch
                if (-not $base) { Write-DorPXELog "Media: AVISO - nenhum boot.wim WinPE encontrado para $arch (defina WinPe.Source). O perfil $($pr.Name) nao sera publicado para $arch." -Level Warn -Component media; continue }
                $shared = Join-Path $p.WinPe (Join-Path 'shared' $mode)
                $marker = Join-Path $shared 'BCD'
                if (-not (Test-Path -LiteralPath $marker)) {
                    Copy-DorPXEWinPeBoot -BaseWim $base -SharedDir $shared -Config $Config
                }
                Build-DorPXEProfileWinPe -Config $Config -Profile $pr -BaseWim $base -Mode $mode -Architectures @($arch) | Out-Null
            }
        }
    }
    $unc = Get-DorPXEShareUnc -Config $Config
    $info = @(
        'ServidorPXE ' + (Get-DorPXEVersion),
        'compartilhamento : ' + $unc,
        'midia           : ' + "$unc\media\$slug\sources",
        'perfis          : ' + (($profiles | ForEach-Object { "$($_.Name) -> $unc\profiles\$($_.Name)\autounattend.xml" }) -join '; '),
        'gerado          : ' + (Get-Date).ToString('s')
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path (Get-DorPXEMediaRoot) 'smb.txt'), $info, (New-Object Text.UTF8Encoding($false)))
    Write-DorPXELog "Media: concludedo. $unc" -Level Info -Component media
    return [pscustomobject]@{
        Source      = $src
        Unc         = $unc
        Profiles    = @($profiles | ForEach-Object { $_.Name })
        Modes       = $Modes
        Architectures = $Architectures
    }
}

function Write-DorPXEAutoExec {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)
    $p = Get-DorPXEPath
    $text = Get-DorPXEAutoExecScript -Config $Config
    $enc = New-Object Text.UTF8Encoding($false)
    $targets = @((Join-Path $p.Www 'autoexec.ipxe'))
    foreach ($d in @('x86_64-pcbios', 'x86_64-efi', 'i386-efi', 'arm64-efi')) {
        $t = Join-Path (Join-Path $p.Www 'ipxe') (Join-Path $d 'autoexec.ipxe')
        if (Test-Path -LiteralPath (Split-Path -Parent $t)) { $targets += $t }
    }
    foreach ($t in $targets) { [IO.File]::WriteAllText($t, $text, $enc) }
    Write-DorPXELog ("Media: autoexec.ipxe gerado em {0} arquivo(s)" -f $targets.Count) -Level Info -Component media
    return $targets
}
