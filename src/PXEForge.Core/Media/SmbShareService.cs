using System.Net;
using System.Text;
using PXEForge.Core.Diagnostics;

namespace PXEForge.Core.Media;

/// <summary>
/// Read-only SMB share used by Windows Setup inside WinPE. A share is required
/// because setup.exe cannot install from an HTTP URL.
/// </summary>
public sealed class SmbShareService
{
    private readonly LogHub _log;

    public SmbShareService(LogHub log)
    {
        _log = log;
    }

    public async Task EnsureShareAsync(string shareName, string localPath, CancellationToken ct)
    {
        if (!WindowsHelper.IsAdministrator())
        {
            throw new UnauthorizedAccessException("Criar o share SMB requer administrador.");
        }

        localPath = Path.GetFullPath(localPath);
        Directory.CreateDirectory(localPath);

        // Tenta com PowerShell/SMB primeiro
        var script =
            "$ErrorActionPreference='Stop';" +
            "$name=$env:PF_SHARE; $path=$env:PF_PATH;" +
            "$existing = Get-SmbShare -Name $name -ErrorAction SilentlyContinue;" +
            "if (-not $existing) {" +
            "  try { New-SmbShare -Name $name -Path $path -ReadAccess 'BUILTIN\\Administrators' -Force | Out-Null; 'CREATED' }" +
            "  catch { try { New-SmbShare -Name $name -Path $path -Force | Out-Null; 'CREATED_FALLBACK' } catch { throw $_ } }" +
            "} else {" +
            "  try { Set-SmbShare -Name $name -Path $path -Force -EncryptData $false | Out-Null } catch { }" +
            "  'EXISTS'" +
            "}";

        try
        {
            var output = await IsoIngestService.RunProcessAsync(
                "powershell.exe",
                new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script },
                ct,
                new Dictionary<string, string>
                {
                    ["PF_SHARE"] = shareName,
                    ["PF_PATH"] = localPath
                });

            if (output.Contains("CREATED", StringComparison.OrdinalIgnoreCase))
            {
                _log.Info("smb", $"share {shareName} CRIADO em {localPath} (PowerShell/SMB)");
            }
            else
            {
                _log.Info("smb", $"share {shareName} já existia ou foi atualizado em {localPath} (PowerShell/SMB)");
            }

            return;
        }
        catch (Exception ex)
        {
            _log.Warn("smb", $"New-SmbShare falhou: {ex.Message}");
            _log.Warn("smb", "tentando fallback com 'net share'...");
        }

        // Fallback: net share (sem GRANT Everyone para evitar erro 1332)
        var netScript =
            "@echo off\r\n" +
            "net share " + shareName + "=" + localPath + " /REMARK:\"PXEForge\" 2>&1\r\n" +
            "exit /b %ERRORLEVEL%\r\n";

        var tmp = Path.Combine(Path.GetTempPath(), "pxeforge-netsmb-" + Guid.NewGuid().ToString("N") + ".bat");
        await File.WriteAllTextAsync(tmp, netScript, Encoding.ASCII, ct);

        try
        {
            await IsoIngestService.RunProcessAsync("cmd.exe", new[] { "/c", tmp }, ct);
            _log.Info("smb", $"share {shareName} configurado via 'net share' em {localPath} (sem grant explícito)");
        }
        finally
        {
            try { File.Delete(tmp); } catch { }
        }
    }

    public static string BuildUncPath(IPAddress serverAddress, string shareName) =>
        $@"\\{serverAddress}\{shareName}";
}
