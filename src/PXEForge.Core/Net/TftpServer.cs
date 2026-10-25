using System.Buffers.Binary;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using PXEForge.Core.Diagnostics;

namespace PXEForge.Core.Net;

/// <summary>
/// TFTP server implementing RFC 1350 with the options that matter for PXE:
/// RFC 2347/2348 (blksize), RFC 2349 (timeout, tsize) and RFC 7440 (windowsize).
/// Read-only by design.
/// </summary>
public sealed class TftpServer : IAsyncDisposable
{
    private const ushort OpRrq = 1;
    private const ushort OpWrq = 2;
    private const ushort OpData = 3;
    private const ushort OpAck = 4;
    private const ushort OpError = 5;
    private const ushort OpOack = 6;

    private readonly IPAddress _bindAddress;
    private readonly int _port;
    private readonly string _root;
    private readonly LogHub _log;
    private readonly CancellationTokenSource _cts = new();
    private UdpClient? _listener;
    private Task? _loop;
    private long _bytesSent;
    private long _transfers;
    private int _activeSessions;
    private Func<bool>? _shouldThrottle;

    public TftpServer(IPAddress bindAddress, int port, string root, LogHub log, Func<bool>? shouldThrottle = null)
    {
        _bindAddress = bindAddress;
        _port = port;
        _root = Path.GetFullPath(root);
        _log = log;
        _shouldThrottle = shouldThrottle;
    }

    public bool IsRunning => _loop is { IsCompleted: false };
    public long BytesSent => Interlocked.Read(ref _bytesSent);
    public long Transfers => Interlocked.Read(ref _transfers);
    public int ActiveSessions => Volatile.Read(ref _activeSessions);

    public void Start()
    {
        if (IsRunning)
        {
            return;
        }

        Directory.CreateDirectory(_root);
        var listener = new UdpClient(new IPEndPoint(_bindAddress, _port));
        _listener = listener;
        _loop = Task.Run(() => LoopAsync(_cts.Token));
        _log.Info("tftp", $"TFTP escutando em {_bindAddress}:{_port} (raiz {_root})");
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var received = await _listener!.ReceiveAsync(ct);
                var datagram = received.Buffer;
                var remote = received.RemoteEndPoint;
                _ = Task.Run(() => HandleRequestAsync(datagram, remote, ct), ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (Exception ex)
            {
                _log.Warn("tftp", $"receive falhou: {ex.Message}");
            }
        }
    }

    private async Task HandleRequestAsync(byte[] datagram, IPEndPoint remote, CancellationToken ct)
    {
        try
        {
            if (datagram.Length < 4)
            {
                return;
            }

            var opcode = BinaryPrimitives.ReadUInt16BigEndian(datagram);
            if (opcode == OpWrq)
            {
                await SendErrorAsync(remote, 2, "servidor somente leitura", ct);
                return;
            }

            if (opcode != OpRrq)
            {
                await SendErrorAsync(remote, 4, "operacao ilegal", ct);
                return;
            }

            if (_shouldThrottle?.Invoke() == true)
            {
                _log.Warn("tftp", $"limite por recursos: rejeitando RRQ de {remote.Address} (CPU/RAM >= 85%)");
                await SendErrorAsync(remote, 0, "servidor sobrecarregado, tente novamente", ct);
                return;
            }

            var (fileName, mode, options) = ParseRequest(datagram);
            if (!string.Equals(mode, "octet", StringComparison.OrdinalIgnoreCase))
            {
                await SendErrorAsync(remote, 0, "somente modo octet", ct);
                return;
            }

            var path = ResolvePath(fileName);
            if (path is null)
            {
                _log.Warn("tftp", $"{remote.Address} tentou sair da raiz: {fileName}");
                await SendErrorAsync(remote, 2, "acesso negado", ct);
                return;
            }

            if (!File.Exists(path))
            {
                _log.Warn("tftp", $"{remote.Address} pediu arquivo inexistente: {fileName}");
                await SendErrorAsync(remote, 1, "arquivo nao encontrado", ct);
                return;
            }

            Interlocked.Increment(ref _activeSessions);
            try
            {
                await ServeFileAsync(path, fileName, options, remote, ct);
            }
            finally
            {
                Interlocked.Decrement(ref _activeSessions);
            }
        }
        catch (Exception ex)
        {
            _log.Warn("tftp", $"sessao {remote}: {ex.Message}");
            try
            {
                await SendErrorAsync(remote, 0, "erro interno", ct);
            }
            catch
            {
                // Ignore.
            }
        }
    }

