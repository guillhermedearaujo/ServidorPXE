using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using PXEForge.Core.Configuration;
using PXEForge.Core.Diagnostics;

namespace PXEForge.Core.Media;

public sealed record IngestProgress(string Stage, string Detail, long Copied, long Total);

public sealed record IngestResult(
    string Source,
    string BootWim,
    string? InstallImage,
    IReadOnlyList<string> ImageNames,
    IReadOnlyList<string> Warnings,
    string? MountedDrive);

/// <summary>
/// Turns a Windows ISO (or an already extracted folder) into the content tree
/// that the boot chain needs. Mounting and copying are separated so a failed
/// copy never leaves the operator guessing.
/// </summary>
public sealed class IsoIngestService
{
    private readonly PxeConfig _config;
    private readonly LogHub _log;
    private readonly ContentLayout _layout;

    public IsoIngestService(PxeConfig config, LogHub log)
    {
        _config = config;
        _log = log;
        _layout = new ContentLayout(config.ResolvedContentRoot);
    }

    public async Task<IngestResult> IngestAsync(
        string sourcePath,
        IProgress<IngestProgress>? progress,
        CancellationToken ct)
    {
        _layout.Ensure();
        var warnings = new List<string>();
        string? mountedDrive = null;
        string? mountIso = null;

        try
        {
            string root;
            if (Directory.Exists(sourcePath))
            {
                root = Path.GetFullPath(sourcePath);
                _log.Info("media", $"origem tratada como pasta ja extraida: {root}");
            }
            else
            {
                if (!File.Exists(sourcePath))
                {
                    throw new FileNotFoundException("ISO nao encontrada.", sourcePath);
                }

                if (!OperatingSystem.IsWindows())
                {
                    throw new PlatformNotSupportedException("A montagem de ISO requer Windows.");
                }

                var free = GetFreeSpace(_layout.Root);
                var isoSize = new FileInfo(sourcePath).Length;
                var minimum = isoSize + 4L * 1024 * 1024 * 1024;
                if (free >= 0 && free < minimum)
                {
                    throw new IOException(
                        $"Espaco insuficiente em {Path.GetPathRoot(_layout.Root)}. " +
                        $"ISO: {Format(isoSize)}, necessario: {Format(minimum)}, livre: {Format(free)}.");
                }

                progress?.Report(new IngestProgress("mount", "Montando ISO...", 0, 0));
                mountedDrive = await MountIsoAsync(sourcePath, ct);
                mountIso = sourcePath;
                root = mountedDrive + Path.DirectorySeparatorChar;
                _log.Info("media", $"ISO montada em {mountedDrive}");
            }

            var sourceBoot = Path.Combine(root, "sources", "boot.wim");
            if (!File.Exists(sourceBoot))
            {
                throw new FileNotFoundException("A ISO nao tem sources\\boot.wim.", sourceBoot);
            }

            var install = FindInstallImage(root)
                ?? throw new FileNotFoundException("A ISO nao tem sources\\install.wim|esd|swm.", Path.Combine(root, "sources"));

            var installSize = new FileInfo(install).Length;
            progress?.Report(new IngestProgress("copy", "Copiando boot.wim...", 0, installSize));

            await CopyFileAsync(sourceBoot, Path.Combine(_layout.WinpeDir, "boot.wim"), null, ct);
            await CopyIfExistsAsync(root, "boot", "boot.sdi", _layout.WinpeDir, "boot.sdi", ct);
            await CopyIfExistsAsync(root, "boot", "bcd", _layout.WinpeDir, "BCD-BIOS", ct);
            await CopyIfExistsAsync(root, "efi", "microsoft/boot/bcd", _layout.WinpeDir, "BCD-EFI", ct);
            await CopyIfExistsAsync(root, "", "bootmgr", _layout.WinpeDir, "bootmgr", ct);
            await CopyIfExistsAsync(root, "efi/microsoft/boot", "bootmgfw.efi", _layout.WinpeDir, "bootmgfw.efi", ct);
            await CopyIfExistsAsync(root, "boot/fonts", "wgl4_boot.ttf", _layout.FontsDir, "wgl4_boot.ttf", ct);

            if (!File.Exists(Path.Combine(_layout.WinpeDir, "BCD-EFI")))
            {
                warnings.Add("BCD-EFI nao encontrado na ISO; boot UEFI pode falhar.");
            }

            if (!File.Exists(Path.Combine(_layout.WinpeDir, "BCD-BIOS")))
            {
                warnings.Add("BCD-BIOS nao encontrado na ISO; boot BIOS pode falhar.");
            }

            progress?.Report(new IngestProgress("copy", "Copiando imagem de instalacao...", 0, installSize));
            var installTarget = Path.Combine(_layout.MediaSourcesDir, Path.GetFileName(install));
            await CopyFileAsync(
                install,
                installTarget,
                new Progress<long>(copied => progress?.Report(
                    new IngestProgress("copy", Path.GetFileName(install), copied, installSize))),
                ct);

            // Split WIM sets are useless without their siblings.
            if (install.EndsWith(".swm", StringComparison.OrdinalIgnoreCase))
            {
                var prefix = Path.GetFileNameWithoutExtension(install);
                var stem = Regex.Replace(prefix, @"\d+$", "");
                foreach (var swm in Directory.EnumerateFiles(Path.GetDirectoryName(install)!, $"{stem}*.swm"))
                {
                    if (string.Equals(swm, install, StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    await CopyFileAsync(swm, Path.Combine(_layout.MediaSourcesDir, Path.GetFileName(swm)), null, ct);
                }
            }

            var imageNames = await ReadImageNamesAsync(installTarget, ct);
            if (imageNames.Count == 1)
            {
                warnings.Add(
                    $"A imagem de instalacao tem um unico nome ({imageNames[0]}); isso costuma indicar ISO repack, " +
                    "nao a midia oficial da Microsoft.");
            }

            var result = new IngestResult(
                sourcePath,
                Path.Combine(_layout.WinpeDir, "boot.wim"),
                installTarget,
                imageNames,
                warnings,
                mountedDrive);

            await File.WriteAllTextAsync(
                Path.Combine(_config.ResolvedStateRoot, "media-manifest.json"),
                System.Text.Json.JsonSerializer.Serialize(result, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }),
                ct);

            _log.Info("media", $"midia preparada: boot.wim + {Path.GetFileName(installTarget)} ({Format(installSize)})");
            foreach (var warning in warnings)
            {
                _log.Warn("media", warning);
            }

            return result;
        }
        finally
        {
            if (mountIso is not null)
            {
                try
                {
                    await DismountIsoAsync(mountIso, CancellationToken.None);
                    _log.Info("media", "ISO desmontada");
                }
                catch (Exception ex)
                {
                    _log.Warn("media", $"falha ao desmontar a ISO: {ex.Message}");
                }
            }
        }
    }

    public static string? FindInstallImage(string root)
    {
        var sources = Path.Combine(root, "sources");
        if (!Directory.Exists(sources))
        {
            return null;
        }

        foreach (var name in new[] { "install.wim", "install.esd" })
        {
            var candidate = Path.Combine(sources, name);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return Directory.EnumerateFiles(sources, "install*.swm")
            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault();
    }

    public static async Task<IReadOnlyList<string>> ReadImageNamesAsync(string wimPath, CancellationToken ct)
    {
        try
        {
            var output = await RunProcessAsync(
                "dism.exe",
                new[] { "/English", "/Get-WimInfo", $"/WimFile:{wimPath}" },
                ct);

            return Regex.Matches(output, @"^\s*Name\s*:\s*(.+?)\s*$", RegexOptions.Multiline)
                .Select(m => m.Groups[1].Value.Trim())
                .Where(s => s.Length > 0)
                .Distinct()
                .ToList();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    private async Task<string> MountIsoAsync(string isoPath, CancellationToken ct)
    {
        var script = "$ErrorActionPreference='Stop';" +
                     "$img=Mount-DiskImage -ImagePath $env:PF_ISO -PassThru;" +
                     "$v=$img|Get-Volume;" +
                     "if(-not $v.DriveLetter){throw 'volume sem letra de unidade'};" +
                     "Write-Output ('DRIVE='+$v.DriveLetter)";
        var output = await RunProcessAsync(
            "powershell.exe",
            new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script },
            ct,
            new Dictionary<string, string> { ["PF_ISO"] = isoPath });

        var line = output.Split('\n')
            .Select(l => l.Trim())
            .FirstOrDefault(l => l.StartsWith("DRIVE=", StringComparison.OrdinalIgnoreCase));

        if (line is null)
        {
            throw new InvalidOperationException("Nao foi possivel montar a ISO. Execute como administrador. " + output.Trim());
        }

        return line["DRIVE=".Length..].Trim() + ":";
    }

    private static async Task DismountIsoAsync(string isoPath, CancellationToken ct)
    {
        await RunProcessAsync(
            "powershell.exe",
            new[]
            {
                "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
                "Dismount-DiskImage -ImagePath $env:PF_ISO | Out-Null"
            },
            ct,
            new Dictionary<string, string> { ["PF_ISO"] = isoPath });
    }

    private static async Task CopyIfExistsAsync(
        string root,
        string fromDir,
        string fromName,
        string toDir,
        string toName,
        CancellationToken ct)
    {
        var relative = string.IsNullOrEmpty(fromDir) ? fromName : Path.Combine(fromDir, fromName);
        var source = Path.Combine(root, relative);
        if (File.Exists(source))
        {
            await CopyFileAsync(source, Path.Combine(toDir, toName), null, ct);
        }
    }

    private static async Task CopyFileAsync(
        string source,
        string destination,
        IProgress<long>? progress,
        CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        const int bufferSize = 1024 * 1024;
        var buffer = new byte[bufferSize];
        long copied = 0;

        await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, bufferSize, FileOptions.SequentialScan);
        await using var output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, bufferSize, FileOptions.SequentialScan);
        int read;
        while ((read = await input.ReadAsync(buffer, ct)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, read), ct);
            copied += read;
            progress?.Report(copied);
        }
    }

