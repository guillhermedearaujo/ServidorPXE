using System.Diagnostics;
using System.Runtime.InteropServices;

namespace PXEForge.Core.Monitoring;

public sealed record ResourceSnapshot(
    DateTimeOffset Timestamp,
    double CpuPercent,
    long WorkingSetBytes,
    long PrivateBytes,
    long GcTotalBytes,
    int ThreadCount,
    int HandleCount,
    ulong TotalPhysicalBytes,
    ulong AvailablePhysicalBytes,
    double RamUsedPercent,
    int ActiveTftpSessions,
    int ActiveHttpSessions,
    long DhcpRequests,
    long TftpTransfers,
    long TftpBytesSent,
    bool IsThrottled,
    string ThrottleReason,
    string CapacityEstimate
);

public sealed class ResourceMonitor
{
    private readonly Process _process = Process.GetCurrentProcess();
    private TimeSpan _lastCpuTime = TimeSpan.Zero;
    private DateTime _lastCheck = DateTime.MinValue;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    public ResourceSnapshot GetSnapshot(int activeTftp, int activeHttp, long dhcpRequests, long tftpTransfers, long tftpBytesSent)
    {
        try { _process.Refresh(); } catch { }

        var now = DateTime.UtcNow;
        var cpuTime = TimeSpan.Zero;
        try { cpuTime = _process.TotalProcessorTime; } catch { }

        var cpuPercent = 0.0;
        if (_lastCheck != DateTime.MinValue)
        {
            var timeDiff = (now - _lastCheck).TotalMilliseconds;
            var cpuDiff = (cpuTime - _lastCpuTime).TotalMilliseconds;
            if (timeDiff > 0 && cpuDiff >= 0)
            {
                cpuPercent = cpuDiff / (timeDiff * Math.Max(1, Environment.ProcessorCount)) * 100.0;
                if (cpuPercent < 0) cpuPercent = 0;
                if (cpuPercent > 100) cpuPercent = 100;
            }
        }

        _lastCheck = now;
        _lastCpuTime = cpuTime;

        long gcBytes = 0;
        try { gcBytes = GC.GetGCMemoryInfo().HeapSizeBytes; } catch { }

        ulong totalPhys = 0;
        ulong availPhys = 0;
        double ramPercent = 0;

        try
        {
            var mem = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
            if (GlobalMemoryStatusEx(ref mem))
            {
                totalPhys = mem.ullTotalPhys;
                availPhys = mem.ullAvailPhys;
                ramPercent = mem.dwMemoryLoad;
            }
        }
        catch { }

        var isThrottled = cpuPercent >= 85.0 || ramPercent >= 85.0;
        var throttleReason = string.Empty;
        if (cpuPercent >= 85.0 && ramPercent >= 85.0) throttleReason = "CPU e RAM >= 85%";
        else if (cpuPercent >= 85.0) throttleReason = "CPU >= 85%";
        else if (ramPercent >= 85.0) throttleReason = "RAM >= 85%";

        // Estimativa conservadora por RAM livre
        var freeGb = totalPhys > 0 ? (availPhys / 1024.0 / 1024.0 / 1024.0) : 4.0;
        var estimated = 0;
        if (freeGb >= 10) estimated = (int)(freeGb / 0.25);
        else if (freeGb >= 6) estimated = (int)(freeGb / 0.3);
        else if (freeGb >= 4) estimated = (int)(freeGb / 0.35);
        else if (freeGb >= 2) estimated = (int)(freeGb / 0.5);
        else estimated = 1;

        if (cpuPercent > 80) estimated = Math.Max(1, estimated / 2);
        if (ramPercent > 85) estimated = Math.Max(1, estimated / 2);

        var cap = estimated <= 0
            ? "Capacidade: limitada (pouca RAM livre)"
            : $"Capacidade estimada: ~{estimated} cliente(s) simultâneo(s)";

        int threadCount = 0;
        int handleCount = 0;
        long workingSet = 0;
        long privateBytes = 0;
        try
        {
            _process.Refresh();
            threadCount = _process.Threads.Count;
            handleCount = _process.HandleCount;
            workingSet = _process.WorkingSet64;
            privateBytes = _process.PrivateMemorySize64;
        }
        catch { }

        return new ResourceSnapshot(
            DateTimeOffset.Now,
            Math.Round(cpuPercent, 1),
            workingSet,
            privateBytes,
            gcBytes,
            threadCount,
            handleCount,
            totalPhys,
            availPhys,
            Math.Round(ramPercent, 1),
            activeTftp,
            activeHttp,
            dhcpRequests,
            tftpTransfers,
            tftpBytesSent,
            isThrottled,
            throttleReason,
            cap
        );
    }

    public static string FormatBytes(long bytes)
    {
        if (bytes < 0) bytes = 0;
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        double value = bytes;
        int i = 0;
        while (value >= 1024 && i < units.Length - 1)
        {
            value /= 1024;
            i++;
        }
        return $"{value:0.0} {units[i]}";
    }

    public static string FormatBytes(ulong bytes) => FormatBytes((long)Math.Min(bytes, (ulong)long.MaxValue));
}
