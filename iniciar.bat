@echo off
setlocal EnableExtensions
rem ============================================================================
rem  DorPXE - iniciar.bat
rem  Console de operacao. Deve ser executado como Administrador (elevacao
rem  automatica). DorPXE precisa de admin para UDP/67, UDP/69, firewall,
rem  URLACL e share SMB.
rem
rem  Este script se prepara para rodar em qualquer estacao corporativa:
rem    1) libera a Execution Policy (Bypass) no usuario e, se admin, na maquina
rem    2) remove o Mark of the Web dos arquivos baixados (git/zip/navegador)
rem    3) garante as pastas que o servico precisa, mesmo em projeto recem-baixado
rem
rem  Uso interativo (menu):      iniciar.bat
rem  Uso direto (um comando):    iniciar.bat start | stop | restart | status
rem                               iniciar.bat health | console | dispositivos
rem                               iniciar.bat testes | logs | instalar | preparar
rem  Diagnostico sem elevacao:   definir DORPXE_SKIP_ELEVATE=1
rem
rem  Porta HTTP: ajuste a variavel PORT abaixo (padrao do config: 8080).
rem ============================================================================

set "ROOT=%~dp0"
set "PORT=8080"
set "SCRIPT=.\ServidorPXE.ps1"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
set "PSC=powershell -NoProfile -ExecutionPolicy Bypass -Command"
set "TOKFILE=%ROOT%state\admin-token.txt"

cd /d "%ROOT%"

rem --- elevacao automatica -----------------------------------------------------
if "%DORPXE_SKIP_ELEVATE%"=="1" goto sem_admin
net session >nul 2>&1
if errorlevel 1 goto elevar
goto sem_admin

:elevar
echo [ServidorPXE] Executando como Administrador...
if not "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs" >nul 2>&1
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
)
if errorlevel 1 (
    echo.
    echo [ERRO] Nao foi possivel elevar para Administrador. Clique com o botao
    echo        direito em iniciar.bat e escolha "Executar como administrador".
    echo.
    pause
    exit /b 1
)
exit /b 0

:sem_admin
rem aqui: com Administrador, ou com DORPXE_SKIP_ELEVATE=1 para diagnostico

rem --- preparacao do ambiente (Execution Policy + Mark of the Web) --------------
if not "%DORPXE_SKIP_PREPARE%"=="1" call :preparar

if not exist "%TOKFILE%" echo [aviso] state\admin-token.txt ainda nao existe (sera criado no primeiro Start).

rem --- acoes -------------------------------------------------------------------
if /i "%~1"=="iniciar"     goto acao_iniciar
if /i "%~1"=="start"      goto acao_iniciar
if /i "%~1"=="parar"      goto acao_parar
if /i "%~1"=="stop"       goto acao_parar
if /i "%~1"=="reiniciar"  goto acao_reiniciar
if /i "%~1"=="restart"    goto acao_reiniciar
if /i "%~1"=="status"     goto acao_status
if /i "%~1"=="health"     goto acao_health
if /i "%~1"=="console"    goto acao_console
if /i "%~1"=="dispositivos" goto acao_dispositivos
if /i "%~1"=="testes"     goto acao_testes
if /i "%~1"=="logs"       goto acao_logs
if /i "%~1"=="instalar"   goto acao_instalar
if /i "%~1"=="preparar"   goto acao_preparar
if /i "%~1"=="menu"       goto menu
if not "%~1"==""          goto uso

:menu
cls
echo.
echo  =====================================================
echo    DorPXE  -  console de operacao   (porta %PORT%)
echo  =====================================================
echo.
echo   1) Iniciar em segundo plano ^(recomendado^)
echo   2) Iniciar em primeiro plano ^(logs na tela, Ctrl+C para sair^)
echo   3) Reiniciar
echo   4) Parar
echo   5) Status
echo   6) Health  ^(testa HTTP, TFTP e DHCP^)
echo   7) Abrir console web no navegador
echo   8) Dispositivos cadastrados
echo   9) Testes
echo  10) Instalar ^(firewall, URLACL, tarefa agendada^)
echo  11) Ver ultimos logs
echo  12) Preparar ambiente ^(Execution Policy^)
echo   0) Sair
echo.
set "OP="
set /p OP="Escolha uma opcao e pressione Enter: "
if errorlevel 1 goto fim
set "OP=%OP: =%"
echo.

