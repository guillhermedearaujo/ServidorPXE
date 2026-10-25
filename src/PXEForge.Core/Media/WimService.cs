using System.Text;
using PXEForge.Core.Diagnostics;

namespace PXEForge.Core.Media;

/// <summary>
/// Patches a Windows Setup boot.wim so WinPE maps the media share and starts
/// setup unattended. Requires administrator rights because DISM mounts the WIM.
/// </summary>
public sealed class WimService
{
    private readonly LogHub _log;
    private readonly string _scratchRoot;

    public WimService(LogHub log, string stateRoot)
    {
        _log = log;
        _scratchRoot = Path.Combine(stateRoot, "wim-mount");
    }

    public async Task PatchAsync(
        string bootWimPath,
        string startnetContent,
        int imageIndex,
        CancellationToken ct)
    {
        if (!WindowsHelper.IsAdministrator())
        {
            throw new UnauthorizedAccessException(
                "Montar e alterar o boot.wim requer privilégios de administrador. " +
                "Reinicie o PXEForge como administrador.");
        }

        if (!File.Exists(bootWimPath))
        {
            throw new FileNotFoundException("boot.wim não encontrado.", bootWimPath);
        }

        Directory.CreateDirectory(_scratchRoot);
        var mountDir = Path.Combine(_scratchRoot, "mount-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(mountDir);
        var scratchDir = Path.Combine(_scratchRoot, "scratch");
        Directory.CreateDirectory(scratchDir);

        var fullWim = Path.GetFullPath(bootWimPath);
        var fullMount = Path.GetFullPath(mountDir);
        var fullScratch = Path.GetFullPath(scratchDir);

        _log.Info("wim", $"montando {Path.GetFileName(fullWim)} (índice {imageIndex})");
        var dismArgs = $"/English /Mount-Image /ImageFile:\"{fullWim}\" /Index:{imageIndex} /MountDir:\"{fullMount}\" /ScratchDir:\"{fullScratch}\"";
        _log.Info("wim", $"DISM: {dismArgs}");

        try
        {
            await IsoIngestService.RunProcessAsync(
                "dism.exe",
                new[]
                {
                    "/English",
                    "/Mount-Image",
                    "/ImageFile:" + fullWim,
                    "/Index:" + imageIndex.ToString(),
                    "/MountDir:" + fullMount,
                    "/ScratchDir:" + fullScratch
                },
                ct);

            var system32 = Path.Combine(fullMount, "Windows", "System32");
            if (!Directory.Exists(system32))
            {
                throw new InvalidOperationException($"Imagem {imageIndex} não parece ser um WinPE válido (sem Windows\\System32).");
            }

            await File.WriteAllTextAsync(
                Path.Combine(system32, "startnet.cmd"),
                startnetContent,
                Encoding.ASCII,
                ct);

            // Setup images launch setup.exe through winpeshl.ini; replacing it
            // with our own launcher is what makes the deployment unattended.
            await File.WriteAllTextAsync(
                Path.Combine(system32, "winpeshl.ini"),
                "[LaunchApps]\r\n%SYSTEMROOT%\\System32\\wpeinit.exe\r\n%SYSTEMROOT%\\System32\\cmd.exe, /c %SYSTEMROOT%\\System32\\startnet.cmd\r\n",
                Encoding.ASCII,
                ct);

            _log.Info("wim", "startnet.cmd e winpeshl.ini injetados; gravando alterações...");
            await IsoIngestService.RunProcessAsync(
                "dism.exe",
                new[] { "/English", "/Unmount-Image", "/MountDir:" + fullMount, "/Commit" },
                ct);

            _log.Info("wim", "boot.wim atualizado com sucesso");
        }
        catch
        {
            try
            {
                await IsoIngestService.RunProcessAsync(
                    "dism.exe",
                    new[] { "/English", "/Unmount-Image", "/MountDir:" + fullMount, "/Discard" },
                    CancellationToken.None);
                _log.Warn("wim", "montagem descartada após falha");
            }
            catch
            {
                // Best effort cleanup.
            }

            throw;
        }
        finally
        {
            try
            {
                if (Directory.Exists(mountDir) && !Directory.EnumerateFileSystemEntries(mountDir).Any())
                {
                    Directory.Delete(mountDir, true);
                }
            }
            catch
            {
                // Leave it for manual cleanup.
            }
        }
    }

    public async Task<IReadOnlyList<(int Index, string Name)>> ListImagesAsync(string wimPath, CancellationToken ct)
    {
        var fullWim = Path.GetFullPath(wimPath);
        var output = await IsoIngestService.RunProcessAsync(
            "dism.exe",
            new[] { "/English", "/Get-WimInfo", "/WimFile:" + fullWim },
            ct);

        var result = new List<(int, string)>();
        int? currentIndex = null;
        foreach (var raw in output.Split('\n', '\r'))
        {
            var line = raw.Trim();
            if (line.StartsWith("Index", StringComparison.OrdinalIgnoreCase))
            {
                var colon = line.IndexOf(':');
                if (colon > 0 && int.TryParse(line[(colon + 1)..].Trim(), out var index))
                {
                    currentIndex = index;
                }
            }
            else if (currentIndex is not null && line.StartsWith("Name", StringComparison.OrdinalIgnoreCase))
            {
                var colon = line.IndexOf(':');
                if (colon > 0)
                {
                    result.Add((currentIndex.Value, line[(colon + 1)..].Trim()));
                    currentIndex = null;
                }
            }
        }

        return result;
    }
}