    private async Task ServeFileAsync(
        string path,
        string displayName,
        Dictionary<string, string> options,
        IPEndPoint remote,
        CancellationToken ct)
    {
        using var session = new UdpClient(new IPEndPoint(IPAddress.Any, 0));
        session.Client.ReceiveTimeout = 1000;

        var blockSize = 512;
        var timeoutSeconds = 5;
        var windowSize = 1;

        if (options.TryGetValue("blksize", out var rawBlock) &&
            int.TryParse(rawBlock, NumberStyles.Integer, CultureInfo.InvariantCulture, out var requestedBlock))
        {
            blockSize = Math.Clamp(requestedBlock, 8, 65464);
        }

        if (options.TryGetValue("timeout", out var rawTimeout) &&
            int.TryParse(rawTimeout, NumberStyles.Integer, CultureInfo.InvariantCulture, out var requestedTimeout))
        {
            timeoutSeconds = Math.Clamp(requestedTimeout, 1, 30);
        }

        if (options.TryGetValue("windowsize", out var rawWindow) &&
            int.TryParse(rawWindow, NumberStyles.Integer, CultureInfo.InvariantCulture, out var requestedWindow))
        {
            windowSize = Math.Clamp(requestedWindow, 1, 64);
        }

        var fileInfo = new FileInfo(path);
        var negotiated = new List<(string Name, string Value)>();
        if (options.ContainsKey("blksize"))
        {
            negotiated.Add(("blksize", blockSize.ToString(CultureInfo.InvariantCulture)));
        }

        if (options.ContainsKey("timeout"))
        {
            negotiated.Add(("timeout", timeoutSeconds.ToString(CultureInfo.InvariantCulture)));
        }

        if (options.ContainsKey("tsize"))
        {
            negotiated.Add(("tsize", fileInfo.Length.ToString(CultureInfo.InvariantCulture)));
        }

        if (options.ContainsKey("windowsize"))
        {
            negotiated.Add(("windowsize", windowSize.ToString(CultureInfo.InvariantCulture)));
        }

        var lastAck = (ushort)0;
        if (negotiated.Count > 0)
        {
            var oack = BuildOack(negotiated);
            if (!await SendAndAwaitAckAsync(session, remote, oack, expectedBlock: 0, timeoutSeconds, ct))
            {
                return;
            }
        }

        await using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            blockSize,
            FileOptions.SequentialScan | FileOptions.Asynchronous);

        var buffer = new byte[blockSize];
        ushort block = 1;
        long total = 0;
        var done = false;

        while (!done && !ct.IsCancellationRequested)
        {
            var window = new List<byte[]>(windowSize);
            var lastInWindow = block;

            for (var i = 0; i < windowSize; i++)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(0, blockSize), ct);
                if (read == 0 && i > 0)
                {
                    break;
                }

                var dataPacket = new byte[4 + read];
                BinaryPrimitives.WriteUInt16BigEndian(dataPacket, OpData);
                BinaryPrimitives.WriteUInt16BigEndian(dataPacket.AsSpan(2), block);
                buffer.AsSpan(0, read).CopyTo(dataPacket.AsSpan(4));

                window.Add(dataPacket);
                lastInWindow = block;
                total += read;

                if (read < blockSize)
                {
                    done = true;
                    break;
                }

