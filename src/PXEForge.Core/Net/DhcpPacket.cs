using System.Buffers.Binary;
using System.Net;
using System.Text;

namespace PXEForge.Core.Net;

/// <summary>
/// Minimal DHCPv4 (RFC 2131/2132) codec. Only the fields a proxyDHCP needs are
/// modelled, but the parser is tolerant and keeps every option.
/// </summary>
public sealed class DhcpPacket
{
    public const byte BootRequest = 1;
    public const byte BootReply = 2;

    public const byte MessageDiscover = 1;
    public const byte MessageOffer = 2;
    public const byte MessageRequest = 3;
    public const byte MessageDecline = 4;
    public const byte MessageAck = 5;
    public const byte MessageNak = 6;
    public const byte MessageRelease = 7;
    public const byte MessageInform = 8;

    public byte Op { get; set; }
    public byte HardwareType { get; set; } = 1;
    public byte HardwareLength { get; set; } = 6;
    public byte Hops { get; set; }
    public uint TransactionId { get; set; }
    public ushort Seconds { get; set; }
    public ushort Flags { get; set; }
    public IPAddress ClientAddress { get; set; } = IPAddress.Any;
    public IPAddress YourAddress { get; set; } = IPAddress.Any;
    public IPAddress ServerAddress { get; set; } = IPAddress.Any;
    public IPAddress RelayAddress { get; set; } = IPAddress.Any;
    public byte[] ClientHardwareAddress { get; set; } = new byte[16];
    public string ServerName { get; set; } = "";
    public string BootFileName { get; set; } = "";
    public Dictionary<byte, byte[]> Options { get; } = new();

    public string MacAddress =>
        string.Join(":", ClientHardwareAddress.Take(HardwareLength).Select(b => b.ToString("x2")));

    public ushort? ClientArchitecture =>
        Options.TryGetValue(93, out var value) && value.Length >= 2
            ? BinaryPrimitives.ReadUInt16BigEndian(value)
            : null;

    public string VendorClass =>
        Options.TryGetValue(60, out var value) ? Encoding.ASCII.GetString(value).TrimEnd('\0') : "";

    public string UserClass
    {
        get
        {
            if (!Options.TryGetValue(77, out var value))
            {
                return "";
            }

            // Option 77 is a sequence of length-prefixed strings.
            var sb = new StringBuilder();
            var i = 0;
            while (i < value.Length)
            {
                var length = value[i++];
                if (length == 0 || i + length > value.Length)
                {
                    break;
                }

                sb.Append(Encoding.ASCII.GetString(value, i, length));
                i += length;
                sb.Append(' ');
            }

            return sb.ToString().Trim();
        }
    }

    public bool IsPxeClient
    {
        get
        {
            var vendor = VendorClass;
            return vendor.StartsWith("PXEClient", StringComparison.OrdinalIgnoreCase)
                   || vendor.StartsWith("HTTPClient", StringComparison.OrdinalIgnoreCase)
                   || ClientArchitecture is not null;
        }
    }

    public bool IsIpxeClient =>
        UserClass.Contains("iPXE", StringComparison.OrdinalIgnoreCase) ||
        VendorClass.Contains("iPXE", StringComparison.OrdinalIgnoreCase);

    public T? GetOption<T>(byte code, Func<byte[], T> parser, T? fallback = default) =>
        Options.TryGetValue(code, out var value) ? parser(value) : fallback;

    public static DhcpPacket Parse(ReadOnlySpan<byte> data)
    {
        if (data.Length < 240)
        {
            throw new FormatException("DHCP packet shorter than 240 bytes.");
        }

        var packet = new DhcpPacket
        {
            Op = data[0],
            HardwareType = data[1],
            HardwareLength = data[2],
            Hops = data[3],
            TransactionId = BinaryPrimitives.ReadUInt32BigEndian(data.Slice(4, 4)),
            Seconds = BinaryPrimitives.ReadUInt16BigEndian(data.Slice(8, 2)),
            Flags = BinaryPrimitives.ReadUInt16BigEndian(data.Slice(10, 2)),
            ClientAddress = new IPAddress(data.Slice(12, 4)),
            YourAddress = new IPAddress(data.Slice(16, 4)),
            ServerAddress = new IPAddress(data.Slice(20, 4)),
            RelayAddress = new IPAddress(data.Slice(24, 4))
        };

        packet.ClientHardwareAddress = data.Slice(28, 16).ToArray();
        packet.ServerName = ReadFixedString(data.Slice(44, 64));
        packet.BootFileName = ReadFixedString(data.Slice(108, 128));

        if (data[236] != 99 || data[237] != 130 || data[238] != 83 || data[239] != 99)
        {
            throw new FormatException("Missing DHCP magic cookie.");
        }

        var i = 240;
        while (i < data.Length)
        {
            var code = data[i++];
            if (code == 0)
            {
                continue;
            }

            if (code == 255)
            {
                break;
            }

            if (i >= data.Length)
            {
                break;
            }

            var length = (int)data[i++];
            if (i + length > data.Length)
            {
                length = data.Length - i;
            }

            packet.Options[code] = data.Slice(i, length).ToArray();
            i += length;
        }

        return packet;
    }

