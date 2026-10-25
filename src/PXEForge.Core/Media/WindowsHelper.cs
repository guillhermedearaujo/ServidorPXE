using System.Security.Principal;

namespace PXEForge.Core.Media;

public static class WindowsHelper
{
    public static bool IsAdministrator()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    public static string DescribeFirmware() =>
        Directory.Exists(@"C:\EFI") ? "UEFI" : "BIOS/legacy";
}
