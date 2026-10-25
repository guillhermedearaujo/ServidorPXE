using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using PXEForge.Core.Configuration;
using PXEForge.Core.Diagnostics;
using PXEForge.Core.Media;
using PXEForge.Core.Monitoring;
using PXEForge.Core.Net;
using PXEForge.Core.Security;

namespace PXEForge.Core;

public enum EngineState
{
    Stopped,
    Starting,
    Running,
    Degraded,
    Error
}

public sealed record EngineStatus(
    string State,
    string ServerName,
    string ServerAddress,
    int HttpPort,
    int TftpPort,
    int DhcpPort,
    bool HttpRunning,
    bool TftpRunning,
    bool DhcpRunning,
    long DhcpRequests,
    long TftpTransfers,
    long TftpBytes,
    bool MediaReady,
    bool Administrator,
    IReadOnlyList<string> Problems,
    DateTimeOffset StartedAt);

public sealed record PrepareResult(
    IngestResult Ingest,
    bool BootWimPatched,
    bool ShareReady,
    IReadOnlyList<string> Warnings);

/// <summary>
/// Orchestrates the three network stages and the media preparation pipeline.
/// </summary>
public sealed class PxeEngine : IAsyncDisposable
{
    private readonly PxeConfig _config;
    private readonly LogHub _log;
    private readonly ContentLayout _layout;
    private BootHttpServer? _http;
    private TftpServer? _tftp;
    private ProxyDhcpServer? _dhcp;
    private readonly FirewallService _firewall;
    private readonly ResourceMonitor _resourceMonitor = new();
    private readonly List<string> _problems = new();
    private EngineState _state = EngineState.Stopped;
    private DateTimeOffset _startedAt;
    private IPAddress _serverAddress = IPAddress.Loopback;

    public PxeEngine(PxeConfig config, LogHub log)
    {
        _config = config;
        _log = log;
        _layout = new ContentLayout(config.ResolvedContentRoot);
        _firewall = new FirewallService(log);
    }

    public PxeConfig Config => _config;
    public EngineState State => _state;
    public IPAddress ServerAddress => _serverAddress;
    public ContentLayout Layout => _layout;
    public FirewallService Firewall => _firewall;

    public bool ShouldThrottle() => _resourceMonitor.GetSnapshot(_tftp?.ActiveSessions ?? 0, _http?.ActiveHttp ?? 0, _dhcp?.RequestsHandled ?? 0, _tftp?.Transfers ?? 0, _tftp?.BytesSent ?? 0).IsThrottled;

    public ResourceSnapshot GetResourceSnapshot() => _resourceMonitor.GetSnapshot(_tftp?.ActiveSessions ?? 0, _http?.ActiveHttp ?? 0, _dhcp?.RequestsHandled ?? 0, _tftp?.Transfers ?? 0, _tftp?.BytesSent ?? 0);

