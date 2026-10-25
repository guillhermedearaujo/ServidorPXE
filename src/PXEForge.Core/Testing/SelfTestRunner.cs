using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using PXEForge.Core.Configuration;
using PXEForge.Core.Diagnostics;
using PXEForge.Core.Media;
using PXEForge.Core.Net;

namespace PXEForge.Core.Testing;

public sealed record TestOutcome(string Name, bool Passed, string Detail);

/// <summary>
/// Loopback integration tests. They exercise the real protocol code over
/// 127.0.0.1 using unprivileged ports, so they can run without administrator
/// rights and without a PXE client machine.
/// </summary>
public sealed class SelfTestRunner
{
    private readonly LogHub _log;
    private readonly List<TestOutcome> _results = new();

    public SelfTestRunner(LogHub log)
    {
        _log = log;
    }

    public static async Task<IReadOnlyList<TestOutcome>> RunAsync(LogHub log, CancellationToken ct = default)
    {
        var runner = new SelfTestRunner(log);
        await runner.ExecuteAsync(ct);
        return runner._results;
    }

    private async Task ExecuteAsync(CancellationToken ct)
    {
        await Run("dhcp-codec", TestDhcpCodecAsync, ct);
        await Run("dhcp-bootfile-selection", TestBootFileSelectionAsync, ct);
        await Run("proxy-dhcp-loopback", TestProxyDhcpAsync, ct);
        await Run("tftp-transfer-options", TestTftpAsync, ct);
        await Run("http-boot-script", TestHttpAsync, ct);
    }

    private async Task Run(string name, Func<CancellationToken, Task<string>> test, CancellationToken ct)
    {
        var stopwatch = Stopwatch.StartNew();
        try
        {
            var detail = await test(ct);
            _results.Add(new TestOutcome(name, true, $"{detail} ({stopwatch.ElapsedMilliseconds} ms)"));
            _log.Info("selftest", $"PASS {name}: {detail}");
        }
        catch (Exception ex)
        {
            _results.Add(new TestOutcome(name, false, ex.Message));
            _log.Error("selftest", $"FAIL {name}: {ex}");
        }
    }

