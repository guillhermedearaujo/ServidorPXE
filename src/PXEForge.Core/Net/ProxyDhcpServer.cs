using System.Net;
using System.Net.Sockets;
using PXEForge.Core.Diagnostics;

namespace PXEForge.Core.Net;

public sealed class ProxyDhcpServer : IAsyncDisposable
{
    private readonly IPAddress _bindAddress;
    private readonly int _port;
    private readonly IPAddress _serverAddress;
    private readonly BootFileResolver _bootFiles;
    private readonly LogHub _log;
    private readonly int _relayPort;
    private readonly CancellationTokenSource _cts = new();
    private Socket? _socket;
    private Task? _loop;

    public ProxyDhcpServer(
        IPAddress bindAddress,
        int port,
        IPAddress serverAddress,
        BootFileResolver bootFiles,
        LogHub log,
        int relayPort = 67)
    {
        _bindAddress = bindAddress;
        _port = port;
        _serverAddress = serverAddress;
        _bootFiles = bootFiles;
        _log = log;
        _relayPort = relayPort;
    }

    public bool IsRunning => _loop is { IsCompleted: false };

    public long RequestsHandled => _requests;
    private long _requests;

    public void Start()
    {
        if (IsRunning)
        {
            return;
        }

        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        socket.EnableBroadcast = true;
        socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ExclusiveAddressUse, false);
        socket.Bind(new IPEndPoint(_bindAddress, _port));
        _socket = socket;
        _loop = Task.Run(() => LoopAsync(_cts.Token));
        _log.Info("dhcp", $"proxyDHCP escutando em {_bindAddress}:{_port} (servidor {_serverAddress})");
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        var buffer = new byte[1500];
        EndPoint remote = new IPEndPoint(IPAddress.Any, 0);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var received = await _socket!.ReceiveFromAsync(buffer, SocketFlags.None, remote, ct);
                var packetCopy = buffer.AsSpan(0, received.ReceivedBytes).ToArray();
                _ = Task.Run(() => HandleAsync(packetCopy, received.RemoteEndPoint, ct), ct);
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
                _log.Warn("dhcp", $"falha no receive: {ex.Message}");
            }
        }
    }

    private async Task HandleAsync(byte[] data, EndPoint remote, CancellationToken ct)
    {
        try
        {
            var request = DhcpPacket.Parse(data);
            if (request.Op != DhcpPacket.BootRequest || !request.IsPxeClient)
            {
                return;
            }

            var messageType = request.Options.TryGetValue(53, out var mt) && mt.Length > 0 ? mt[0] : (byte)0;
            if (messageType is not (DhcpPacket.MessageDiscover or DhcpPacket.MessageRequest))
            {
                return;
            }

            var bootFile = _bootFiles.Resolve(request);
            var replyType = messageType == DhcpPacket.MessageDiscover
                ? DhcpPacket.MessageOffer
                : DhcpPacket.MessageAck;

            var reply = DhcpPacket.CreateProxyReply(
                request,
                replyType,
                _serverAddress,
                bootFile,
                _serverAddress.ToString());
            var payload = reply.Build();

            // Relay agent present: answer to the relay on its port.
            var destination = !request.RelayAddress.Equals(IPAddress.Any)
                ? new IPEndPoint(request.RelayAddress, _relayPort)
                : new IPEndPoint(IPAddress.Broadcast, 68);

            await _socket!.SendToAsync(payload, SocketFlags.None, destination, ct);
            Interlocked.Increment(ref _requests);

            _log.Debug("dhcp",
                $"{request.MacAddress} arch={request.ClientArchitecture?.ToString() ?? "-"} " +
                $"{(request.IsIpxeClient ? "ipxe" : "firmware")} -> {(replyType == DhcpPacket.MessageOffer ? "OFFER" : "ACK")} " +
                $"{bootFile}");
        }
        catch (FormatException ex)
        {
            _log.Debug("dhcp", $"pacote ignorado: {ex.Message}");
        }
        catch (Exception ex)
        {
            _log.Warn("dhcp", $"falha ao responder: {ex.Message}");
        }
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        try
        {
            _socket?.Close();
            _socket?.Dispose();
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
        _log.Info("dhcp", "proxyDHCP parado");
    }
}
