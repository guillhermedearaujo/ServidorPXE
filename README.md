# PXEForge

PXEForge é uma aplicação Windows limpa (clean-room) para reimagem de máquinas via rede (PXE), com foco em ambientes corporativos. Construída com **C# .NET 8 + WPF + Kestrel**, voltada para operar em modo portátil, sem instalação, chaves de registro ou serviço do Windows.

## Principais recursos

- **ProxyDHCP** - Coexiste com o DHCP já existente na rede
- **Suporte BIOS e UEFI** - Compatível com ambos os modos
- **Carregamento flexível** - Suporta arquivo `.ISO` ou diretório extraído do Windows
- **Geração automática** - Cria `autounattend.xml`, `startnet.cmd`, `winpeshl.ini` e prepara o WinPE automaticamente
- **Servidores integrados** - TFTP e HTTP (Kestrel) prontos para boot iPXE/wimboot
- **Compartilhamento SMB** - Criação automática do share para acesso aos arquivos durante a instalação
- **Scripts de firewall** - Geração de `.ps1` para liberação das portas necessárias
- **Totalmente portátil** - Escreve `content/`, `state/`, `pxeforge.config.json` e logs junto ao executável

## Novidades desta versão

### Monitor Unificado
Tudo centralizado em um único bloco na interface: **Servidor, Monitor Unificado & Testes**

- **CPU e RAM em tempo real** - Barras com percentual de uso
- **Memória do processo** - `Working Set`, `Memória Privada`, `GC`
- **Recursos do sistema** - `Handles`, `Threads`
- **Sessões ativas** - Contagem por protocolo (`TFTP`, `HTTP`, `DHCP`)
- **Tráfego** - Total de transferências TFTP e volume enviado
- **Capacidade estimada** - Cálculo conservador de clientes simultâneos com base em RAM livre e pressão de CPU/RAM
- **Status do limitador** - Indicação visual (Verde/Vermelho) quando o limite estiver ativo

### Limitação por sobrecarga (Throttling)
Para evitar travamentos/crashes em hardware com poucos recursos, o servidor passa a **bloquear novos acessos** quando **CPU ou RAM >= 85%**:

- **TFTP** - Novos `RRQ` são rejeitados com a mensagem: `servidor sobrecarregado, tente novamente`
- **HTTP (`/files/*`)** - Retorna `HTTP 503 Service Unavailable` com header `Retry-After: 10`
- **Sessões em andamento** - Conexões já ativas **não são interrompidas**, apenas novos boot são negados até os recursos caírem abaixo do limite

### Melhorias e correções

- **Centralização de métricas** - Novo `ResourceMonitor` unifica estatísticas, sessões, tráfego e capacidade
- **Integração completa** - `TftpServer`, `BootHttpServer` e `PxeEngine` passam a respeitar o limitador
- **Correção DISM** - Ajustado para funcionar corretamente fora de caminhos temporários com caracteres `=` (comum em extração single-file)
- **Correção SMB** - Criação do share mais compatível, evitando erro `1332` ao não forçar concessão `Everyone`
- **Armazenamento junto ao exe** - `content/` e `state/` passam a ser gravados no diretório do executável
- **UI reorganizada** - Botões `CARREGAR .ISO` / `SELECIONAR DIRETÓRIO`, remoção da barra de caminho editável, adição de build stamp
- **Logs aprimorados** - Log por preparação gravado junto ao `.exe`, com visualização no app

## Requisitos

- **Sistema**: Windows 10/11 x64
- **Arquitetura**: UEFI ou BIOS
- **Permissões**: Executar como **Administrador** (obrigatório para UDP/67, UDP/69, SMB e DISM)
- **Rede**: Funciona em modo ProxyDHCP. Atenção a DHCP Snooping, IP Helper, VLANs, 802.1X/NAC e regras de firewall

## Como usar

1. Execute `PXEForge.exe` como Administrador
2. Carregue um `.ISO` do Windows ou selecione um diretório com os arquivos já extraídos
3. Aguarde a preparação da mídia (injeção no `boot.wim`, geração de scripts, configuração SMB)
4. Inicie o servidor
5. Inicie o cliente em modo PXE (BIOS/UEFI) para iniciar o reimagens

## Build

- **Tipo**: Self-contained single-file
- **Runtime**: `win-x64`
- **Framework**: .NET 8
- **Build de teste**: `PXEForge-TestBuild\PXEForge.exe`

## Observações

- Aplicação 100% portátil. Não altera registro, não cria serviços Windows
- Em redes corporativas com restrições de switch/segurança, pode ser necessário liberar portas/trusted interfaces
- O limitador é conservador por design: prioriza estabilidade do servidor PXE em detrimento de novos boot sob alta carga