    private static Task<string> TestDhcpCodecAsync(CancellationToken ct)
    {
        var discover = new DhcpPacket
        {
            Op = DhcpPacket.BootRequest,
            TransactionId = 0x12345678,
            ClientHardwareAddress = new byte[] { 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            Flags = 0x8000
        };
        discover.Options[53] = new[] { DhcpPacket.MessageDiscover };
        discover.Options[60] = Encoding.ASCII.GetBytes("PXEClient:Arch:00007:UNDI:003000");
        discover.Options[93] = new byte[] { 0x00, 0x07 };
        discover.Options[97] = Guid.NewGuid().ToByteArray();

        var wire = discover.Build();
        var parsed = DhcpPacket.Parse(wire);

        Assert(parsed.TransactionId == discover.TransactionId, "xid perdido");
        Assert(parsed.ClientArchitecture == 7, "opcao 93 perdida");
        Assert(parsed.IsPxeClient, "cliente PXE nao reconhecido");
        Assert(parsed.MacAddress == "aa:bb:cc:dd:ee:01", "MAC divergente: " + parsed.MacAddress);

        var reply = DhcpPacket.CreateProxyReply(parsed, DhcpPacket.MessageOffer, IPAddress.Parse("192.168.1.10"), "ipxe/ipxe.efi", "192.168.1.10");
        var replyParsed = DhcpPacket.Parse(reply.Build());
        Assert(replyParsed.Op == DhcpPacket.BootReply, "opcode de resposta invalido");
        Assert(replyParsed.Options[53][0] == DhcpPacket.MessageOffer, "tipo de mensagem invalido");
        Assert(Encoding.ASCII.GetString(replyParsed.Options[66]) == "192.168.1.10", "opcao 66 invalida");
        Assert(Encoding.ASCII.GetString(replyParsed.Options[67]) == "ipxe/ipxe.efi", "opcao 67 invalida");
        Assert(replyParsed.ServerAddress.ToString() == "192.168.1.10", "siaddr invalido");

        return Task.FromResult("pacote ida/volta OK, opcoes 53/60/66/67/93/97 preservadas");
    }

    private static Task<string> TestBootFileSelectionAsync(CancellationToken ct)
    {
        var resolver = new BootFileResolver(
            IPAddress.Parse("10.0.0.1"),
            8082,
            "ipxe/undionly.kpxe",
            "ipxe/ipxe.efi",
            "ipxe/arm64-efi/ipxe.efi",
            "/boot.ipxe");

        string Resolve(ushort arch, bool ipxe = false)
        {
            var request = new DhcpPacket();
            request.Options[93] = new[] { (byte)(arch >> 8), (byte)(arch & 0xFF) };
            if (ipxe)
            {
                request.Options[77] = new byte[] { 4, (byte)'i', (byte)'P', (byte)'X', (byte)'E' };
            }

            return resolver.Resolve(request);
        }

        Assert(Resolve(0) == "ipxe/undionly.kpxe", "BIOS deveria receber undionly.kpxe");
        Assert(Resolve(7) == "ipxe/ipxe.efi", "UEFI x64 deveria receber ipxe.efi");
        Assert(Resolve(10) == "ipxe/arm64-efi/ipxe.efi", "ARM64 deveria receber ipxe arm64");
        Assert(Resolve(7, ipxe: true) == "http://10.0.0.1:8082/boot.ipxe", "iPXE deveria receber a URL do script");

        return Task.FromResult("BIOS/UEFI/ARM64/iPXE resolvidos corretamente");
    }

    private async Task<string> TestProxyDhcpAsync(CancellationToken ct)
    {
        const int serverPort = 16767;
        var client = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        try
        {
            var clientPort = ((IPEndPoint)client.Client.LocalEndPoint!).Port;
            await using var server = new ProxyDhcpServer(
                IPAddress.Loopback,
                serverPort,
                IPAddress.Parse("192.168.1.10"),
                new BootFileResolver(IPAddress.Parse("192.168.1.10"), 8082, "ipxe/undionly.kpxe", "ipxe/ipxe.efi", "ipxe/arm64-efi/ipxe.efi", "/boot.ipxe"),
                new LogHub(10),
                relayPort: clientPort);

            server.Start();

            var discover = new DhcpPacket
            {
                Op = DhcpPacket.BootRequest,
                TransactionId = 0xCAFEBABE,
                RelayAddress = IPAddress.Loopback,
                ClientHardwareAddress = new byte[] { 0x02, 0, 0, 0, 0, 0x42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
            };
            discover.Options[53] = new[] { DhcpPacket.MessageDiscover };
            discover.Options[60] = Encoding.ASCII.GetBytes("PXEClient:Arch:00007:UNDI:003000");
            discover.Options[93] = new byte[] { 0, 7 };
            discover.Options[97] = Enumerable.Repeat((byte)0x11, 17).ToArray();

            await client.SendAsync(discover.Build(), new IPEndPoint(IPAddress.Loopback, serverPort), ct);

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            var received = await client.ReceiveAsync(timeout.Token);
            var offer = DhcpPacket.Parse(received.Buffer);

            Assert(offer.Op == DhcpPacket.BootReply, "resposta nao e BOOTREPLY");
            Assert(offer.TransactionId == discover.TransactionId, "xid divergente");
            Assert(offer.Options[53][0] == DhcpPacket.MessageOffer, "esperava DHCPOFFER");
            Assert(offer.Options[67].Length > 0 && Encoding.ASCII.GetString(offer.Options[67]) == "ipxe/ipxe.efi", "bootfile UEFI incorreto");
            Assert(offer.Options[54].SequenceEqual(IPAddress.Parse("192.168.1.10").GetAddressBytes()), "server identifier incorreto");
            Assert(offer.YourAddress.Equals(IPAddress.Any), "proxyDHCP nao deve atribuir IP");

            return "DHCPOFFER respondido em 127.0.0.1 com bootfile UEFI correto";
        }
        finally
        {
            client.Dispose();
        }
    }

    private async Task<string> TestTftpAsync(CancellationToken ct)
    {
        var root = Path.Combine(Path.GetTempPath(), "pxeforge-selftest-tftp-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(root);
        try
        {
            var payload = RandomNumberGenerator.GetBytes(300 * 1024);
            var file = Path.Combine(root, "payload.bin");
            await File.WriteAllBytesAsync(file, payload, ct);

            const int serverPort = 16969;
            await using var server = new TftpServer(IPAddress.Loopback, serverPort, root, new LogHub(10));
            server.Start();

            var downloaded = await TftpClient.DownloadAsync(
                IPAddress.Loopback,
                serverPort,
                "payload.bin",
                blockSize: 1468,
                windowSize: 4,
                ct);

            Assert(downloaded.Length == payload.Length, $"tamanho divergente: {downloaded.Length} != {payload.Length}");
            Assert(SHA256.HashData(downloaded).SequenceEqual(SHA256.HashData(payload)), "hash divergente");

            // Path traversal must be refused, not served.
            var traversalBlocked = false;
            try
            {
                await TftpClient.DownloadAsync(IPAddress.Loopback, serverPort, "../../windows/win.ini", 512, 1, ct);
            }
            catch (TftpException)
            {
                traversalBlocked = true;
            }

            Assert(traversalBlocked, "path traversal nao foi bloqueado");

            return $"{downloaded.Length} bytes via blksize=1468/windowsize=4; traversal bloqueado";
        }
        finally
        {
            try
            {
                Directory.Delete(root, true);
            }
            catch
            {
                // Best effort.
            }
        }
    }

    private async Task<string> TestHttpAsync(CancellationToken ct)
    {
        var root = Path.Combine(Path.GetTempPath(), "pxeforge-selftest-http-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(Path.Combine(root, "winpe"));
        Directory.CreateDirectory(Path.Combine(root, "ipxe"));

        try
        {
            await File.WriteAllBytesAsync(Path.Combine(root, "winpe", "wimboot"), new byte[64], ct);
            await File.WriteAllBytesAsync(Path.Combine(root, "winpe", "boot.sdi"), new byte[64], ct);
            await File.WriteAllBytesAsync(Path.Combine(root, "winpe", "boot.wim"), new byte[4096], ct);
            await File.WriteAllBytesAsync(Path.Combine(root, "winpe", "BCD-EFI"), new byte[64], ct);
            var sample = Encoding.ASCII.GetBytes("0123456789abcdef");
            await File.WriteAllBytesAsync(Path.Combine(root, "sample.txt"), sample, ct);
            File.WriteAllText(Path.Combine(root, "..", "pxeforge-secret.txt"), "secret");

            const int port = 18082;
            var config = new PxeConfig { ServerName = "SELFTEST", HttpPort = port };
            await using var http = new BootHttpServer(
                config,
                IPAddress.Loopback,
                port,
                root,
                new LogHub(10),
                () => new { state = "Running" });

            await http.StartAsync(ct);
            using var client = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}") };

            var script = await client.GetStringAsync("/boot.ipxe", ct);
            Assert(script.Contains("wimboot", StringComparison.OrdinalIgnoreCase), "script sem wimboot");
            Assert(script.Contains("boot.wim", StringComparison.OrdinalIgnoreCase), "script sem boot.wim");
            Assert(script.Contains("BCD-EFI", StringComparison.OrdinalIgnoreCase), "script sem BCD");

            var status = await client.GetAsync("/api/status", ct);
            Assert(status.IsSuccessStatusCode, "api/status falhou");

            using var range = new HttpRequestMessage(HttpMethod.Get, "/files/sample.txt");
            range.Headers.Range = new RangeHeaderValue(0, 3);
            var rangeResponse = await client.SendAsync(range, ct);
            Assert(rangeResponse.StatusCode == HttpStatusCode.PartialContent, $"range retornou {(int)rangeResponse.StatusCode}");
            var rangeBody = await rangeResponse.Content.ReadAsByteArrayAsync(ct);
            Assert(rangeBody.Length == 4 && Encoding.ASCII.GetString(rangeBody) == "0123", "conteudo do range incorreto");

            var traversal = await client.GetAsync("/files/../pxeforge-secret.txt", ct);
            Assert(traversal.StatusCode == HttpStatusCode.NotFound, "path traversal HTTP nao bloqueado");

            try
            {
                File.Delete(Path.Combine(root, "..", "pxeforge-secret.txt"));
            }
            catch
            {
                // Best effort.
            }

            return "script iPXE, API, range HTTP e bloqueio de traversal OK";
        }
        finally
        {
            try
            {
                Directory.Delete(root, true);
            }
            catch
            {
                // Best effort.
            }
        }
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}

public sealed class TftpException : Exception
{
    public TftpException(string message) : base(message) { }
}

/// <summary>Small TFTP client used only by the self-test.</summary>
internal static class TftpClient
{
    public static async Task<byte[]> DownloadAsync(
        IPAddress server,
        int port,
        string fileName,
        int blockSize,
        int windowSize,
        CancellationToken ct)
    {
        using var client = new UdpClient(new IPEndPoint(IPAddress.Any, 0));
        var serverEndPoint = new IPEndPoint(server, port);

        using var request = new MemoryStream();
        WriteUInt16(request, 1);
        WriteZ(request, fileName);
        WriteZ(request, "octet");
        WriteZ(request, "blksize");
        WriteZ(request, blockSize.ToString());
        WriteZ(request, "windowsize");
        WriteZ(request, windowSize.ToString());
        WriteZ(request, "tsize");
        WriteZ(request, "0");

        await client.SendAsync(request.ToArray(), serverEndPoint, ct);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));

        var output = new MemoryStream();
        ushort expectedBlock = 1;
        var acknowledged = false;

        while (true)
        {
            var received = await client.ReceiveAsync(timeout.Token);
            if (received.Buffer.Length < 4)
            {
                continue;
            }

            var opcode = BinaryPrimitives.ReadUInt16BigEndian(received.Buffer);
            if (opcode == 5)
            {
                var message = Encoding.ASCII.GetString(received.Buffer, 4, received.Buffer.Length - 4).TrimEnd('\0');
                throw new TftpException("erro TFTP: " + message);
            }

            if (opcode == 6)
            {
                await SendAckAsync(client, received.RemoteEndPoint, 0);
                continue;
            }

            if (opcode != 3)
            {
                continue;
            }

            var block = BinaryPrimitives.ReadUInt16BigEndian(received.Buffer.AsSpan(2));
            var payloadLength = received.Buffer.Length - 4;

            if (block == expectedBlock)
            {
                output.Write(received.Buffer, 4, payloadLength);
                expectedBlock = (ushort)(expectedBlock + 1);
                acknowledged = false;
            }

            var isLast = payloadLength < blockSize;
            var inWindow = ((expectedBlock - 1) % windowSize) == 0;

            if (!acknowledged && (isLast || inWindow))
            {
                await SendAckAsync(client, received.RemoteEndPoint, block);
                acknowledged = true;
            }

            if (isLast && block == expectedBlock - 1)
            {
                // Final ACK already sent above.
                await SendAckAsync(client, received.RemoteEndPoint, block);
                return output.ToArray();
            }
        }
    }

    private static async Task SendAckAsync(UdpClient client, IPEndPoint remote, ushort block)
    {
        var packet = new byte[4];
        BinaryPrimitives.WriteUInt16BigEndian(packet, 4);
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(2), block);
        await client.SendAsync(packet, remote);
    }

    private static void WriteUInt16(Stream stream, ushort value)
    {
        stream.WriteByte((byte)(value >> 8));
        stream.WriteByte((byte)(value & 0xFF));
    }

    private static void WriteZ(Stream stream, string value)
    {
        var bytes = Encoding.ASCII.GetBytes(value);
        stream.Write(bytes);
        stream.WriteByte(0);
    }
}
