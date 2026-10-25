namespace PXEForge.Core.Media;

/// <summary>
/// Well known directories under the content root.
/// </summary>
public sealed class ContentLayout
{
    public ContentLayout(string root)
    {
        Root = Path.GetFullPath(root);
    }

    public string Root { get; }
    public string IpxeDir => Path.Combine(Root, "ipxe");
    public string WinpeDir => Path.Combine(Root, "winpe");
    public string FontsDir => Path.Combine(WinpeDir, "fonts");
    public string MediaDir => Path.Combine(Root, "media");
    public string MediaSourcesDir => Path.Combine(MediaDir, "sources");

    public void Ensure()
    {
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(IpxeDir);
        Directory.CreateDirectory(WinpeDir);
        Directory.CreateDirectory(FontsDir);
        Directory.CreateDirectory(MediaSourcesDir);
    }

    public IReadOnlyList<string> MissingBootPayload()
    {
        var required = new[]
        {
            Path.Combine(IpxeDir, "undionly.kpxe"),
            Path.Combine(IpxeDir, "ipxe.efi"),
            Path.Combine(WinpeDir, "wimboot"),
            Path.Combine(WinpeDir, "boot.sdi"),
            Path.Combine(WinpeDir, "boot.wim")
        };

        return required.Where(p => !File.Exists(p)).ToList();
    }

    public bool HasInstallImage() =>
        Directory.Exists(MediaSourcesDir) &&
        Directory.EnumerateFiles(MediaSourcesDir, "install.*").Any();
}
