using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using System.Windows;
using PXEForge.Core;
using PXEForge.Core.Configuration;
using PXEForge.Core.Diagnostics;
using PXEForge.Core.Monitoring;
using PXEForge.Core.Testing;

namespace PXEForge.App.ViewModels;

public sealed class LogItem : INotifyPropertyChanged
{
    private string _line = string.Empty;
    public string Line { get => _line; set { _line = value; OnPropertyChanged(); } }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly LogHub _log;
    private readonly PxeEngine _engine;
    private readonly PxeConfig _config;
    private readonly string _agentLogPath;
    private string _statusText = "Parado";
    private bool _isRunning;
    private bool _isBusy;
    private string _bindAddress = "auto";
    private int _httpPort = 8082;
    private string _serverName = "PXEFORGE";
    private string _selectedSource = string.Empty;
    private string _sourceType = "NENHUM";
    private string _progressText = string.Empty;
    private string _stateColor = "#6b6b6b";
    private long _dhcpRequests;
    private long _tftpTransfers;
    private long _tftpBytes;
    private bool _admin;
    private string _testSummary = "Nao executados";
    private string _buildStamp = string.Empty;
    private bool _isPreparing;
    private double _prepareProgress;
    private bool _prepareIndeterminate = true;
    private string _prepareStage = string.Empty;

    // Monitor unificado
    private double _cpuPercent;
    private double _ramPercent;
    private string _ramUsageText = string.Empty;
    private string _processMemText = string.Empty;
    private int _handleCount;
    private int _threadCount;
    private string _activeSessionsText = string.Empty;
    private string _trafficText = string.Empty;
    private string _capacityText = string.Empty;
    private bool _isThrottled;
    private string _throttleReason = string.Empty;
    private string _monitorSummary = string.Empty;

