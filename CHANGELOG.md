# Changelog

Todas as alteracoes relevantes deste projeto sao registradas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/)
e o versionamento segue [SemVer](https://semver.org/lang/pt-BR/).

## [Nao publicado]

### Adicionado
- **Barra de progresso por ativo** no passo de Ativos, com bytes entregues,
  MB/GB e porcentagem de cada cliente. Mede a fase **TFTP do WinPE**
  (wimboot + `boot.wim` + BCD/`boot.sdi`/fonte), que e o que de fato passa
  pelo servidor. O rotulo deixa explicito que o `install.wim` vem pelo share
  SMB direto para o cliente e **nao e medido pelo console** - o Windows Setup
  le o arquivo do share sem passar pelo ServidorPXE.
- Contagem de bytes TFTP **por IP de cliente** durante o envio (a cada 256 KB,
  para nao disputar o lock a cada bloco), exposta em `/pxe/api/status` como
  `tftpByIp` e cruzada com a lista de hosts ativos para virar MAC + progresso.
- `Get-DorPXEBootPayloadBytes`: soma dos arquivos que um cliente baixa por TFTP,
  usada como denominador da porcentagem.
- **Fluxo do console na ordem 1, 2, 3**: `1. Politica de boot` (barra
  superior), `2. Midia (ISO)` e `3. Ativos`. Os menus Ativos e Midia foram
  invertidos: a Midia vem primeiro, com o Ativos como ultimo passo.
- **Licenca GPL-3.0** (`LICENSE`) e a secao de Licenca no README, com a
  licenca dos binarios de terceiros (iPXE e wimboot, GPL-2.0) e o aviso de que
  nenhum conteudo da Microsoft e redistribuido.
- Aviso de status no README: o boot em si ainda nao foi validado em hardware
  real (falta ISO, ADK e cliente PXE).
- Barra de status superior com os **dois seletores de politica de boot**
  (`Modo` e `Acao padrao`), o botao `Aplicar` e o resumo do efeito da
  combinacao - a politica fica visivel e trocavel em qualquer aba.
- Verificacao **Autenticacao Windows** no diagnostico de ambiente (11o item): ela
  diz se o assembly de contas do Windows carregou e se existe algum grupo de
  `AuthGroups` na maquina - ou seja, se o login tem como funcionar.
- Autenticacao do console com usuario local ou de dominio do Windows, no mesmo
  modelo do BYFACE: cookie `dorpxe_session` assinado (`usuario|expiracao|HMAC`),
  `HttpOnly` e `SameSite=Strict`, validade de 1 hora ou 30 dias com
  "Lembrar meu acesso".
- Autorizacao por grupo do AD/local (`Server.AuthGroups`) ou por lista de
  usuarios (`Server.AuthUsers`), com limite de tentativas por origem.
- Rotas `/pxe/api/login`, `/pxe/api/session` e `/pxe/api/logout`.
- Segredo de sessao persistente em `state/session-secret.txt`, gerado na
  primeira inicializacao.
- Diagnostico de ambiente com 11 verificacoes (binarios iPXE, pasta de midia,
  WinPE, ISO, DHCP, escopo de rede, firewall, Execution Policy, privilegio,
  Politica x cadastro e Autenticacao Windows) visivel na aba Servico e ativos.
- `iniciar.bat` agora prepara o ambiente: UAC, `Set-ExecutionPolicy Bypass`,
  `Unblock-File` (Mark of the Web) e criacao das pastas do projeto.
- Acao/menu `preparar` no `iniciar.bat`.
- `preflight` antes da midia: o projeto abre e opera mesmo sem ISO/boot.wim.
- Cabecalho do console com o usuario autenticado e botao `Sair`.

### Alterado
- **Projeto renomeado de DorPXE para ServidorPXE.** O repositorio, os titulos, o
  README e o CHANGELOG usam o novo nome, mais generico. Nomes de arquivo
  (`ServidorPXE.ps1`, `Install-ServidorPXE.ps1`,
  `config\ServidorPXE.config.psd1`), o log (`servidorpxe.log`), a rota do log
  (`/pxe/servidorpxe.log`), o share SMB (`ServidorPXE`), o nome do servico
  instalado e o mutex passaram junto.
- **Console reorganizado em duas abas.** A antiga aba 3 (Politica + Dispositivos)
  foi eliminada: os seletores de politica subiram para a barra de status superior
  e os cards de ativos (Dispositivos, Cadastrar equipamento, Cadastrados) foram
  para o passo 1, logo apos Atividade recente. A aba 1 passou a se chamar
  **Servico e ativos**.
- O **usuario autenticado** aparece abaixo dos botoes `Atualizar` e `Reiniciar`,
  em vez de ao lado deles.
- Politica de boot passou de botoes para dois `<select>`: `Modo`
  (AllowList/Open) e `Acao padrao` (Iniciar direto/Negar). As escolhas pendentes
  nao sao mais sobrescritas pelo atualizacao automatica de 3 segundos.
- A opcao legada `Menu` foi removida do cadastro do console; continua disponivel
  apenas por CLI (`-DeviceAction Menu`).
- `servidorpxe.log` e a data de hoje em `logs\` passam a ser gravados em UTF-8 com
  BOM, para que os acentos aparecam corretos no Bloco de Notas e no PowerShell.
- `config\ServidorPXE.config.psd1` gravado pelo console passa a emitir o aviso de
  segredos no topo do arquivo.
- Log do DHCP em modo Proxy deixa de anunciar a propria sub-rede como um
  "enderecamento" e informa que o enderecamento continua no Windows Server.
- Log de erro do HTTP passou a responder HTTP/1.1 explicito, para nao derrubar
  a conexao em caso de falha de socket.

### Corrigido
- **Login recusava qualquer credencial do Windows.** Faltava carregar
  `System.DirectoryServices.AccountManagement`, que o BYFACE faz em
  `server.ps1:170`. Sem o assembly, `PrincipalContext` nao existia, nenhum
  contexto era criado e `Invoke-DorPXEAuthenticate` respondia 401 "usuario ou
  senha invalidos" para qualquer usuario, inclusive com a senha certa.
- **Grupo de administracao nao batia em Windows em portugues.** Onde o grupo se
  chama `Administradores`, o nome do config (`Administrators`) nao era
  encontrado. A comparacao passou a ser por SID, com os SIDs bem conhecidos
  mapeados para qualquer idioma.
- `Get-DorPXEUserGroupSid` usa `GetGroups()` sem argumento: em .NET Framework
  4.x nao existe a sobrecarga com `GroupScope`, e a anterior devolvia lista
  vazia.
- `Server.AuthGroups`, `Server.AuthUsers` e `Server.RememberDays` eram
  **sempre ignorados**: a config e um `Hashtable` e o codigo procurava as
  chaves em `.PSObject.Properties`, que nao enxerga as chaves de um hashtable.
- `Get-DorPXEPath` nao expunha a pasta de midia, quebrando o diagnostico e a
  verificacao de `www\_dorpxe\media`.
- Execucao nao elevada do `iniciar.bat` caia no bloco de erros por causa de um
  `goto` apontando para um rotulo inexistente.
- Radioes de politica e estilos `.tg` orfaos ficaram no HTML depois da troca
  para dropdowns.
- Interpolacao `${...}` do JavaScript dentro do here-string do PowerShell
  corrompia o script do console.
- **Linha de `boot.i386.wim` duplicada no `boot.ipxe`.** O gerador iterava os
  modos prontos (`uefi` e `bios`) e emitia uma linha por par modo x extra. Como a
  URL usa `${mode}` (variavel do iPXE, nao do servidor), o que importa e o
  conjunto de arquiteturas extras: com os dois modos prontos a mesma linha saia
  duas vezes. Agora os extras sao deduplicados por arquivo e ordenados.
- **Nome antigo sobrevivia em textos que o usuario e o cliente veem.** O
  primeiro renome cobriu arquivos, log, share e titulos do console, mas deixou
  o cabecalho do `boot.ipxe`, o menu de boot, a tela de acesso negado, o titulo
  do Windows Setup e o `FullName`/`Organization` do `autounattend.xml` (esses
  dois viram o "proprietario registrado" do Windows instalado).
- **Nome de servico divergente no `sc.exe`.** `sc.exe description` e
  `sc.exe failure` ainda apontavam para `DorPXE`, que nao existe depois do
  renome: a configuracao de recuperacao automatica nao era aplicada. Alinhados
  com o servico criado (`ServidorPXE`).
- **Share padrao do `New-DorPXEConfig` continuava `DorPXE`.** O arquivo de
  configuracao foi corrigido, mas um `Init` regravaria o padrao antigo por
  cima. Corrigido no gerador e no arquivo.
- **Diagnostico de firewall cego.** Duas verificacoes procuravam regras
  `DorPXE*` (`lib\Admin.ps1` e `lib\Common.ps1`) enquanto o instalador criava
  `DorPXE-HTTP/TFTP/DHCP`; apos o renome das regras, nenhuma das duas bateria
  acharia as regras. Passaram a usar `ServidorPXE*`, o mesmo prefixo do
  instalador.
- Prefixo do log diario inconsistente: gravava `logs\dorpxe-AAAAMMDD.log` e o
  console lia `dorpxe-*.log`. Agora `servidorpxe-*` nos dois lados, com o README
  atualizado.
- `MessageDenied` do `config\ServidorPXE.config.psd1` (o arquivo carregado em
  runtime) ainda dizia `DorPXE:`; so o default em `lib\Common.ps1` havia sido
  corrigido.
- Nome da tarefa agendada, do atalho do Menu Iniciar e das regras de firewall
  coerentes com `ServidorPXE`.

### Testes
- 182 checks (antes: 171). Novos checks de regressao:
  - extras sem duplicar e nenhuma linha repetida no `boot.ipxe`;
  - firewall criado pelo instalador casa com o procurado no diagnostico;
  - `sc.exe` aponta para o servico `ServidorPXE`;
  - share padrao e share do config iguais a `ServidorPXE`;
  - `MessageDenied` do config igual ao do gerador;
  - prefixo do log arquiado igual na escrita e na leitura;
  - nenhum nome antigo visivel em codigo/config (case sensivel, com allowlist
    dos identificadores internos `Get-DorPXE*`, `X-DorPXE-Token`,
    `dorpxe_session`, `www\_dorpxe`, `DORPXE_SKIP_*`);
  - README documenta o caminho do log diario atual.
- `PXE_DUMP_BOOT=1 ServidorPXE.ps1 Test` imprime o `boot.ipxe` gerado, que e o
  arquivo exato que o cliente recebe.

## [1.0.0] - 2026-09-26

### Adicionado
- Servidor PXE nativo em PowerShell 5.1: proxy DHCP (UDP/67), TFTP (UDP/69) e
  HTTP para iPXE e WinPE.
- Console web de tres abas (Servico, Midia, Politica + Dispositivos).
- Codecs DHCP (DISCOVER/OFFER com options 66/67/93) e TFTP (RRQ/OACK/DATA/ACK)
  testados localmente.
- Suporte a UEFI (x86_64, i386, arm64), PCBIOS e wimboot, com escolha de
  `boot.wim` por arquitetura.
- Perfis de implantacao (`autounattend`), cadastro de MAC/OUI/prefixos e
  politica AllowList/Open.
- Modo Proxy de DHCP para conviver com o DHCP corporativo.
- `Install-ServidorPXE.ps1` com firewall, URLACL, share SMB e inicializacao
  (ScheduledTask, StartupFolder, Service ou None).
- Suíte `.\ServidorPXE.ps1 Test` com 8 grupos de testes locais.
