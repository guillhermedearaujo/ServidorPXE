# ============================================================================
#  Auth.ps1 - autenticacao do console por usuario LOCAL do Windows
#  (modelo identico ao ByFace Vision: credencial do Windows -> sessao por cookie)
#
#  O console NAO usa mais token digitado na tela. O usuario informas o usuario e
#  a senha da conta local (ou do dominio, se a maquina estiver no AD) e recebe
#  um cookie HttpOnly assinado. Nada de senha e gravado em disco.
#
#  Autorizacao: o usuario precisa ser membro de um grupo de administracao de
#  rede (padrao: "DHCP Administrators", "DHCP Admins" ou "Administrators") OU
#  estar listado em Server.AuthUsers no config. Ajustes ficam em:
#     config\ServidorPXE.config.psd1  ->  Server.AuthGroups / Server.AuthUsers
#
#  IMPORTANTE (Windows em portugues - pt-BR):
#  o grupo local de administracao chama-se "Administradores", e NAO
#  "Administrators". Por isso a comparacao de grupo e feita por SID
#  (S-1-5-32-544), e nao pelo nome traduzido - assim o mesmo config funciona
#  em qualquer idioma do Windows.
# ============================================================================

# Sem isso o tipo PrincipalContext nao resolve e TODO login volta 401.
# Mesma linha do ByFace Vision (powershell_server\server.ps1:170).
try { Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction SilentlyContinue } catch { }

# SIDs bem conhecidos (valem em qualquer idioma do Windows).
$script:DorPXEWellKnownSids = @{
    'S-1-5-32-544' = @('Administrators', 'Administradores', 'Admin')
    'S-1-5-32-545' = @('Users', 'Usuarios')
    'S-1-5-32-546' = @('Guests', 'Convidados')
    'S-1-5-32-547' = @('Power Users', 'Usuarios Avancados')
    'S-1-5-32-548' = @('Account Operators', 'Operadores de Conta')
    'S-1-5-32-549' = @('Server Operators', 'Operadores de Servidor')
    'S-1-5-32-550' = @('Print Operators', 'Operadores de Impressao')
    'S-1-5-32-551' = @('Backup Operators', 'Operadores de Backup')
    'S-1-5-32-552' = @('Remote Desktop Users', 'Usuarios de Area de Trabalho Remota')
    'S-1-5-32-555' = @('Remote Management Users', 'Usuarios de Gerenciamento Remoto')
}

function Initialize-DorPXEAuth {
    [CmdletBinding()]
    param()
    if (-not ('System.DirectoryServices.AccountManagement.PrincipalContext' -as [type])) {
        try { Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction SilentlyContinue } catch { }
    }
    return [bool]('System.DirectoryServices.AccountManagement.PrincipalContext' -as [type])
}

function Get-DorPXEAuthOption {
    [CmdletBinding()]
    param($Config, [string]$Name, $Default)
    $v = $null
    $found = $false
    if ($Config) {
        try {
            $srv = $Config.Server
            if ($srv) {
                # a config e um Hashtable (@{} do .psd1): .PSObject.Properties
                # nao enxerga as chaves e a opcao seria SEMPRE ignorada.
                if ($srv -is [System.Collections.IDictionary]) {
                    if ($srv.Contains($Name)) { $v = $srv[$Name]; $found = $true }
                }
                elseif ($srv.PSObject.Properties[$Name]) { $v = $srv.PSObject.Properties[$Name].Value; $found = $true }
            }
        }
        catch { $v = $null; $found = $false }
    }
    if (-not $found -or $null -eq $v) { return $Default }
    return $v
}

