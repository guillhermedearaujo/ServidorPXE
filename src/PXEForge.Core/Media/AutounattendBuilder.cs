using System.Text;
using PXEForge.Core.Configuration;

namespace PXEForge.Core.Media;

/// <summary>
/// Generates the Windows Setup answer files and the WinPE startnet script.
/// The answer files are intentionally conservative: they wipe disk 0 and do
/// not inject product keys or third-party drivers.
/// </summary>
public sealed class AutounattendBuilder
{
    private readonly PxeConfig _config;

    public AutounattendBuilder(PxeConfig config)
    {
        _config = config;
    }

    public void WriteAnswerFiles(string mediaRoot, string installFileName, int imageIndex)
    {
        Directory.CreateDirectory(mediaRoot);
        File.WriteAllText(Path.Combine(mediaRoot, "autounattend-uefi.xml"), BuildXml(installFileName, imageIndex, uefi: true), Encoding.UTF8);
        File.WriteAllText(Path.Combine(mediaRoot, "autounattend-bios.xml"), BuildXml(installFileName, imageIndex, uefi: false), Encoding.UTF8);
    }

    public string BuildStartnet(string uncPath, string installFileName, string? smbUser, string? smbPassword)
    {
        var setupArgs = $"/InstallFrom \"Y:\\sources\\{installFileName}\" /unattend:\"%UNATTEND%\"";
        var sb = new StringBuilder();
        sb.AppendLine("@echo off");
        sb.AppendLine("echo ============================================");
        sb.AppendLine($"echo  {_config.ServerName} - PXEForge");
        sb.AppendLine("echo ============================================");
        sb.AppendLine("wpeinit");
        sb.AppendLine("echo [PXEForge] aguardando rede...");
        sb.AppendLine("ping -n 4 127.0.0.1 >nul");

        if (!string.IsNullOrWhiteSpace(smbUser))
        {
            sb.AppendLine($"net use Y: \"{uncPath}\" /user:{smbUser} \"{smbPassword}\" /persistent:no");
        }
        else
        {
            sb.AppendLine($"net use Y: \"{uncPath}\" /persistent:no");
        }

        sb.AppendLine("if errorlevel 1 (");
        sb.AppendLine("  echo [PXEForge] FALHA ao montar o compartilhamento de midia.");
        sb.AppendLine($"  echo [PXEForge] Verifique o share {uncPath} e as credenciais.");
        sb.AppendLine("  pause");
        sb.AppendLine("  exit /b 1");
        sb.AppendLine(")");
        sb.AppendLine("echo [PXEForge] midia montada em Y:");
        sb.AppendLine("set \"FW=0x1\"");
        sb.AppendLine("for /f \"tokens=3\" %%a in ('reg query HKLM\\SYSTEM\\CurrentControlSet\\Control /v PEFirmwareType 2^>nul ^| find \"PEFirmwareType\"') do set \"FW=%%a\"");
        sb.AppendLine("set \"UNATTEND=Y:\\autounattend-bios.xml\"");
        sb.AppendLine("if \"%FW%\"==\"0x2\" set \"UNATTEND=Y:\\autounattend-uefi.xml\"");
        sb.AppendLine("set \"SETUP=\"");
        sb.AppendLine("if exist X:\\sources\\setup.exe set \"SETUP=X:\\sources\\setup.exe\"");
        sb.AppendLine("if not defined SETUP if exist Y:\\sources\\setup.exe set \"SETUP=Y:\\sources\\setup.exe\"");
        sb.AppendLine("if not defined SETUP (");
        sb.AppendLine("  echo [PXEForge] setup.exe nao encontrado.");
        sb.AppendLine("  pause");
        sb.AppendLine("  exit /b 1");
        sb.AppendLine(")");
        sb.AppendLine("echo [PXEForge] iniciando instalacao: %SETUP%");
        sb.AppendLine($"\"%SETUP%\" {setupArgs}");
        sb.AppendLine("echo [PXEForge] Setup encerrou. Reinicie o ativo.");
        sb.AppendLine("pause");
        return sb.ToString();
    }

    private string BuildXml(string installFileName, int imageIndex, bool uefi)
    {
        var locale = string.IsNullOrWhiteSpace(_config.Locale) ? "pt-BR" : _config.Locale;
        var timeZone = string.IsNullOrWhiteSpace(_config.TimeZone) ? "E. South America Standard Time" : _config.TimeZone;
        var installToPartition = uefi ? 3 : 2;

        var disk = uefi
            ? """
                    <DiskConfiguration>
                      <Disk wcm:action="add">
                        <DiskID>0</DiskID>
                        <WillWipeDisk>true</WillWipeDisk>
                        <CreatePartitions>
                          <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
                          <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                          <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                        </CreatePartitions>
                        <ModifyPartitions>
                          <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                          <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
                          <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label></ModifyPartition>
                        </ModifyPartitions>
                      </Disk>
                    </DiskConfiguration>
              """
            : """
                    <DiskConfiguration>
                      <Disk wcm:action="add">
                        <DiskID>0</DiskID>
                        <WillWipeDisk>true</WillWipeDisk>
                        <CreatePartitions>
                          <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>500</Size></CreatePartition>
                          <CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                        </CreatePartitions>
                        <ModifyPartitions>
                          <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Active>true</Active><Format>NTFS</Format><Label>System</Label></ModifyPartition>
                          <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label></ModifyPartition>
                        </ModifyPartitions>
                      </Disk>
                    </DiskConfiguration>
              """;

        var selection = !string.IsNullOrWhiteSpace(_config.ImageName)
            ? $"""
                     <MetaData wcm:action="add">
                       <Key>/IMAGE/NAME</Key>
                       <Value>{Escape(_config.ImageName)}</Value>
                     </MetaData>
               """
            : $"""
                     <MetaData wcm:action="add">
                       <Key>/IMAGE/INDEX</Key>
                       <Value>{(imageIndex > 0 ? imageIndex : 1)}</Value>
                     </MetaData>
               """;

        var localAccounts = string.IsNullOrWhiteSpace(_config.AdminPassword)
            ? ""
            : $"""
                      <UserAccounts>
                        <LocalAccounts>
                          <LocalAccount wcm:action="add">
                            <Name>{Escape(_config.AdminUser)}</Name>
                            <Group>Administrators</Group>
                            <Password><Value>{Escape(_config.AdminPassword)}</Value><PlainText>true</PlainText></Password>
                          </LocalAccount>
                        </LocalAccounts>
                      </UserAccounts>
                """;

        return $"""
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage><UILanguage>{locale}</UILanguage></SetupUILanguage>
      <InputLocale>{locale}</InputLocale>
      <SystemLocale>{locale}</SystemLocale>
      <UILanguage>{locale}</UILanguage>
      <UserLocale>{locale}</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
{disk}
      <ImageInstall>
        <OSImage>
          <InstallFrom>
{selection}
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>{installToPartition}</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
{localAccounts}
      <TimeZone>{timeZone}</TimeZone>
    </component>
  </settings>
</unattend>
""";
    }

    private static string Escape(string value) =>
        value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");
}
