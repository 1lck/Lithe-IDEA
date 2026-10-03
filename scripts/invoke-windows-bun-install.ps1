[CmdletBinding()]
param(
    [switch]$NoCache,
    [ValidateRange(1, 1200)][int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "The Bun install worker requires Windows Job Objects."
}

# Own the worker before Bun can spawn lifecycle scripts. The non-inheritable
# handle belongs to this worker process; Windows closes it at process exit and
# kills every remaining descendant, even when Bun has already exited on error.
# Do not dispose the handle in-process: the worker itself is a job member.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

public static class LitheBunInstallJob {
    static Timer deadline;
    const uint KillOnJobClose = 0x2000;
    const int ExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits {
        public long PerProcessUserTime, PerJobUserTime;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters {
        public ulong ReadOperations, WriteOperations, OtherOperations;
        public ulong ReadBytes, WriteBytes, OtherBytes;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits limits, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    public static IntPtr AttachWorker() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits = new ExtendedLimits();
        limits.Basic.LimitFlags = KillOnJobClose;
        if (!SetInformationJobObject(job, ExtendedLimitInformation, ref limits, (uint)Marshal.SizeOf(limits)) ||
            !AssignProcessToJobObject(job, GetCurrentProcess())) {
            int error = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(error, "Cannot own the Bun installation process tree.");
        }
        return job;
    }

    public static void StartDeadline(int seconds) {
        deadline = new Timer(_ => {
            Console.Error.WriteLine("Bun installation exceeded its " + seconds + " second deadline.");
            Environment.Exit(124);
        }, null, seconds * 1000, Timeout.Infinite);
    }

    public static void FinishDeadline() { deadline.Dispose(); }
}
'@

$installJob = [LitheBunInstallJob]::AttachWorker()
[LitheBunInstallJob]::StartDeadline($TimeoutSeconds)
$arguments = @("install", "--frozen-lockfile")
if ($NoCache) { $arguments += "--no-cache" }
& bun @arguments
$installExitCode = $LASTEXITCODE
[LitheBunInstallJob]::FinishDeadline()
[GC]::KeepAlive($installJob)
exit $installExitCode
