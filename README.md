# ServidorPXE

Servidor PXE nativo para Windows, escrito em **PowerShell 5.1**, sem
dependencias externas. Ele faz o boot pela rede de um Windows 11 ja instalado
na maquina, direto do iPXE + WinPE, e traz um console web para gerenciar
midia, politica e dispositivos.

- **Proxy DHCP** (UDP/67) - convive com o DHCP corporativo, sem sequestrar a
  rede.
- **TFTP** (UDP/69) - entrega os binarios do iPXE e o wimboot.
- **HTTP** (porta 8080) - serve o script de boot, a midia e o console.
- **Console web** de duas abas, com **login de usuario Windows**.

Licenca **GPL-3.0**. Sem dependencias para instalar: so Windows PowerShell.

> Um servidor para instalacao de imagens `.iso` via IPv4, para os ativos
> inicializarem simultaneamente.

> ### Status: versao 1.0 em amadurecimento
>
> O codigo e os testes rodam em Windows 11 (PowerShell 5.1), mas **o boot em si
> ainda nao foi validado em hardware real**: falta uma ISO do Windows 11, o
> Windows ADK e um cliente PXE de verdade. O que ja foi exercitado: proxy DHCP
> e TFTP em rede real, console web, login com usuario do Windows, politica de
> boot, cadastro de dispositivos e os 154 testes automatizados.
>
> **Nao use em producao antes de validar o boot completo num equipamento de
> teste.**

---

## Sumario

