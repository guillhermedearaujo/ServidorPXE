using System.Diagnostics;
using System.Text;
using PXEForge.Core.Diagnostics;

namespace PXEForge.Core.Security;

public sealed class FirewallRule
{
    public string Name { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Direction { get; set; } = "Inbound";
    public string Protocol { get; set; } = "UDP";
    public string LocalPort { get; set; } = string.Empty;
    public bool Enabled { get; set; }
    public string Action { get; set; } = "Allow";
}

public sealed class FirewallService
{
    private readonly LogHub _log;

    public FirewallService(LogHub log)
    {
        _log = log;
    }

    public async Task<IReadOnlyList<FirewallRule>> GetRulesAsync(CancellationToken ct = default)
    {
        var script = @"$ErrorActionPreference='SilentlyContinue';
$rules = @('PXEForge-DHCP','PXEForge-TFTP','PXEForge-HTTP');
foreach($r in $rules){
  $f = Get-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue
  if($f){
    $p = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $f -ErrorAction SilentlyContinue
    $a = Get-NetFirewallAction -AssociatedNetFirewallRule $f -ErrorAction SilentlyContinue
    [PSCustomObject]@{Name=$r;DisplayName=$r;Direction=$f.Direction;Protocol=$p.Protocol;LocalPort=$p.LocalPort;Enabled=($f.Enabled -eq 'True');Action=$a.Action}
  }
}";
        var output = await RunPsAsync(script, ct);
        var rules = new List<FirewallRule>();
        // simple parse
        try
        {
            var json = "[]";
            // try convert from objects not directly available; use netsh fallback simplified
        }
        catch { }
        
        // fallback: check existence
        foreach (var name in new[] { "PXEForge-DHCP", "PXEForge-TFTP", "PXEForge-HTTP" })
        {
            var exists = await RuleExistsAsync(name, ct);
            if (exists)
                rules.Add(new FirewallRule { Name = name, DisplayName = name, Enabled = true, Action = "Allow" });
        }
        return rules;
    }

    public async Task<bool> RuleExistsAsync(string displayName, CancellationToken ct = default)
    {
        var script = $"(Get-NetFirewallRule -DisplayName '{displayName}' -ErrorAction SilentlyContinue) -ne $null";
        var output = await RunPsAsync(script, ct);
        return output.Trim().Equals("True", StringComparison.OrdinalIgnoreCase);
    }

    public async Task EnsureRulesAsync(int httpPort = 8082, CancellationToken ct = default)
    {
        if (!PXEForge.Core.Media.WindowsHelper.IsAdministrator())
        {
            throw new UnauthorizedAccessException("Criar regras de firewall requer privilégios de administrador.");
        }

        var script = $@"$ErrorActionPreference='Stop'
function New-RuleIfMissing($name,$dir,$proto,$port){{
  if(-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)){{
    New-NetFirewallRule -DisplayName $name -Direction $dir -Action Allow -Protocol $proto -LocalPort $port -Profile Any | Out-Null
    Write-Output 'CREATED:'+$name
  }}else{{Write-Output 'EXISTS:'+$name}}
}}
New-RuleIfMissing 'PXEForge-DHCP' Inbound UDP 67
New-RuleIfMissing 'PXEForge-TFTP' Inbound UDP 69
New-RuleIfMissing 'PXEForge-HTTP' Inbound TCP {httpPort}
New-RuleIfMissing 'PXEForge-SMB' Inbound TCP 445";

        var output = await RunPsAsync(script, ct);
        _log.Info("firewall", output.Replace("\r\n", " | "));
    }

    public async Task RemoveRulesAsync(CancellationToken ct = default)
    {
        if (!PXEForge.Core.Media.WindowsHelper.IsAdministrator())
        {
            throw new UnauthorizedAccessException("Remover regras de firewall requer privilégios de administrador.");
        }

        var script = @"$ErrorActionPreference='SilentlyContinue'
@('PXEForge-DHCP','PXEForge-TFTP','PXEForge-HTTP','PXEForge-SMB') | ForEach-Object {
  Remove-NetFirewallRule -DisplayName $_ -ErrorAction SilentlyContinue
}
Write-Output 'REMOVED'";
        var output = await RunPsAsync(script, ct);
        _log.Info("firewall", output.Trim());
    }

    public string GenerateRequestScript(int httpPort = 8082)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Solicitação de liberação de firewall para PXEForge");
        sb.AppendLine("# Execute este script como Administrador OU encaminhe ao time de Segurança/Redes");
        sb.AppendLine("# Gerado por PXEForge em " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        sb.AppendLine();
        sb.AppendLine("param([switch]$Apply)");
        sb.AppendLine("if($Apply){");
        sb.AppendLine("  if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){");
        sb.AppendLine("    Write-Error 'Execute como Administrador'; exit 1");
        sb.AppendLine("  }");
        sb.AppendLine("  New-NetFirewallRule -DisplayName 'PXEForge-DHCP' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 67 -Profile Any -Description 'PXEForge proxyDHCP' -ErrorAction SilentlyContinue");
        sb.AppendLine("  New-NetFirewallRule -DisplayName 'PXEForge-TFTP' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 69 -Profile Any -Description 'PXEForge TFTP' -ErrorAction SilentlyContinue");
        sb.AppendLine($"  New-NetFirewallRule -DisplayName 'PXEForge-HTTP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort {httpPort} -Profile Any -Description 'PXEForge HTTP Boot' -ErrorAction SilentlyContinue");
        sb.AppendLine("  New-NetFirewallRule -DisplayName 'PXEForge-SMB' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Profile Any -Description 'PXEForge SMB Media' -ErrorAction SilentlyContinue");
        sb.AppendLine("  Write-Host 'Regras aplicadas.' -ForegroundColor Green");
        sb.AppendLine("}else{");
        sb.AppendLine("  Write-Host 'Modo simulacao. Use -Apply para criar as regras.' -ForegroundColor Yellow");
        sb.AppendLine("  Write-Host 'Regras solicitadas:'");
        sb.AppendLine("  Write-Host '  UDP Inbound 67 (PXEForge-DHCP)'");
        sb.AppendLine("  Write-Host '  UDP Inbound 69 (PXEForge-TFTP)'");
        sb.AppendLine($"  Write-Host '  TCP Inbound {httpPort} (PXEForge-HTTP)'");
        sb.AppendLine("  Write-Host '  TCP Inbound 445 (PXEForge-SMB)'");
        sb.AppendLine("}");
        return sb.ToString();
    }

    private static async Task<string> RunPsAsync(string script, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " + Escape(script),
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var proc = new Process { StartInfo = psi };
        proc.Start();
        var output = await proc.StandardOutput.ReadToEndAsync(ct);
        await proc.WaitForExitAsync(ct);
        return output;
    }

    private static string Escape(string s) => "\"" + s.Replace("\"", "'") + "\"";
}
