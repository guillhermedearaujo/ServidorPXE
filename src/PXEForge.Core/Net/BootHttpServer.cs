using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using PXEForge.Core.Configuration;
using PXEForge.Core.Diagnostics;

namespace PXEForge.Core.Net;

public sealed class BootHttpServer : IAsyncDisposable
{
    private readonly PxeConfig _config;
    private readonly IPAddress _bindAddress;
    private readonly int _port;
    private readonly string _contentRoot;
    private readonly LogHub _log;
    private readonly Func<object> _statusProvider;
    private readonly Func<bool>? _shouldThrottle;
    private WebApplication? _app;
    private int _activeHttp;

    public BootHttpServer(PxeConfig config, IPAddress bindAddress, int port, string contentRoot, LogHub log, Func<object> statusProvider, Func<bool>? shouldThrottle = null)
    {
        _config = config;
        _bindAddress = bindAddress;
        _port = port;
        _contentRoot = contentRoot;
        _log = log;
        _statusProvider = statusProvider;
        _shouldThrottle = shouldThrottle;
    }

    public int Port => _port;
    public bool IsRunning => _app is not null;
    public int ActiveHttp => Volatile.Read(ref _activeHttp);

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_app is not null) return;
        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions { Args = Array.Empty<string>(), ContentRootPath = AppContext.BaseDirectory, EnvironmentName = Environments.Production });
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(options => { options.Listen(_bindAddress, _port); options.AddServerHeader = false; options.Limits.MinResponseDataRate = null; options.Limits.MinRequestBodyDataRate = null; });
        var app = builder.Build();
        app.MapGet("/", () => Results.Text($"{_config.ServerName} PXEForge\nboot script: /boot.ipxe\nstatus: /api/status\n", "text/plain", Encoding.UTF8));
        app.MapGet("/health.txt", () => Results.Text("OK", "text/plain", Encoding.UTF8));
        app.MapGet("/boot.ipxe", () => Results.Text(BuildIpxeScript(), "text/plain", Encoding.UTF8));
        app.MapGet("/api/status", () => Results.Json(_statusProvider()));
        app.MapGet("/health", () => Results.Json(new { ok = true }));
        app.MapGet("/api/logs", () => Results.Json(_log.Recent(100).Select(e => new { ts = e.Timestamp, level = e.Level.ToString().ToLowerInvariant(), component = e.Component, message = e.Message })));
        app.MapGet("/files/{**path}", (HttpContext ctx, string path) => {
            if (_shouldThrottle?.Invoke() == true) { ctx.Response.StatusCode = 503; ctx.Response.Headers["Retry-After"] = "10"; return Results.Text("Servidor sobrecarregado. Tente novamente em instantes.", "text/plain"); }
            var fullPath = ResolveSafePath(path);
            if (fullPath is null || !File.Exists(fullPath)) return Results.NotFound();
            Interlocked.Increment(ref _activeHttp);
            try { return Results.File(fullPath, GetContentType(fullPath), enableRangeProcessing: true); }
            finally { Interlocked.Decrement(ref _activeHttp); }
        });
        _app = app;
        await app.StartAsync(ct);
        _log.Info("http", $"HTTP escutando em http://{_bindAddress}:{_port}/ (raiz {_contentRoot})");
    }

    public string BuildIpxeScript()
    {
        var baseUrl = $"http://{_bindAddress}:{_port}/files";
        var winpe = Path.Combine(_contentRoot, "winpe");
        var sb = new StringBuilder();
        sb.AppendLine("#!ipxe");
        sb.AppendLine($"# {_config.ServerName} - PXEForge test build");
        sb.AppendLine($"set srv http://{_bindAddress}:{_port}");
        sb.AppendLine("set base /files");
        sb.AppendLine("echo PXEForge: carregando WinPE...");
        sb.AppendLine("iseq  efi && set bcd BCD-EFI || set bcd BCD-BIOS");
        sb.AppendLine("kernel /winpe/wimboot || goto failed");
        if (File.Exists(Path.Combine(winpe, "bootmgr"))) sb.AppendLine("initrd --name bootmgr /winpe/bootmgr || goto failed");
        var uefiBootManager = Path.Combine(winpe, "bootmgfw.efi");
        if (File.Exists(uefiBootManager)) sb.AppendLine("initrd --name bootmgfw.efi /winpe/bootmgfw.efi || goto failed");
        sb.AppendLine("initrd --name BCD /winpe/ || goto failed");
        sb.AppendLine("initrd --name boot.sdi /winpe/boot.sdi || goto failed");
        sb.AppendLine("initrd --name boot.wim /winpe/boot.wim || goto failed");
        var font = Path.Combine(winpe, "fonts", "wgl4_boot.ttf");
        if (File.Exists(font)) sb.AppendLine("initrd --name wgl4_boot.ttf /winpe/fonts/wgl4_boot.ttf");
        sb.AppendLine("imgargs wimboot quiet");
        sb.AppendLine("boot || goto failed");
        sb.AppendLine(":failed");
        sb.AppendLine("echo PXEForge: falha ao carregar o WinPE");
        sb.AppendLine("prompt");
        sb.AppendLine("exit");
        return sb.ToString();
    }

    private string? ResolveSafePath(string requested)
    {
        try
        {
            var root = Path.GetFullPath(_contentRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var relative = requested.Replace('/', Path.DirectorySeparatorChar).TrimStart(Path.DirectorySeparatorChar);
            var full = Path.GetFullPath(Path.Combine(root, relative));
            return full.StartsWith(root, StringComparison.OrdinalIgnoreCase) ? full : null;
        }
        catch { return null; }
    }

    private static string GetContentType(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".ipxe" => "text/plain",
        ".wim" or ".swm" => "application/octet-stream",
        ".efi" or ".kpxe" or ".kkpxe" => "application/octet-stream",
        ".ttf" => "font/ttf",
        ".json" => "application/json",
        ".txt" or ".md" => "text/plain",
        _ => "application/octet-stream"
    };

    public async ValueTask DisposeAsync()
    {
        if (_app is null) return;
        try { await _app.StopAsync(TimeSpan.FromSeconds(3)); await _app.DisposeAsync(); }
        catch { }
        finally { _app = null; _log.Info("http", "HTTP parado"); }
    }
}