    public EngineStatus GetStatus() => new(
        _state.ToString(),
        _config.ServerName,
        _serverAddress.ToString(),
        _config.HttpPort,
        _config.TftpPort,
        _config.DhcpPort,
        _http is not null,
        _tftp?.IsRunning == true,
        _dhcp?.IsRunning == true,
        _dhcp?.RequestsHandled ?? 0,
        _tftp?.Transfers ?? 0,
        _tftp?.BytesSent ?? 0,
        _layout.MissingBootPayload().Count == 0 && _layout.HasInstallImage(),
        WindowsHelper.IsAdministrator(),
        _problems.ToArray(),
        _startedAt);

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_state is EngineState.Running or EngineState.Degraded)
        {
            return;
        }

        _state = EngineState.Starting;
        _problems.Clear();
        _startedAt = DateTimeOffset.Now;
        _layout.Ensure();
        Directory.CreateDirectory(_config.ResolvedStateRoot);
        _serverAddress = _config.ResolveBindAddress();

        _log.Info("core", $"{_config.ServerName} iniciando em {_serverAddress} " +
                          $"({(WindowsHelper.IsAdministrator() ? "administrador" : "SEM elevacao")})");

        if (_config.EnableHttp)
        {
            try
            {
                _http = new BootHttpServer(
                    _config,
                    IPAddress.Any,
                    _config.HttpPort,
                    _layout.Root,
                    _log,
                    GetStatus,
                    ShouldThrottle);
                await _http.StartAsync(ct);
            }
            catch (Exception ex)
            {
                _http = null;
                _problems.Add($"HTTP nao iniciou na porta {_config.HttpPort}: {ex.Message}");
                _log.Error("http", _problems[^1]);
            }
        }

        if (_config.EnableTftp)
        {
            try
            {
                _tftp = new TftpServer(IPAddress.Any, _config.TftpPort, _layout.Root, _log, ShouldThrottle);
                _tftp.Start();
            }
            catch (Exception ex)
            {
                _tftp = null;
                _problems.Add($"TFTP nao iniciou na porta {_config.TftpPort}: {DescribeSocketError(ex)}");
                _log.Error("tftp", _problems[^1]);
            }
        }

        if (_config.EnableProxyDhcp)
        {
            try
            {
                var resolver = new BootFileResolver(
                    _serverAddress,
                    _config.HttpPort,
                    _config.BootFileBios,
                    _config.BootFileUefi,
                    _config.BootFileArm64,
                    _config.IpxeScriptPath);
                _dhcp = new ProxyDhcpServer(IPAddress.Any, _config.DhcpPort, _serverAddress, resolver, _log);
                _dhcp.Start();
            }
            catch (Exception ex)
            {
                _dhcp = null;
                _problems.Add($"proxyDHCP nao iniciou na porta {_config.DhcpPort}: {DescribeSocketError(ex)}");
                _log.Error("dhcp", _problems[^1]);
            }
        }

        _state = _problems.Count == 0 ? EngineState.Running : EngineState.Degraded;
        _log.Info("core", $"estado: {_state}");
    }

    private static string DescribeSocketError(Exception ex)
    {
        if (ex is SocketException socket &&
            socket.SocketErrorCode is SocketError.AccessDenied)
        {
            return "acesso negado. Portas 67/69 exigem execucao como administrador.";
        }

        if (ex is UnauthorizedAccessException)
        {
            return "acesso negado. Execute como administrador.";
        }

        return ex.Message;
    }

    public async Task StopAsync()
    {
        if (_dhcp is not null)
        {
            await _dhcp.DisposeAsync();
            _dhcp = null;
        }

        if (_tftp is not null)
        {
            await _tftp.DisposeAsync();
            _tftp = null;
        }

        if (_http is not null)
        {
            await _http.DisposeAsync();
            _http = null;
        }

        _state = EngineState.Stopped;
        _log.Info("core", "servidor parado");
    }

    public async Task<PrepareResult> PrepareMediaAsync(
        string isoPath,
        IProgress<IngestProgress>? progress = null,
        CancellationToken ct = default)
    {
        _layout.Ensure();
        Directory.CreateDirectory(_config.ResolvedStateRoot);

        _log.Info("media", $"iniciando preparo: {isoPath}");
        var ingest = await new IsoIngestService(_config, _log).IngestAsync(isoPath, progress, ct);

        var installFileName = Path.GetFileName(ingest.InstallImage);
        var builder = new AutounattendBuilder(_config);
        var imageIndex = _config.ImageIndex > 0 ? _config.ImageIndex : 1;
        builder.WriteAnswerFiles(_layout.MediaDir, installFileName, imageIndex);
        _log.Info("media", "autounattend-uefi.xml e autounattend-bios.xml gravados");

        var unc = SmbShareService.BuildUncPath(_serverAddress, _config.SmbShareName);
        var startnet = builder.BuildStartnet(unc, installFileName, _config.SmbUser, _config.SmbPassword);
        var startnetPath = Path.Combine(_config.ResolvedStateRoot, "startnet.cmd");
        await File.WriteAllTextAsync(startnetPath, startnet, ct);
        _log.Info("media", $"startnet de referencia: {startnetPath}");

        var warnings = new List<string>(ingest.Warnings);
        var patched = false;

        if (_config.PatchBootWim)
        {
            try
            {
                var wim = new WimService(_log, _config.ResolvedStateRoot);
                await wim.PatchAsync(ingest.BootWim, startnet, _config.BootWimIndex, ct);
                patched = true;
            }
            catch (Exception ex)
            {
                warnings.Add("boot.wim NAO foi personalizado: " + ex.Message);
                _log.Warn("wim", warnings[^1]);
            }
        }
        else
        {
            warnings.Add("PatchBootWim desligado: o WinPE original nao sabe montar o share automaticamente.");
        }

        var shareReady = false;
        if (WindowsHelper.IsAdministrator())
        {
            try
            {
                await new SmbShareService(_log).EnsureShareAsync(_config.SmbShareName, _layout.MediaDir, ct);
                shareReady = true;
            }
            catch (Exception ex)
            {
                warnings.Add("share SMB nao criado: " + ex.Message);
                _log.Warn("smb", warnings[^1]);
            }
        }
        else
        {
            warnings.Add($"share SMB nao criado (sem elevacao). Crie manualmente: {unc} -> {_layout.MediaDir}");
        }

        var manifest = new
        {
            preparedAt = DateTimeOffset.Now,
            source = ingest.Source,
            bootWim = ingest.BootWim,
            installImage = ingest.InstallImage,
            imageNames = ingest.ImageNames,
            bootWimPatched = patched,
            share = unc,
            shareReady,
            warnings
        };

        await File.WriteAllTextAsync(
            Path.Combine(_config.ResolvedStateRoot, "prepare-manifest.json"),
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }),
            ct);

        return new PrepareResult(ingest, patched, shareReady, warnings);
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
    }
}