if "%OP%"=="1" goto acao_iniciar
if "%OP%"=="2" goto acao_frente
if "%OP%"=="3" goto acao_reiniciar
if "%OP%"=="4" goto acao_parar
if "%OP%"=="5" goto acao_status
if "%OP%"=="6" goto acao_health
if "%OP%"=="7" goto acao_console
if "%OP%"=="8" goto acao_dispositivos
if "%OP%"=="9" goto acao_testes
if "%OP%"=="10" goto acao_instalar
if "%OP%"=="11" goto acao_logs
if "%OP%"=="12" goto acao_preparar
if "%OP%"=="0" goto fim
if "%OP%"=="" goto fim
echo [aviso] Opcao invalida.
ping -n 3 127.0.0.1 >nul
goto menu

:acao_iniciar
echo [ServidorPXE] Iniciando em segundo plano...
%PS% "%SCRIPT%" Start -Background -Port %PORT%
goto pos

:acao_frente
echo [ServidorPXE] Iniciando em primeiro plano. Ctrl+C encerra.
%PS% "%SCRIPT%" Start -Port %PORT%
goto pos

:acao_reiniciar
echo [ServidorPXE] Reiniciando...
%PS% "%SCRIPT%" Restart -Port %PORT%
goto pos

:acao_parar
echo [ServidorPXE] Parando...
%PS% "%SCRIPT%" Stop
goto pos

:acao_status
%PS% "%SCRIPT%" Status
goto pos

:acao_health
%PS% "%SCRIPT%" Health -Port %PORT%
goto pos

:acao_console
set "URL=http://127.0.0.1:%PORT%/pxe/admin"
echo [ServidorPXE] Abrindo: %URL%
echo           (login com usuario local do Windows autorizado)
start "" "%URL%"
goto pos

:acao_preparar
echo [ServidorPXE] Preparacao concluida ^(Execution Policy, arquivos e pastas^).
goto pos

:acao_dispositivos
%PS% "%SCRIPT%" Device -Action List
goto pos

:acao_testes
%PS% "%SCRIPT%" Test
goto pos

:acao_logs
set "LOGFILE=%ROOT%servidorpxe.log"
if not exist "%LOGFILE%" (
    echo [aviso] Arquivo %LOGFILE% ainda nao existe ^(criado no primeiro Start^).
    goto pos
)
echo === servidorpxe.log ^(ultimas 40 linhas^) ===
%PSC% "Get-Content -LiteralPath '%LOGFILE%' -Tail 40" 2>nul
echo.
echo caminho completo: %LOGFILE%
goto pos

:acao_instalar
echo [ServidorPXE] Instalando: firewall, URLACL, share SMB e tarefa agendada.
echo         Requer Administrador e pode levar alguns segundos.
echo.
%PS% "%SCRIPT%" Install
goto pos

:pos
echo.
if not "%~1"=="" goto fim
pause
goto menu

:uso
echo Uso: iniciar.bat [iniciar^|parar^|reiniciar^|status^|health^|console^|dispositivos^|testes^|logs^|instalar^|preparar^|menu]
exit /b 1

rem ---------------------------------------------------------------------------
rem  :preparar - Execution Policy + arquivos baixados + pastas do projeto.
rem  Roda toda vez que o .bat entra (antes de qualquer comando) para o projeto
rem  funcionar em uma estacao corporativa recien-configurada:
rem    - Set-ExecutionPolicy Bypass (CurrentUser sempre; LocalMachine se admin)
rem    - Unblock-File (remove o Mark of the Web de .ps1/.bat/.ipxe baixados)
rem    - cria as pastas que o servico usa, mesmo em projeto recem-baixado
rem  Pular: definir DORPXE_SKIP_PREPARE=1
rem ---------------------------------------------------------------------------
:preparar
echo [ServidorPXE] Preparando o ambiente: Execution Policy, arquivos e pastas...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='SilentlyContinue';" ^
  "Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass -Force | Out-Null;" ^
  "if ((New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole('Administrators')) { Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy Bypass -Force | Out-Null };" ^
  "$r='%ROOT%';" ^
  "Get-ChildItem -LiteralPath $r -Recurse -Depth 3 -File -Force | Where-Object { $_.Extension -in '.ps1','.psd1','.bat','.cmd','.ipxe','.xml' -and $_.FullName -notlike '*\www\_dorpxe\*' } | Unblock-File;" ^
  "foreach ($d in @('state','state\mount','logs','config','lib','www','www\ipxe','www\pxe','www\winpe','www\winpe\profiles','www\winpe\shared','www\_dorpxe','www\_dorpxe\media','www\_dorpxe\profiles')) { New-Item -ItemType Directory -Force -Path (Join-Path $r $d) | Out-Null };" ^
  "Write-Host '        Execution Policy liberada, arquivos desbloqueados e pastas criadas.' -ForegroundColor DarkGray"
exit /b 0

:fim
endlocal
exit /b 0
