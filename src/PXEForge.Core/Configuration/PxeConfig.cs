using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PXEForge.Core.Configuration;

/// <summary>
/// Persistent configuration. Deliberately small and JSON based so operators can
/// inspect and edit it with any text editor.
/// </summary>
public sealed class PxeConfig
{
    public string ServerName { get; set; } = "PXEFORGE";

    /// <summary>"auto" or an explicit IPv4 address of the serving interface.</summary>
    public string BindAddress { get; set; } = "auto";

    public int HttpPort { get; set; } = 8082;
    public int TftpPort { get; set; } = 69;
    public int DhcpPort { get; set; } = 67;

    /// <summary>Absolute or relative to the executable directory.</summary>
    public string ContentRoot { get; set; } = "content";
    public string StateRoot { get; set; } = "state";

    public bool EnableProxyDhcp { get; set; } = true;
    public bool EnableTftp { get; set; } = true;
    public bool EnableHttp { get; set; } = true;

    // TFTP paths are relative to ContentRoot.
    public string BootFileBios { get; set; } = "ipxe/undionly.kpxe";
    public string BootFileUefi { get; set; } = "ipxe/ipxe.efi";
    public string BootFileArm64 { get; set; } = "ipxe/arm64-efi/ipxe.efi";

    /// <summary>Script returned when the requester is already iPXE (option 77).</summary>
    public string IpxeScriptPath { get; set; } = "/boot.ipxe";

    // SMB media share used by Windows Setup inside WinPE.
    public string SmbShareName { get; set; } = "PXEFORGE";
    public string SmbUser { get; set; } = "";
    public string SmbPassword { get; set; } = "";

    // Deployment profile.
    public string ProfileName { get; set; } = "Windows 11";
    public string ImageName { get; set; } = "";
    public int ImageIndex { get; set; } = 0;
    public string Locale { get; set; } = "pt-BR";
    public string TimeZone { get; set; } = "E. South America Standard Time";
    public string AdminUser { get; set; } = "deploy";
    public string AdminPassword { get; set; } = "";
    public bool WipeDisk { get; set; } = true;

    public string? LastIso { get; set; }
    public bool PatchBootWim { get; set; } = true;
    public int BootWimIndex { get; set; } = 2;

    /// <summary>
    /// Folder where content/state live. Must NOT be the single-file extraction
    /// directory: its name contains '=', which makes DISM reject /ImageFile paths.
    /// </summary>
    public static string AppDirectory
    {
        get
        {
            var exe = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exe))
            {
                var dir = Path.GetDirectoryName(exe);
                if (!string.IsNullOrEmpty(dir))
                {
                    return dir;
                }
            }

            return AppContext.BaseDirectory;
        }
    }

    [JsonIgnore]
    public string BaseDirectory { get; set; } = AppDirectory;

    [JsonIgnore]
    public string ResolvedContentRoot => Path.GetFullPath(Path.IsPathRooted(ContentRoot)
        ? ContentRoot
        : Path.Combine(BaseDirectory, ContentRoot));

    [JsonIgnore]
    public string ResolvedStateRoot => Path.GetFullPath(Path.IsPathRooted(StateRoot)
        ? StateRoot
        : Path.Combine(BaseDirectory, StateRoot));

    public static string DefaultPath => Path.Combine(AppDirectory, "pxeforge.config.json");

    public static PxeConfig Load(string? path = null)
    {
        path ??= DefaultPath;
        try
        {
            if (File.Exists(path))
            {
                var json = File.ReadAllText(path);
                var cfg = JsonSerializer.Deserialize<PxeConfig>(json, JsonOptions) ?? new PxeConfig();
                cfg.BaseDirectory = AppDirectory;
                return cfg;
            }
        }
        catch
        {
            // A broken config must not prevent the UI from opening.
        }

        return new PxeConfig { BaseDirectory = AppDirectory };
    }

    public void Save(string? path = null)
    {
        path ??= DefaultPath;
        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(dir))
        {
            Directory.CreateDirectory(dir);
        }

        var json = JsonSerializer.Serialize(this, JsonOptions);
        File.WriteAllText(path, json);
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    /// <summary>
    /// Resolves the IPv4 address that PXE clients should be pointed at.
    /// Preference order: explicit value, interface with a default gateway,
    /// then the first usable non-loopback IPv4 address.
    /// </summary>
    public IPAddress ResolveBindAddress()
    {
        if (!string.Equals(BindAddress, "auto", StringComparison.OrdinalIgnoreCase)
            && IPAddress.TryParse(BindAddress, out var explicitAddress))
        {
            return explicitAddress;
        }

        return DiscoverAddresses().FirstOrDefault() ?? IPAddress.Loopback;
    }

    public static IReadOnlyList<IPAddress> DiscoverAddresses()
    {
        var result = new List<(int score, IPAddress address)>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up)
                {
                    continue;
                }

                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                {
                    continue;
                }

                var props = nic.GetIPProperties();
                var hasGateway = props.GatewayAddresses.Any(g =>
                    g.Address.AddressFamily == AddressFamily.InterNetwork &&
                    !g.Address.Equals(IPAddress.Any));

                foreach (var unicast in props.UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork)
                    {
                        continue;
                    }

                    if (IPAddress.IsLoopback(unicast.Address) || unicast.Address.ToString().StartsWith("169.254."))
                    {
                        continue;
                    }

                    var score = hasGateway ? 0 : 1;
                    if (nic.NetworkInterfaceType == NetworkInterfaceType.Wireless80211)
                    {
                        score += 2;
                    }

                    result.Add((score, unicast.Address));
                }
            }
        }
        catch
        {
            // Fall through to loopback.
        }

        return result
            .OrderBy(x => x.score)
            .Select(x => x.address)
            .Distinct()
            .ToList();
    }
}