                block++;
            }

            if (window.Count == 0)
            {
                break;
            }

            var success = await SendWindowAndAwaitAckAsync(
                session, remote, window, lastInWindow, timeoutSeconds, ct);

            if (!success)
            {
                _log.Warn("tftp", $"timeout em {displayName} para {remote.Address}");
                return;
            }

            lastAck = lastInWindow;
            block = (ushort)(lastInWindow + 1);
        }

        Interlocked.Add(ref _bytesSent, total);
        Interlocked.Increment(ref _transfers);
        _log.Info("tftp", $"{remote.Address} <- {displayName} ({total} bytes, blksize={blockSize}, windowsize={windowSize})");
    }

    private async Task<bool> SendWindowAndAwaitAckAsync(
        UdpClient session,
        IPEndPoint remote,
        List<byte[]> packets,
        ushort lastBlock,
        int timeoutSeconds,
        CancellationToken ct)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            foreach (var packet in packets)
            {
                await session.SendAsync(packet, packet.Length, remote);
            }

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));

            try
            {
                while (true)
                {
                    var received = await session.ReceiveAsync(timeout.Token);
                    if (received.Buffer.Length < 4)
                    {
                        continue;
                    }

                    var opcode = BinaryPrimitives.ReadUInt16BigEndian(received.Buffer);
                    if (opcode == OpError)
                    {
                        return false;
                    }

                    if (opcode != OpAck)
                    {
                        continue;
                    }

                    var ackBlock = BinaryPrimitives.ReadUInt16BigEndian(received.Buffer.AsSpan(2));
                    if (ackBlock == lastBlock)
                    {
                        return true;
                    }

                    // Stale ACK: keep waiting for the one that closes this window.
                }
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                // Retransmit the whole window.
            }
        }

        return false;
    }

    private static async Task<bool> SendAndAwaitAckAsync(
        UdpClient session,
        IPEndPoint remote,
        byte[] packet,
        ushort expectedBlock,
        int timeoutSeconds,
        CancellationToken ct)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            await session.SendAsync(packet, packet.Length, remote);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));

            try
            {
                while (true)
                {
                    var received = await session.ReceiveAsync(timeout.Token);
                    if (received.Buffer.Length < 4)
                    {
                        continue;
                    }

                    var opcode = BinaryPrimitives.ReadUInt16BigEndian(received.Buffer);
                    if (opcode == OpError)
                    {
                        return false;
                    }

                    if (opcode != OpAck)
                    {
                        continue;
                    }

                    var block = BinaryPrimitives.ReadUInt16BigEndian(received.Buffer.AsSpan(2));
                    if (block == expectedBlock)
                    {
                        return true;
                    }
                }
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                // Retransmit.
            }
        }

        return false;
    }

    private async Task SendErrorAsync(IPEndPoint remote, ushort code, string message, CancellationToken ct)
    {
        using var socket = new UdpClient(new IPEndPoint(IPAddress.Any, 0));
        var text = Encoding.ASCII.GetBytes(message);
        var packet = new byte[4 + text.Length + 1];
        BinaryPrimitives.WriteUInt16BigEndian(packet, OpError);
        BinaryPrimitives.WriteUInt16BigEndian(packet.AsSpan(2), code);
        text.CopyTo(packet, 4);
        await socket.SendAsync(packet, packet.Length, remote);
    }

    private string? ResolvePath(string fileName)
    {
        var relative = fileName.Replace('\\', '/').TrimStart('/');
        var candidate = Path.GetFullPath(Path.Combine(_root, relative.Replace('/', Path.DirectorySeparatorChar)));
        var rootWithSeparator = _root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;

        if (!candidate.StartsWith(rootWithSeparator, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return candidate;
    }

    private static (string FileName, string Mode, Dictionary<string, string> Options) ParseRequest(byte[] data)
    {
        var index = 2;
        var fileName = ReadNullTerminated(data, ref index);
        var mode = ReadNullTerminated(data, ref index);
        var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        while (index < data.Length)
        {
            var name = ReadNullTerminated(data, ref index);
            if (string.IsNullOrEmpty(name))
            {
                continue;
            }

            var value = ReadNullTerminated(data, ref index);
            options[name] = value;
        }

        return (fileName, mode, options);
    }

    private static string ReadNullTerminated(byte[] data, ref int index)
    {
        var start = index;
        while (index < data.Length && data[index] != 0)
        {
            index++;
        }

        var text = Encoding.ASCII.GetString(data, start, index - start);
        if (index < data.Length)
        {
            index++;
        }

        return text;
    }

    private static byte[] BuildOack(List<(string Name, string Value)> options)
    {
        using var stream = new MemoryStream();
        Span<byte> header = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(header, OpOack);
        stream.Write(header);
        foreach (var (name, value) in options)
        {
            var nameBytes = Encoding.ASCII.GetBytes(name);
            var valueBytes = Encoding.ASCII.GetBytes(value);
            stream.Write(nameBytes);
            stream.WriteByte(0);
            stream.Write(valueBytes);
            stream.WriteByte(0);
        }

        return stream.ToArray();
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        try
        {
            _listener?.Dispose();
            if (_loop is not null)
            {
                await _loop.ConfigureAwait(false);
            }
        }
        catch
        {
            // Ignore shutdown races.
        }

        _cts.Dispose();
        _log.Info("tftp", "TFTP parado");
    }
}