    public MainViewModel()
    {
        _log = new LogHub(5000);
        try
        {
            var exePath = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exePath))
            {
                _agentLogPath = Path.Combine(Path.GetDirectoryName(exePath)!, "pxeforge-agent-debug.txt");
            }
            else
            {
                _agentLogPath = Path.Combine(PxeConfig.AppDirectory, "pxeforge-agent-debug.txt");
            }
        }
        catch
        {
            _agentLogPath = Path.Combine(Environment.CurrentDirectory, "pxeforge-agent-debug.txt");
        }

        _log.EntryWritten += entry =>
        {
            var line = entry.ToString();
            Application.Current.Dispatcher.Invoke(() =>
            {
                Logs.Insert(0, new LogItem { Line = line });
                if (Logs.Count > 2000) Logs.RemoveAt(Logs.Count - 1);
            });
            try
            {
                File.AppendAllText(_agentLogPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + line + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
                // ignore logging failures
            }
        };

        _config = PxeConfig.Load();
        _config.BaseDirectory = PxeConfig.AppDirectory;
        _bindAddress = _config.BindAddress;
        _httpPort = _config.HttpPort;
        _serverName = _config.ServerName;
        _engine = new PxeEngine(_config, _log);
        _admin = PXEForge.Core.Media.WindowsHelper.IsAdministrator();
        _buildStamp = BuildStampText();
        Logs = new ObservableCollection<LogItem>();
        try
        {
            var header = $"=== PXEForge agent debug log ==={Environment.NewLine}" +
                         $"Started: {DateTime.Now:yyyy-MM-dd HH:mm:ss}{Environment.NewLine}" +
                         $"BaseDir: {PxeConfig.AppDirectory}{Environment.NewLine}" +
                         $"Exe: {Environment.ProcessPath ?? "unknown"}{Environment.NewLine}" +
                         $"Admin: {_admin}{Environment.NewLine}" +
                         $"==============================={Environment.NewLine}{Environment.NewLine}";
            File.WriteAllText(_agentLogPath, header, Encoding.UTF8);
            _log.Info("agent", $"agent debug log: {_agentLogPath}");
        }
        catch { }
        UpdateStatus();
    }

    public ObservableCollection<LogItem> Logs { get; }

    public string StatusText { get => _statusText; set { _statusText = value; OnPropertyChanged(); } }
    public bool IsRunning { get => _isRunning; set { _isRunning = value; OnPropertyChanged(); } }
    public bool IsBusy { get => _isBusy; set { _isBusy = value; OnPropertyChanged(); } }
    public string BindAddress { get => _bindAddress; set { _bindAddress = value; _config.BindAddress = value; OnPropertyChanged(); } }
    public int HttpPort { get => _httpPort; set { _httpPort = value; _config.HttpPort = value; OnPropertyChanged(); } }
    public string ServerName { get => _serverName; set { _serverName = value; _config.ServerName = value; OnPropertyChanged(); } }
    public string ProgressText { get => _progressText; set { _progressText = value; OnPropertyChanged(); } }
    public string StateColor { get => _stateColor; set { _stateColor = value; OnPropertyChanged(); } }
    public long DhcpRequests { get => _dhcpRequests; set { _dhcpRequests = value; OnPropertyChanged(); } }
    public long TftpTransfers { get => _tftpTransfers; set { _tftpTransfers = value; OnPropertyChanged(); } }
    public long TftpBytes { get => _tftpBytes; set { _tftpBytes = value; OnPropertyChanged(); } }
    public bool Admin { get => _admin; set { _admin = value; OnPropertyChanged(); } }
    public string TestSummary { get => _testSummary; set { _testSummary = value; OnPropertyChanged(); } }
    public string BuildStamp { get => _buildStamp; set { _buildStamp = value; OnPropertyChanged(); } }

    public bool IsPreparing { get => _isPreparing; set { _isPreparing = value; OnPropertyChanged(); } }
    public double PrepareProgress { get => _prepareProgress; set { _prepareProgress = value; OnPropertyChanged(); } }
    public bool PrepareIndeterminate { get => _prepareIndeterminate; set { _prepareIndeterminate = value; OnPropertyChanged(); } }
    public string PrepareStage { get => _prepareStage; set { _prepareStage = value; OnPropertyChanged(); } }

    public double CpuPercent { get => _cpuPercent; set { _cpuPercent = value; OnPropertyChanged(); } }
    public double RamPercent { get => _ramPercent; set { _ramPercent = value; OnPropertyChanged(); } }
    public string RamUsageText { get => _ramUsageText; set { _ramUsageText = value; OnPropertyChanged(); } }
    public string ProcessMemText { get => _processMemText; set { _processMemText = value; OnPropertyChanged(); } }
    public int HandleCount { get => _handleCount; set { _handleCount = value; OnPropertyChanged(); } }
    public int ThreadCount { get => _threadCount; set { _threadCount = value; OnPropertyChanged(); } }
    public string ActiveSessionsText { get => _activeSessionsText; set { _activeSessionsText = value; OnPropertyChanged(); } }
    public string TrafficText { get => _trafficText; set { _trafficText = value; OnPropertyChanged(); } }
    public string CapacityText { get => _capacityText; set { _capacityText = value; OnPropertyChanged(); } }
    public bool IsThrottled { get => _isThrottled; set { _isThrottled = value; OnPropertyChanged(); } }
    public string ThrottleReason { get => _throttleReason; set { _throttleReason = value; OnPropertyChanged(); } }
    public string MonitorSummary { get => _monitorSummary; set { _monitorSummary = value; OnPropertyChanged(); } }

    /// <summary>Caminho da origem escolhida pelo operador (.ISO ou diretório já extraído).</summary>
    public string SelectedSource
    {
        get => _selectedSource;
        set
        {
            _selectedSource = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(SelectedSourceDisplay));
        }
    }

    /// <summary>ISO ou DIRETORIO. Só informativo para a UI.</summary>
    public string SourceType
    {
        get => _sourceType;
        set
        {
            _sourceType = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(SelectedSourceDisplay));
        }
    }

    public string SelectedSourceDisplay =>
        string.IsNullOrWhiteSpace(SelectedSource)
            ? "Nenhuma origem selecionada. Use CARREGAR .ISO ou SELECIONAR DIRETÓRIO."
            : $"[{SourceType}] {SelectedSource}";

    public async Task StartAsync()
    {
        if (IsRunning || IsBusy) return;
        IsBusy = true;
        try
        {
            _config.Save();
            _log.Info("ui", "salvando configuracao...");
            await _engine.StartAsync();
            UpdateStatus();
            _log.Info("ui", "motor iniciado");
        }
        finally
        {
            IsBusy = false;
            UpdateStatus();
        }
    }

    public async Task StopAsync()
    {
        if (!IsRunning || IsBusy) return;
        IsBusy = true;
        try
        {
            await _engine.StopAsync();
            _log.Info("ui", "motor parado");
        }
        finally
        {
            IsBusy = false;
            UpdateStatus();
        }
    }

    public async Task PrepareAsync()
    {
        var path = (SelectedSource ?? string.Empty).Trim().Trim('"');

        if (string.IsNullOrWhiteSpace(path))
        {
            _log.Error("ui", "Nenhuma origem selecionada. Use CARREGAR .ISO ou SELECIONAR DIRETÓRIO.");
            ProgressText = "Selecione uma origem primeiro.";
            return;
        }

        path = path.TrimEnd('\\', '/');
        if (path.Length == 2 && path[1] == ':')
        {
            path += "\\"; // "F:" -> "F:\"
        }

        SelectedSource = path;

        var isFile = File.Exists(path);
        var isDir = Directory.Exists(path);

        if (!isFile && !isDir)
        {
            _log.Error("ui", $"Origem não encontrada: {path}");
            ProgressText = "Origem inválida.";
            return;
        }

        // Sobrescreve o log para debug a cada preparação (como pedido)
        try
        {
            var exePath = Environment.ProcessPath ?? PxeConfig.AppDirectory;
            var header = $"=== PXEForge PREPARE SESSION ==={Environment.NewLine}" +
                         $"Time: {DateTime.Now:yyyy-MM-dd HH:mm:ss}{Environment.NewLine}" +
                         $"Source: {path} ({(isDir ? "DIRECTORY" : "FILE")}){Environment.NewLine}" +
                         $"BaseDir: {PxeConfig.AppDirectory}{Environment.NewLine}" +
                         $"Exe: {exePath}{Environment.NewLine}" +
                         $"LogPath: {_agentLogPath}{Environment.NewLine}" +
                         $"Admin: {Admin}{Environment.NewLine}" +
                         $"================================{Environment.NewLine}{Environment.NewLine}";
            File.WriteAllText(_agentLogPath, header, Encoding.UTF8);
            _log.Info("agent", $"preparation log reset: {_agentLogPath}");
        }
        catch (Exception ex)
        {
            _log.Warn("agent", $"falha ao criar log de debug: {ex.Message}");
        }

        if (isFile)
        {
            if (!path.EndsWith(".iso", StringComparison.OrdinalIgnoreCase))
            {
                _log.Error("ui", "CARREGAR .ISO aceita somente arquivos .ISO. Para mídia já extraída use SELECIONAR DIRETÓRIO.");
                ProgressText = "Arquivo não é .ISO.";
                return;
            }

            SourceType = "ISO";
            _log.Info("ui", $"arquivo .ISO selecionado: {Path.GetFileName(path)}");
        }
        else
        {
            SourceType = "DIRETÓRIO";
            var bootWimCheck = Path.Combine(path, "sources", "boot.wim");
            if (File.Exists(bootWimCheck))
            {
                _log.Info("ui", "diretório válido: encontrado sources\\boot.wim");
            }
            else
            {
                _log.Warn("ui", "não encontrei sources\\boot.wim neste diretório.");
                _log.Warn("ui", "aponte para a raiz da mídia já extraída (mesma estrutura do DVD/pendrive).");
            }
        }

        if (!Admin)
        {
            _log.Warn("ui", "sem privilégios de administrador: montagem da ISO, DISM, patch do boot.wim e share SMB podem falhar.");
        }

        IsBusy = true;
        IsPreparing = true;
        PrepareIndeterminate = true;
        PrepareProgress = 0;
        PrepareStage = "Iniciando preparo...";
        ProgressText = "Preparando mídia... isso pode demorar alguns minutos.";

        var progress = new Progress<Core.Media.IngestProgress>(p =>
        {
            Application.Current.Dispatcher.Invoke(() =>
            {
                PrepareStage = $"{p.Stage}: {p.Detail}";
                ProgressText = PrepareStage;
                if (p.Total > 0 && p.Copied >= 0)
                {
                    PrepareIndeterminate = false;
                    var pct = Math.Clamp((double)p.Copied / p.Total * 100.0, 0, 100);
                    PrepareProgress = pct;
                }
                else
                {
                    PrepareIndeterminate = true;
                }
            });
        });

        try
        {
            _config.Save();
            var origemLog = isDir ? "diretório já extraído" : "arquivo .ISO";
            _log.Info("ui", $"preparando mídia a partir de {origemLog}: {path}");
            var result = await _engine.PrepareMediaAsync(path, progress);
            _log.Info("ui", $"preparo concluído. boot.wim patch={result.BootWimPatched}, share={result.ShareReady}");
            foreach (var warning in result.Warnings)
            {
                _log.Warn("ui", warning);
            }

            PrepareIndeterminate = false;
            PrepareProgress = 100;
            PrepareStage = "Concluído";
            ProgressText = result.BootWimPatched && result.ShareReady
                ? "Pronto para iniciar o servidor"
                : "Pronto com avisos - verifique os logs";
        }
        catch (Exception ex)
        {
            _log.Error("ui", $"falha no preparo: {ex.Message}");
            _log.Error("ui", ex.ToString());
            ProgressText = "Falha no preparo";
            PrepareStage = "Falha";
            PrepareIndeterminate = false;
            PrepareProgress = 0;
        }
        finally
        {
            try { _log.Info("agent", $"preparation log saved to: {_agentLogPath}"); } catch { }
            IsBusy = false;
            IsPreparing = false;
            UpdateStatus();
        }
    }

    public async Task RunTestsAsync()
    {
        IsBusy = true;
        TestSummary = "Executando testes...";
        try
        {
            var results = await SelfTestRunner.RunAsync(_log);
            var passed = results.Count(r => r.Passed);
            var failed = results.Count(r => !r.Passed);
            TestSummary = $"{passed}/{results.Count} aprovados, {failed} falharam";
            foreach (var r in results)
            {
                if (r.Passed) _log.Info("selftest", $"OK {r.Name} - {r.Detail}");
                else _log.Error("selftest", $"FALHA {r.Name} - {r.Detail}");
            }
        }
        catch (Exception ex)
        {
            TestSummary = "Erro ao executar testes";
            _log.Error("selftest", ex.ToString());
        }
        finally
        {
            IsBusy = false;
            UpdateStatus();
        }
    }

    public void Refresh()
    {
        UpdateStatus();
        UpdateMonitor();
    }

    private void UpdateStatus()
    {
        try
        {
            var status = _engine.GetStatus();
            StatusText = status.State;
            IsRunning = status.State == "Running" || status.State == "Degraded";
            DhcpRequests = status.DhcpRequests;
            TftpTransfers = status.TftpTransfers;
            TftpBytes = status.TftpBytes;
            Admin = status.Administrator;
            StateColor = status.State switch
            {
                "Running" => "#3fb950",
                "Degraded" => "#d29922",
                "Starting" => "#58a6ff",
                "Error" => "#f85149",
                _ => "#6b6b6b"
            };
        }
        catch
        {
            // Ignore status refresh failures.
        }
    }

    private void UpdateMonitor()
    {
        try
        {
            var snap = _engine.GetResourceSnapshot();
            CpuPercent = snap.CpuPercent;
            RamPercent = snap.RamUsedPercent;
            RamUsageText = $"RAM: {snap.RamUsedPercent:0}% | Livre: {ResourceMonitor.FormatBytes(snap.AvailablePhysicalBytes)} / {ResourceMonitor.FormatBytes(snap.TotalPhysicalBytes)}";
            ProcessMemText = $"Processo: Working Set {ResourceMonitor.FormatBytes(snap.WorkingSetBytes)} | Privado {ResourceMonitor.FormatBytes(snap.PrivateBytes)} | GC {ResourceMonitor.FormatBytes(snap.GcTotalBytes)}";
            HandleCount = snap.HandleCount;
            ThreadCount = snap.ThreadCount;
            ActiveSessionsText = $"Ativas: TFTP={snap.ActiveTftpSessions} | HTTP={snap.ActiveHttpSessions} | DHCP req={snap.DhcpRequests}";
            TrafficText = $"Tráfego: TFTP {snap.TftpTransfers} transferências | {ResourceMonitor.FormatBytes(snap.TftpBytesSent)} enviados";
            CapacityText = snap.CapacityEstimate;
            IsThrottled = snap.IsThrottled;
            ThrottleReason = string.IsNullOrWhiteSpace(snap.ThrottleReason) ? "OK" : $"LIMITADO: {snap.ThrottleReason}";
            MonitorSummary = IsThrottled
                ? $"MONITOR UNIFICADO | BLOQUEIO ATIVO | {snap.ThrottleReason} | Novos acessos negados até < 85%"
                : $"MONITOR UNIFICADO | CPU {snap.CpuPercent:0}% | RAM {snap.RamUsedPercent:0}% | Sessões TFTP:{snap.ActiveTftpSessions} HTTP:{snap.ActiveHttpSessions}";
        }
        catch
        {
            // Ignore monitor failures.
        }
    }

    private static string BuildStampText()
    {
        try
        {
            var exe = Environment.ProcessPath;
            var stamp = exe is not null && File.Exists(exe)
                ? File.GetLastWriteTime(exe)
                : DateTime.Now;
            var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "1.0.0";
            return $"UI v2 · build {stamp:yyyy-MM-dd HH:mm} · v{version}";
        }
        catch
        {
            return "UI v2";
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
