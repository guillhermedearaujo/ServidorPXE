# DorPXE 1.0.0 - configuracao (edite a mao, recarregue com -Verb Start)
#
# ATENCAO - SEGREDOS: ProductKey, Profiles[].UserPassword e Media.SetupPassword
# entram NESTA imagem. Nao versione esta imagem em repositorio publico.
# Use o prompt de credencial / GPO / gerenciador de segredos e mantenha
# estes campos vazios no arquivo.
#
@{
    Dhcp = @{
        ProxyAck = $true
        Enabled = $true
        ExtraOptions = @{}
        Mode = 'Proxy'
        BindAddress = 'auto'
        NextServer = 'auto'
    }
    Security = @{
        LoopWindowSec = 60
        MaxConcurrentTftp = 24
        LoopMax = 3
        MaxConcurrentHttp = 24
        TftpAllow = @()
        HttpAllow = @()
    }
    Server = @{
        RememberDays = 30
        AuthGroups = @('DHCP Administrators', 'DHCP Admins', 'Administrators')
        Address = 'auto'
        HttpPort = 8080
        Name = 'DOR-PXE'
        Https = $false
        TftpPort = 69
        HttpRoot = 'www'
        HttpsThumbprint = ''
    }
    WinPe = @{
        Source = 'MediaIso'
        IncludeSdi = $true
        IncludeBcd = $true
        Modes = @('Uefi')
        CustomBootWim = ''
        IncludeFonts = $true
        Architectures = @('x86_64')
        AddPowerShell = $false
    }
    Policy = @{
        Mode = 'Open'
        Devices = @()
        Prefixes = @()
        MenuProfiles = @()
        Models = @()
        DefaultAction = 'Local'
        MenuSeconds = 30
        MessageDenied = 'DorPXE: este equipamento nao esta autorizado para boot via rede.'
    }
    Log = @{
        Level = 'Info'
        KeepDays = 30
    }
    Profiles = @(@{
        SkipOOBE = $true
        ComputerName = '*'
        Scheme = 'Auto'
        ProductKey = ''
        ImageName = 'Windows 11 Pro'
        UserGroup = 'Administrators'
        Title = 'Windows 11 Pro'
        Name = 'win11pro'
        SystemSizeMB = 0
        Drivers = @()
        SkipRgc = 'Target'
        UserPassword = ''
        UserName = 'deploy'
        TimeZone = 'E. South America Standard Time'
        ImageIndex = 0
        Locale = 'pt-BR'
    })
    Media = @{
        Slug = 'win11'
        SetupUser = ''
        Iso = @()
        IsoDir = ''
        SetupPassword = ''
        SkipDynamicUpdate = $true
        ShareAuth = 'Everyone'
        KeepExtracted = $true
        Share = 'ServidorPXE'
    }
}