    private static long GetFreeSpace(string path)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(path));
            return string.IsNullOrEmpty(root) ? -1 : new DriveInfo(root).AvailableFreeSpace;
        }
        catch
        {
            return -1;
        }
    }

    private static string Format(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double value = bytes;
        var index = 0;
        while (value >= 1024 && index < units.Length - 1)
        {
            value /= 1024;
            index++;
        }

        return value.ToString("0.0", CultureInfo.InvariantCulture) + " " + units[index];
    }

    internal static async Task<string> RunProcessAsync(
        string fileName,
        IEnumerable<string> arguments,
        CancellationToken ct,
        IDictionary<string, string>? environment = null)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        if (environment is not null)
        {
            foreach (var (key, value) in environment)
            {
                startInfo.Environment[key] = value;
            }
        }

        using var process = new Process { StartInfo = startInfo };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        process.OutputDataReceived += (_, e) => { if (e.Data is not null) stdout.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) stderr.AppendLine(e.Data); };

        if (!process.Start())
        {
            throw new InvalidOperationException($"Nao foi possivel iniciar {fileName}.");
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        await process.WaitForExitAsync(ct);

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"{Path.GetFileName(fileName)} retornou {process.ExitCode}: {stderr.ToString().Trim()} {stdout.ToString().Trim()}".Trim());
        }

        return stdout.ToString();
    }
}