- [Requisitos](#requisitos)
- [Instalacao rapida](#instalacao-rapida)
- [Como usar o console](#como-usar-o-console)
- [Comandos](#comandos)
- [Politica de boot](#politica-de-boot)
- [Modo corporativo (proxy DHCP)](#modo-corporativo-proxy-dhcp)
- [Seguranca](#seguranca)
- [Estrutura do projeto](#estrutura-do-projeto)
- [Logs e diagnostico](#logs-e-diagnostico)
- [Padrao Git](#padrao-git)
- [Solucao de problemas](#solucao-de-problemas)
- [Licenca](#licenca)

---

## Requisitos

| Item | Detalhe |
| --- | --- |
| Sistema | Windows 10/11 ou Windows Server 2016+ |
| PowerShell | 5.1 (o que ja vem no Windows) - **nao precisa instalar nada** |
| Privilegio | Administrador, para UDP/67, UDP/69, firewall, URLACL e share SMB |
| Rede | Interface com o IP da rede que voce quer atender |
| Imagem | ISO do Windows 11 (necessaria apenas para a etapa de Midia) |
| Portas | 8080 (HTTP), 69 e 67 (TFTP/DHCP, apenas se for o unico DHCP) |

> O projeto **abre e opera sem ISO**. Nesse caso a aba Midia mostra avisos
> guiados e o console continua funcionando normalmente.

---

## Instalacao rapida

O caminho mais simples e o `iniciar.bat`: ele pede elevacao, ajusta a Execution
Policy, remove o Mark of the Web, cria as pastas e sobe o servico.

```bat
iniciar.bat
```

Menu do `iniciar.bat`:

| Opcao | O que faz |
| --- | --- |
| `1` | Iniciar em segundo plano (recomendado) |
| `2` | Iniciar em primeiro plano (logs na tela, `Ctrl+C` para sair) |
| `3` | Reiniciar |
| `4` | Parar |
| `5` | Status |
| `6` | Health (testa HTTP, TFTP e DHCP) |
| `7` | Abrir o console web no navegador |
| `8` | Dispositivos cadastrados |
| `9` | Testes |
| `10` | Instalar (firewall, URLACL, tarefa agendada) |
| `11` | Ver os ultimos logs |
| `12` | Preparar ambiente (Execution Policy) |
| `0` | Sair |

O mesmo script aceita um comando direto, util para atalhos e Task Scheduler:

```bat
iniciar.bat iniciar        iniciar.bat parar        iniciar.bat reiniciar
iniciar.bat status         iniciar.bat health       iniciar.bat console
iniciar.bat dispositivos   iniciar.bat testes       iniciar.bat logs
iniciar.bat instalar       iniciar.bat preparar
```

Variaveis de ambiente uteis:

| Variavel | Efeito |
| --- | --- |
| `DORPXE_SKIP_ELEVATE=1` | Nao pede elevacao (diagnostico) |
| `DORPXE_SKIP_PREPARE=1` | Pula a preparacao do ambiente |
| `PORT=8080` | Porta HTTP usada pelo `.bat` |

Instalacao manual, sem o `.bat`:

```powershell
# 1) Estrutura de pastas e config
.\ServidorPXE.ps1 Init

# 2) Firewall, URLACL, share SMB e inicializacao automatica
.\ServidorPXE.ps1 Install

# 3) Apontar a ISO e montar o WinPE
.\ServidorPXE.ps1 Build-Media -Iso 'D:\ISOs\Win11_24H2_English.iso'

# 4) Subir
.\ServidorPXE.ps1 Start
```

O `Install` aceita `-Mode ScheduledTask` (padrao), `StartupFolder`, `Service` ou
`None`, e desliga etapas individuais com `-NoFirewall`, `-NoUrlAcl` e `-NoShare`.

O console fica em:

```
http://127.0.0.1:8080/pxe/admin      # na propria maquina
http://192.168.1.3:8080/pxe/admin    # de outra maquina da rede
```

Para descobrir o IP e quem pode entrar:

```powershell
.\ServidorPXE.ps1 Admin
```

---

## Como usar o console

O console tem **duas abas** e atualiza sozinho a cada 3 segundos. Os dois
seletores de **politica de boot** ficam na **barra de status superior**, entao
nao importa em qual aba voce esta para ver ou trocar a politica.

### Aba Servico e ativos

Estado do proxy DHCP, do TFTP e do HTTP, tempo no ar, contadores de requisicao,
a **atividade recente** (boot, DHCP e TFTP) e, logo abaixo, os **ativos**:

- **Dispositivos** - quem foi visto nos ultimos 20 minutos.
- **Cadastrar equipamento** - MAC vira a chave de autorizacao, com perfil,
  acao no boot, modelo e observacao.
- **Cadastrados** - a lista, com remocao em um clique.

E aqui que fica o **diagnostico de ambiente**, com 11 verificacoes:

| Verificacao | O que significa |
| --- | --- |
| Binarios iPXE | `ipxe.efi` e `undionly.kpxe` presentes |
| Pasta de midia | `www\_dorpxe\media` existe |
| Imagem WinPE | ha `boot.wim` pronto para bootar |
| ISO do Windows 11 | `Media.Iso` esta apontando para uma ISO |
| DHCP | modo `Proxy` ou `Server`, e em qual endereco |
| Escopo da rede | interface que o servidor esta atendendo |
| Firewall | regra liberada para a porta 8080 |
| Execucao de scripts | valor atual da Execution Policy |
| Privilegio | servico rodando como Administrador |
| Politica x cadastro | quantos dispositivos estao autorizados |
| Autenticacao Windows | se o login tem como funcionar (assembly + grupos) |

### Aba Midia (ISO)

Aponta a pasta ou o arquivo `.iso`, escolhe os perfis e monta o WinPE. O
`Construir midia` extrai a ISO, monta o `boot.wim` por perfil, gera o
`autounattend` e publica o conteudo em `www\winpe`.

### Politica de boot (barra superior)

Os dois seletores ficam na barra de status, no topo:

- **Quem pode iniciar pela rede?** - `Somente cadastrados` (`AllowList`) ou
  `Todos os equipamentos` (`Open`).
- **O que fazer com quem nao esta cadastrado?** - `Iniciar direto` (`Local`) ou
  `Negar` (`Deny`).

Alterar um seletor marca a mudanca como pendente, mostra um aviso em amarelo ao
lado e ela **nao e sobrescrita** pela atualizacao automatica de 3 s. Clique em
**Aplicar** para gravar - nao precisa reiniciar o servico. O resumo do efeito
da combinacao aparece a direita dos seletores.

---

## Comandos

```powershell
.\ServidorPXE.ps1 <Verbo> [opcoes]
```

| Verbo | Descricao |
| --- | --- |
| `Init` | Cria/atualiza a config e a arvore de diretorios |
| `Start` | Sobe proxy DHCP + TFTP + HTTP (`-Background`, `-DurationSec 60`, `-Port 8080`, `-NoDhcp`, `-NoTftp`) |
| `Restart` | Para a instancia e sobe outra em segundo plano |
| `Stop` | Encerra a instancia em execucao |
| `Status` | Mostra o estado do servico (`state\status.json`) |
| `Install` | Executa `Install-ServidorPXE.ps1` |
| `Build-Media` | Extrai a ISO, monta o WinPE e gera o `autounattend` |
| `Device` | `-Action List/Add/Remove/Model/Prefix/Policy` |
| `Test` | Testes locais de codec DHCP/TFTP, politica e scripts iPXE |
| `Health` | Testa HTTP/TFTP/DHCP contra o servidor em execucao |
| `Admin` | Mostra a URL do console e quem pode fazer login |
| `Uninstall` | Remove firewall, URLACL, share e inicializacao |
| `Help` | Ajuda na tela |

Exemplos:

```powershell
# Autorizar uma maquina pelo MAC
.\ServidorPXE.ps1 Device -Action Add -Mac AA:BB:CC:DD:EE:FF -Profile win11pro

# Autorizar todo o lote de um fabricante
.\ServidorPXE.ps1 Device -Action Model -Oui D4:BE:D9 -Model 'OptiPlex 7090' -Profile win11pro

# Liberar uma faixa de rede
.\ServidorPXE.ps1 Device -Action Prefix -Prefix 192.168.1.0/24 -Profile win11pro

# Politica por linha de comando
.\ServidorPXE.ps1 Device -Action Policy -Mode Open -DefaultAction Local

# Testes
.\ServidorPXE.ps1 Test
.\ServidorPXE.ps1 Health
```

### Perfis de implantacao

Os perfis ficam em `Profiles` na config e viram um `autounattend.xml` por
dispositivo. O perfil de exemplo (`win11pro`) cria o usuario `deploy` em
`Administrators`, `pt-BR`, fuso `E. South America Standard Time`, pulando OOBE.

```powershell
# build com varios perfis e arquiteturas
.\ServidorPXE.ps1 Build-Media -Iso 'D:\ISOs\Win11.iso' -Modes Uefi -Architectures x86_64,i386
```

---

## Politica de boot

A decisao e sempre nesta ordem:

1. A maquina esta cadastrada (MAC, OUI ou prefixo)? Usa o perfil dela.
2. Nao esta cadastrada: o que o **Modo** manda fazer.
   - `AllowList` - **nega**, e mostra `Policy.MessageDenied`.
   - `Open` - segue a **Acao padrao**.

| Modo | Maquina desconhecida | Maquina cadastrada |
| --- | --- | --- |
| `AllowList` | Negada | Usa o perfil |
| `Open` + `Iniciar direto` | Instala o Windows 11 direto | Usa o perfil |
| `Open` + `Negar` | Negada | Usa o perfil |

> A acao `Menu` (menu iPXE com timeout) existe no motor e continua disponivel
> por linha de comando com `-DeviceAction Menu`, mas **nao aparece no console**
> - os botoes que existiam antes nao funcionavam de verdade.

---

## Modo corporativo (proxy DHCP)

O padrao do projeto e `Dhcp.Mode = 'Proxy'`, pensado para uma rede que **ja tem
um DHCP corporativo**:

1. O cliente pede endereco ao DHCP corporativo normally.
2. O ServidorPXE intercepta apenas o `DISCOVER` e responde com as **options 66 e 67**
   (para onde baixar o boot), sem nunca distribuir endereco IP.
3. O enderecamento continua 100% no Windows Server / roteador.

Isso significa que a rede nao quebra e nao existe conflito de servidor DHCP.
O motor **e** proxy: `Dhcp.Mode` no config e apenas um rotulo exibido no
diagnostico, e `Dhcp.ProxyAck` liga ou desliga o ACK das requisicoes. O
enderecamento nunca sai do ServidorPXE em nenhum cenario.

Se o seu DHCP nao deixa passar as options 66/67, crie uma **policy de
redirecionamento** no servidor DHCP corporativo apontando oPXEClient para o IP
do ServidorPXE.

---

## Seguranca

### Login do console

O console exige **usuario e senha do Windows** (local ou de dominio), no mesmo
modelo do BYFACE.

- Dominio e validado primeiro; se nao houver, cai para a conta local.
- Liberado quem estiver em `Server.AuthGroups` **ou** em `Server.AuthUsers`.
- A comparacao de grupo e feita por **SID**, e nao pelo nome: o mesmo config
  funciona em Windows em portugues (`Administradores`) ou em ingles
  (`Administrators`), porque os dois nomes sao mapeados para `S-1-5-32-544`.
- Cookie `dorpxe_session` assinado, `HttpOnly` e `SameSite=Strict`, valido por
  1 hora (ou 30 dias com "Lembrar meu acesso").
- Tentativas erradas sao limitadas por origem (8 falhas em 5 minutos bloqueiam
  a origem por 2 minutos).
- O log do servidor so e servido para quem esta autenticado.

```powershell
# Ajustar quem pode entrar
Server = @{
    AuthGroups   = @('DHCP Administrators', 'Administrators')
    AuthUsers    = @('gsantos')   # opcional
    RememberDays = 30
}
```

Nomes de grupo bem conhecidos podem ser escritos em ingles ou portugues
(`Administrators`/`Administradores`, `Users`/`Usuarios`, `Server Operators`/
`Operadores de Servidor`...). Para um grupo criado na rede, o nome e resolvido
pelo proprio Windows - se o grupo nao existir na maquina, ele simply nunca
autoriza ninguem (e o diagnostico avisa).

> **Rede corporativa:** o padrao de `AuthUsers`, quando a chave nao existe na
> config, e `@('Administrator', $env:USERNAME)`. Ou seja, **qualquer usuario
> local que entrar no Windows entra no console**. Deixe `AuthGroups` e
> `AuthUsers` explicitos antes de usar em producao.

> Se o login falhar para todo mundo, veja o item **Autenticacao Windows** no
> diagnostico (aba Servico): ele avisa quando o assembly de contas do Windows
> nao carregou ou quando nenhum grupo de `AuthGroups` existe na maquina.

### Token de automacao

`state\admin-token.txt` guarda um token para automacao local. Ele so funciona
em `127.0.0.1`; de outra maquina a API responde **403** e exige login. O log
`servidorpxe.log` tambem fica bloqueado para acesso remoto sem sessao.

### Segredos

`config\ServidorPXE.config.psd1` aceita `ProductKey`, `Profiles[].UserPassword` e
`Media.SetupPassword`. **Esses campos nao devem ir para o Git.** O console
reescreve esse arquivo e mantem o aviso no topo dele; para producao, prefira
Prompt de credencial, GPO ou um gerenciador de segredos.

---

## Estrutura do projeto

```
ServidorPXE.ps1              ponto de entrada: verbos, CLI e suite de testes
Install-ServidorPXE.ps1      firewall, URLACL, share SMB e inicializacao
iniciar.bat             atalho para o dia a dia (UAC + preparacao + start)
config/
  ServidorPXE.config.psd1    configuracao (versionada, sem segredo)
lib/
  Common.ps1            paths, defaults, privilegio, log, config
  Auth.ps1              autenticacao Windows, grupos, sessoes
  Dhcp.ps1              codec e servidor proxy DHCP (UDP/67)
  Tftp.ps1              codec e servidor TFTP (UDP/69)
  Http.ps1              servidor HTTP, rotas da API e arquivos estaticos
  Media.ps1             extracao da ISO, WinPE, wimboot, autounattend
  Policy.ps1            AllowList/Open, decisao de boot
  Admin.ps1             HTML/CSS/JS do console
www/
  ipxe/                 binarios do iPXE e wimboot (versionados)
  pxe/                  conteudo publicado do build
  winpe/                boot.wim, BCD e midia extraida
  _dorpxe/media/        ISO e arquivos de midia
state/                  token, segredo de sessao, status, dispositivos
logs/                   log diario
```

---

## Logs e diagnostico

| Arquivo | Conteudo |
| --- | --- |
| `servidorpxe.log` | Log da instancia em execucao, UTF-8 **com BOM** (acentos corretos) |
| `logs\servidorpxe-AAAAMMDD.log` | Log diario, rotacionado por `Log.KeepDays` (30) |
| `logs\service.out.log` / `service.err.log` | Saida do servico instalado |
| `state\status.json` | Estado consumivel por automacao |

```powershell
.\ServidorPXE.ps1 Status     # estado
.\ServidorPXE.ps1 Health     # HTTP + TFTP + DHCP contra o servidor em execucao
.\ServidorPXE.ps1 Test       # 8 grupos de testes locais, sem depender da rede
```

---

## Padrao Git

O repositorio segue um padrao simples e previsivel:

| Arquivo | Funcao |
| --- | --- |
| `.gitignore` | Exclui `state\`, `logs\`, `*.log`, segredos e tudo que e gerado |
| `.gitattributes` | CRLF em tudo; binarios marcados como `binary` |
| `.editorconfig` | UTF-8, CRLF, 4 espacos, newline final |
| `CHANGELOG.md` | Historico por `[Nao publicado]` / versao |

**O que entra no commit:** codigo (`.ps1`, `.bat`), documentacao, a config
padrao e os **binarios do iPXE** (`ipxe.efi`, `undionly.kpxe`, `wimboot`, ~3,6 MB).
O projeto nao baixa iPXE automaticamente, entao esses binarios precisam estar
no repositorio para o boot funcionar offline.

**O que nunca entra:** `state\` (inclui `admin-token.txt` e
`session-secret.txt`), `logs\`, `servidorpxe.log`, `www\autoexec.ipxe` (gerado com o
IP da maquina), `www\pxe\`, `www\winpe\`, `www\_dorpxe\` e pastas temporarias.

Antes do primeiro commit:

```powershell
git init
git add -A
git status          # confira: nao pode aparecer nenhum .log, state\ ou .iso
git commit -m "ServidorPXE 1.0.0"
```

---

## Solucao de problemas

| Sintoma | O que fazer |
| --- | --- |
| `acesso negado` nas portas 67/69 | Abra o PowerShell como Administrador |
| Firewall sem regra | `.\ServidorPXE.ps1 Install` |
| Cliente nao baixa nada | Confirme a **Escopo da rede** na aba Servico e se o DHCP corporativo envia as options 66/67 |
| iPXE reinicia em loop | O proprio TFTP detecta e move o cliente para o 2o estagio via HTTP; se persistir, veja `Security.LoopMax` |
| `AllowList vazia: todo host da rede sera negado` | Cadastre os dispositivos ou troque o Modo para `Open` |
| Politica volta sozinha | Clique em **Aplicar** (na barra de status); enquanto estiver pendente, a atualizacao de 3 s nao sobrescreve |
| Login recusa conta correta | Veja **Autenticacao Windows** no diagnostico; se apontar para assembly ou grupo, ajuste `AuthGroups`/`AuthUsers` |
| Execucao de scripts bloqueada | Use `iniciar.bat`, ou `Set-ExecutionPolicy -Scope CurrentUser Bypass` |
| `ISO nao encontrada` | Confira `Media.Iso` na aba Midia; o caminho precisa existir **na maquina do servidor** |
| Politica corporativa de scripts | AppLocker/Constrained Language do AD podem prevalecer; o diagnostico avisa, mas nao sobrepoe a GPO |

---

## Licenca

**GPL-3.0** - o texto completo esta em [`LICENSE`](LICENSE).

A escolha e GPL-3.0, e nao MIT/Apache, por causa dos binarios versionados:
iPXE e wimboot sao GPL-2.0 e acompanham o repositorio. Uma licenca
permissiva no mesmo repo seria incompativel com eles.

### Binarios de terceiros

Os arquivos em `www\ipxe\` **nao** sao obra deste projeto e seguem a licenca
dos projetos upstream:

| Componente | Versao | Licenca | Origem |
| --- | --- | --- | --- |
| iPXE | 2.0.0+ (ver `www\ipxe\version.txt`) | GPL-2.0+ | <https://ipxe.org/> |
| wimboot | v2.9.0 | GPL-2.0+ | <https://ipxe.org/wimboot/> |

O codigo deste repositorio (PowerShell, `autoexec.ipxe` proprio, documentacao)
e GPL-3.0.

### Windows e ADK

O projeto **nao** distribui conteudo da Microsoft. Nenhuma ISO, `install.wim`,
`boot.wim` ou `sources` esta no repositorio: a midia e extraida da sua propria
ISO, em tempo de build, e os `.gitignore` bloqueiam esses artefatos. O Windows 11
e o Windows ADK continuam sob a licenca da Microsoft.

### Reportar problemas

Abra uma issue no repositorio. Se voce modificar e distribuir, mantenha a
licenca e avise as alteracoes no `CHANGELOG.md`.

Se um dia quiser **hospedar** o console deste servidor para terceiros em vez de
entregar o codigo, a GPL-3.0 nao obriga a abrir a fonte nesse caso - mas a
**AGPL-3.0** sim (secao 13, uso em rede). Como o projeto ja e distribuido em
codigo, essa e a unica diferenca relevante entre as duas.