function Get-DorPXEAuthGroups {
    [CmdletBinding()]
    param($Config)
    $g = @(Get-DorPXEAuthOption -Config $Config -Name 'AuthGroups' -Default @('DHCP Administrators', 'DHCP Admins', 'Administrators'))
    return @($g | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

function Get-DorPXEAuthUsers {
    [CmdletBinding()]
    param($Config)
    $u = @(Get-DorPXEAuthOption -Config $Config -Name 'AuthUsers' -Default @('Administrator', $env:USERNAME))
    return @($u | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
}

# Segredo de assinatura da sessao: um por instalacao, guardado em state\.
# Se o arquivo nao puder ser gravado, reaproveita o admin-token (sempre existe).
function Get-DorPXESessionSecret {
    [CmdletBinding()]
    param($Config)
    if ($script:DorPXESessionSecret) { return $script:DorPXESessionSecret }
    $file = Join-Path (Get-DorPXEPath).State 'session-secret.txt'
    $sec = $null
    if (Test-Path -LiteralPath $file) {
        try { $sec = [IO.File]::ReadAllText($file).Trim() } catch { $sec = $null }
    }
    if (-not $sec) {
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $sec = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
        try { [IO.File]::WriteAllText($file, $sec, (New-Object Text.UTF8Encoding($false))) }
        catch {
            $sec = (Get-DorPXEAdminToken -Config $Config)
            Write-DorPXELog "auth: sem state\session-secret.txt, assinatura passa a usar o admin-token" -Level Warn -Component auth
        }
    }
    $script:DorPXESessionSecret = $sec
    return $sec
}

function Get-DorPXEAuthDomain {
    [CmdletBinding()]
    param()
    try { return [string][System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().Name }
    catch { return $null }
}

function New-DorPXEPrincipalContext {
    [CmdletBinding()]
    param([ValidateSet('Domain', 'Machine')][string]$Type, [string]$Domain)
    if (-not (Initialize-DorPXEAuth)) {
        Write-DorPXELog 'auth: assembly System.DirectoryServices.AccountManagement nao carregou - nenhum login vai funcionar' -Level Error -Component auth
        return $null
    }
    try {
        if ($Type -eq 'Domain') { return New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Domain', $Domain, 'Negotiate') }
        return New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine')
    }
    catch {
        Write-DorPXELog ("auth: nao foi possivel abrir o contexto {0} ({1})" -f $Type, $_.Exception.Message) -Level Debug -Component auth
        return $null
    }
}

# 'CONTOSO\joao' / '.\joao' -> 'joao'
function ConvertFrom-DorPXEUserName {
    [CmdletBinding()]
    param([string]$Name)
    if (-not $Name) { return '' }
    $n = $Name.Trim()
    $i = $n.LastIndexOf('\')
    if ($i -ge 0) { $n = $n.Substring($i + 1) }
    return $n
}

# Compara duas palavras ignorando acentos e caixa (grupos vem traduzidos pelo
# Windows: "Administrators" no config precisa bater com "Administradores" no pt-BR).
function Test-DorPXETextEqual {
    [CmdletBinding()]
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    $fold = {
        param([string]$s)
        # FormD separa a letra do acento; basta descartar o que sobra nao-ASCII.
        ([string]$s).Trim().ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD) -replace '[^\x00-\x7F]', ''
    }
    return ((& $fold $A) -eq (& $fold $B))
}

# Normaliza um nome de grupo para SID. Resolve nomes bem conhecidos em qualquer
# idioma ("Administrators" e "Administradores" -> S-1-5-32-544) e, para grupo
# criado na rede (ex.: "DHCP Administrators"), usa a traducao do proprio Windows.
function ConvertTo-DorPXEGroupSid {
    [CmdletBinding()]
    param([string]$Name)
    if (-not $Name) { return $null }
    $n = $Name.Trim()
    if (-not $n) { return $null }
    if ($n -match '^S-1-') { return $n.ToUpperInvariant() }
    foreach ($sid in $script:DorPXEWellKnownSids.Keys) {
        foreach ($alias in $script:DorPXEWellKnownSids[$sid]) {
            if (Test-DorPXETextEqual -A $n -B $alias) { return $sid }
        }
    }
    try {
        $acc = New-Object System.Security.Principal.NTAccount($n)
        return $acc.Translate([System.Security.Principal.SecurityIdentifier]).Value.ToUpperInvariant()
    }
    catch { return $null }
}

function Test-DorPXECredential {
    [CmdletBinding()]
    param($Context, [string]$User, [string]$Password)
    if (-not $Context -or -not $User) { return $false }
    try { return [bool]$Context.ValidateCredentials($User, $Password, 'Negotiate') }
    catch {
        try { return [bool]$Context.ValidateCredentials($User, $Password) }
        catch { return $false }
    }
}

# SIDs de todos os grupos do usuario (local + global/dominio).
function Get-DorPXEUserGroupSid {
    [CmdletBinding()]
    param($Context, [string]$User)
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $Context -or -not $User) { return @() }
    if (-not (Initialize-DorPXEAuth)) { return @() }
    $up = $null
    try { $up = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($Context, $User) } catch { }
    if (-not $up) {
        # conta do dominio usa sometimes o FQDN/UPN
        try { $up = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($Context, $User, 'UserPrincipalName') } catch { }
    }
    if (-not $up) { return @() }
    # .NET Framework 4.x so expoe GetGroups() e GetGroups(PrincipalContext) -
    # as sobrecargas com GroupScope nao existem neste runtime.
    $groups = $null
    try { $groups = $up.GetGroups() } catch { $groups = $null }
    if (-not $groups) { try { $groups = $up.GetGroups($Context) } catch { $groups = $null } }
    foreach ($g in @($groups)) {
        if ($g -and $g.Sid) { $out.Add(([string]$g.Sid.Value).ToUpperInvariant()) }
    }
    return @($out | Sort-Object -Unique)
}

# O usuario pertence ao grupo? Compara por SID (funciona em qualquer idioma).
function Test-DorPXEGroupMember {
    [CmdletBinding()]
    param($Context, [string]$User, [string]$Group)
    if (-not $Context -or -not $User -or -not $Group) { return $false }
    $want = ConvertTo-DorPXEGroupSid -Name $Group
    if (-not $want) { return $false }
    $have = Get-DorPXEUserGroupSid -Context $Context -User $User
    if ($have.Count -gt 0) { return [bool](@($have) -contains $want) }
    # reserva: comparacao por nome, quando a enumeracao de SIDs nao funciona
    try {
        $up = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($Context, $User)
        if (-not $up) { return $false }
        $gp = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($Context, $Group)
        if (-not $gp) { return $false }
        return [bool]$up.IsMemberOf($gp)
    }
    catch { return $false }
}

# Vale a lista de usuarios autorizados (independente de grupo) ou qualquer grupo da lista.
function Test-DorPXEUserAuthorized {
    [CmdletBinding()]
    param($Config, [string]$User, $Context)
    if (-not $User) { return $false }
    foreach ($u in (Get-DorPXEAuthUsers -Config $Config)) {
        if ($u -and (Test-DorPXETextEqual -A $u -B $User)) { return $true }
    }
    foreach ($g in (Get-DorPXEAuthGroups -Config $Config)) {
        if (Test-DorPXEGroupMember -Context $Context -User $User -Group $g) { return $true }
    }
    return $false
}

function ConvertTo-DorPXEUnixTime {
    [CmdletBinding()]
    param([datetime]$When)
    return ([DateTimeOffset]$When).ToUnixTimeSeconds()
}

function Get-DorPXEAuthHash {
    [CmdletBinding()]
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        return ([BitConverter]::ToString($h)).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

# token = usuario|expira|assinatura(usuario|expira|segredo)
function New-DorPXESessionToken {
    [CmdletBinding()]
    param($Config, [string]$User, [switch]$Remember)
    $hours = 1
    $rm = Get-DorPXEAuthOption -Config $Config -Name 'RememberDays' -Default 30
    if ($Remember) { $hours = [Math]::Max(1, [int]$rm) * 24 }
    $exp = (Get-Date).AddHours($hours)
    $expU = ConvertTo-DorPXEUnixTime -When $exp
    $sig = Get-DorPXEAuthHash "$User|$expU|$(Get-DorPXESessionSecret -Config $Config)"
    return "$User|$expU|$sig"
}

function Get-DorPXECookieValue {
    [CmdletBinding()]
    param([string]$Header, [string]$Name)
    if (-not $Header) { return $null }
    foreach ($part in ($Header -split ';')) {
        $p = $part.Trim()
        if ($p -like ($Name + '=*')) {
            $i = $p.IndexOf('=')
            return $p.Substring($i + 1)
        }
    }
    return $null
}

# Valida o cookie e devolve o usuario autenticado (ou $null).
function Get-DorPXESessionUser {
    [CmdletBinding()]
    param($Config, $Request)
    $cookie = ''
    try { $cookie = [string]$Request.Headers['cookie'] } catch { $cookie = '' }
    $tok = Get-DorPXECookieValue -Header $cookie -Name 'dorpxe_session'
    if (-not $tok) { return $null }
    $parts = $tok.Split('|')
    if ($parts.Length -ne 3) { return $null }
    $user = $parts[0]
    $expU = 0L
    if (-not [long]::TryParse($parts[1], [ref]$expU)) { return $null }
    if ($expU -lt (ConvertTo-DorPXEUnixTime -When (Get-Date))) { return $null }
    $expected = Get-DorPXEAuthHash "$user|$($parts[1])|$(Get-DorPXESessionSecret -Config $Config)"
    if ($expected -ne $parts[2]) { return $null }
    if (-not $user) { return $null }
    return $user
}

# Autentica: tenta o dominio (AD) e depois a conta local da estacao.
# Devolve @{ Ok; User; Mode; Error }
function Invoke-DorPXEAuthenticate {
    [CmdletBinding()]
    param($Config, [string]$User, [string]$Password)
    $u = ConvertFrom-DorPXEUserName -Name $User
    if (-not $u -or -not $Password) {
        return [pscustomobject]@{ Ok = $false; User = $u; Mode = $null; Error = 'informe usuario e senha' }
    }
    $okUser = $null
    $okMode = $null
    $okCtx = $null
    $ctxLocal = $null
    $ctxDom = $null
    $dom = Get-DorPXEAuthDomain
    if ($dom) {
        $ctx = New-DorPXEPrincipalContext -Type Domain -Domain $dom
        if ($ctx) {
            $ctxDom = $ctx
            if (Test-DorPXECredential -Context $ctx -User $u -Password $Password) { $okUser = $u; $okMode = 'Domain'; $okCtx = $ctx; $ctxDom = $null }
        }
    }
    if (-not $okUser) {
        $ctxLocal = New-DorPXEPrincipalContext -Type Machine
        if ($ctxLocal -and (Test-DorPXECredential -Context $ctxLocal -User $u -Password $Password)) { $okUser = $u; $okMode = 'Local'; $okCtx = $ctxLocal; $ctxLocal = $null }
    }
    foreach ($c in @($ctxDom, $ctxLocal)) { if ($c) { try { $c.Dispose() } catch { } } }
    if (-not $okUser) {
        # sem nenhum contexto o Windows nem chegou a conferir a senha: dizer
        # "senha invalida" esconderia o problema real.
        if (-not (Initialize-DorPXEAuth)) {
            Write-DorPXELog 'auth: sem o assembly AccountManagement, a credencial do Windows nao pode ser conferida' -Level Error -Component auth
            return [pscustomobject]@{ Ok = $false; User = $u; Mode = $null; Error = 'nao foi possivel consultar as contas do Windows neste servidor' }
        }
        return [pscustomobject]@{ Ok = $false; User = $u; Mode = $null; Error = 'usuario ou senha invalidos' }
    }
    if (-not (Test-DorPXEUserAuthorized -Config $Config -User $u -Context $okCtx)) {
        $grupos = (Get-DorPXEAuthGroups -Config $Config) -join ', '
        try { $okCtx.Dispose() } catch { }
        return [pscustomobject]@{ Ok = $false; User = $u; Mode = $okMode; Error = "sem permissao: entre em um destes grupos ($grupos) ou em Server.AuthUsers" }
    }
    try { $okCtx.Dispose() } catch { }
    return [pscustomobject]@{ Ok = $true; User = $u; Mode = $okMode; Error = $null }
}

# Trava simples contra forca bruta: 8 erros em 5 min bloqueia por 2 min.
function Test-DorPXEAuthThrottle {
    [CmdletBinding()]
    param()
    if (-not $script:DorPXEAuthFails) { return $true }
    $now = Get-Date
    $f = @($script:DorPXEAuthFails | Where-Object { ($now - $_.At).TotalMinutes -lt 5 })
    $script:DorPXEAuthFails = $f
    if ($f.Count -ge 8) {
        $last = ($f | Sort-Object At | Select-Object -Last 1).At
        if (($now - $last).TotalSeconds -lt 120) { return $false }
        $script:DorPXEAuthFails = @()
    }
    return $true
}

function Add-DorPXEAuthFailure {
    [CmdletBinding()]
    param()
    if (-not $script:DorPXEAuthFails) { $script:DorPXEAuthFails = @() }
    $script:DorPXEAuthFails += [pscustomobject]@{ At = (Get-Date) }
}