    public byte[] Build()
    {
        var size = 240 + Options.Sum(kv => 2 + kv.Value.Length) + 1;
        var buffer = new byte[size];
        buffer[0] = Op;
        buffer[1] = HardwareType;
        buffer[2] = HardwareLength;
        buffer[3] = Hops;
        BinaryPrimitives.WriteUInt32BigEndian(buffer.AsSpan(4, 4), TransactionId);
        BinaryPrimitives.WriteUInt16BigEndian(buffer.AsSpan(8, 2), Seconds);
        BinaryPrimitives.WriteUInt16BigEndian(buffer.AsSpan(10, 2), Flags);
        ClientAddress.GetAddressBytes().CopyTo(buffer, 12);
        YourAddress.GetAddressBytes().CopyTo(buffer, 16);
        ServerAddress.GetAddressBytes().CopyTo(buffer, 20);
        RelayAddress.GetAddressBytes().CopyTo(buffer, 24);
        Buffer.BlockCopy(ClientHardwareAddress, 0, buffer, 28, Math.Min(16, ClientHardwareAddress.Length));
        WriteFixedString(buffer.AsSpan(44, 64), ServerName, 64);
        WriteFixedString(buffer.AsSpan(108, 128), BootFileName, 128);

        buffer[236] = 99;
        buffer[237] = 130;
        buffer[238] = 83;
        buffer[239] = 99;

        var offset = 240;
        foreach (var (code, value) in Options)
        {
            buffer[offset++] = code;
            buffer[offset++] = (byte)value.Length;
            value.CopyTo(buffer, offset);
            offset += value.Length;
        }

        buffer[offset] = 255;

        // DHCP minimum message size is 300 bytes (RFC 1542).
        if (buffer.Length < 300)
        {
            Array.Resize(ref buffer, 300);
        }

        return buffer;
    }

    public static DhcpPacket CreateProxyReply(
        DhcpPacket request,
        byte messageType,
        IPAddress serverAddress,
        string bootFileName,
        string tftpServerName)
    {
        var reply = new DhcpPacket
        {
            Op = BootReply,
            HardwareType = request.HardwareType,
            HardwareLength = request.HardwareLength,
            Hops = request.Hops,
            TransactionId = request.TransactionId,
            Seconds = 0,
            Flags = request.Flags,
            ClientAddress = IPAddress.Any,
            YourAddress = IPAddress.Any,   // proxyDHCP never assigns an address
            ServerAddress = serverAddress,
            RelayAddress = request.RelayAddress,
            ClientHardwareAddress = request.ClientHardwareAddress,
            ServerName = tftpServerName,
            BootFileName = bootFileName
        };

        reply.Options[53] = new[] { messageType };
        reply.Options[54] = serverAddress.GetAddressBytes();
        reply.Options[60] = Encoding.ASCII.GetBytes("PXEClient");
        reply.Options[66] = Encoding.ASCII.GetBytes(tftpServerName);
        reply.Options[67] = Encoding.ASCII.GetBytes(bootFileName);

        // Echo the client UUID so PXE firmware accepts the proxy offer.
        if (request.Options.TryGetValue(97, out var uuid))
        {
            reply.Options[97] = uuid.ToArray();
        }

        return reply;
    }

    private static string ReadFixedString(ReadOnlySpan<byte> data)
    {
        var length = data.IndexOf((byte)0);
        if (length < 0)
        {
            length = data.Length;
        }

        return Encoding.ASCII.GetString(data.Slice(0, length));
    }

    private static void WriteFixedString(Span<byte> target, string value, int maxLength)
    {
        target.Clear();
        var bytes = Encoding.ASCII.GetBytes(value);
        bytes.AsSpan(0, Math.Min(bytes.Length, maxLength)).CopyTo(target);
    }
}

/// <summary>
/// Resolves the boot file for a request, including the second-stage iPXE script.
/// </summary>
public sealed class BootFileResolver
{
    private readonly IPAddress _serverAddress;
    private readonly int _httpPort;
    private readonly string _biosFile;
    private readonly string _uefiFile;
    private readonly string _arm64File;
    private readonly string _scriptPath;

    public BootFileResolver(IPAddress serverAddress, int httpPort, string biosFile, string uefiFile, string arm64File, string scriptPath)
    {
        _serverAddress = serverAddress;
        _httpPort = httpPort;
        _biosFile = biosFile.TrimStart('/');
        _uefiFile = uefiFile.TrimStart('/');
        _arm64File = arm64File.TrimStart('/');
        _scriptPath = scriptPath.StartsWith('/') ? scriptPath : "/" + scriptPath;
    }

    public string Resolve(DhcpPacket request)
    {
        if (request.IsIpxeClient)
        {
            return $"http://{_serverAddress}:{_httpPort}{_scriptPath}";
        }

        return request.ClientArchitecture switch
        {
            0 => _biosFile,          // x86 BIOS
            6 => _uefiFile,          // EFI IA32 (served by x64 firmware only in practice)
            7 => _uefiFile,          // EFI x64
            9 => _uefiFile,          // EFI x64 (alternative code)
            10 => _arm64File,        // EFI ARM64
            _ => _biosFile
        };
    }
}
