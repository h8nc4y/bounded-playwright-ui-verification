Set-StrictMode -Version Latest

# 実行系の分岐にcaller-controlledな`$env:OS`を使わず、.NETのkernel情報を正とする。
# これにより環境変数を偽装されてもcontainment方式が弱い経路へ切り替わらない。
$script:privateMarkerIsWindows =
    [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

# Windows PowerShell 5.1には子孫tree停止APIがないため、kill-on-close Jobを使う。
# direct child終了後もJob handleを保持し、pipeを握る孫processまで確実に停止する。
if ($script:privateMarkerIsWindows -and
    $null -eq ('BoundedPlaywrightUiVerification.PrivateMarkerJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace BoundedPlaywrightUiVerification
{
    public static class PrivateMarkerJob
    {
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const uint JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800;
        private const uint JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000;
        private const int JobObjectExtendedLimitInformation = 9;

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(
            IntPtr jobAttributes,
            string name
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(
            IntPtr job,
            IntPtr process
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool IsProcessInJob(
            IntPtr process,
            IntPtr job,
            out bool result
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength,
            IntPtr returnLength
        );

        public static IntPtr CreateKillOnClose()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateJobObject failed."
                );
            }

            var information = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            information.BasicLimitInformation.LimitFlags =
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(
                typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
            );
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(information, buffer, false);
                if (!SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    buffer,
                    (uint)size
                ))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "SetInformationJobObject failed."
                    );
                }
                return job;
            }
            catch
            {
                CloseHandle(job);
                throw;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static void Assign(IntPtr job, IntPtr process)
        {
            if (!AssignProcessToJobObject(job, process))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "AssignProcessToJobObject failed."
                );
            }
        }

        public static bool Close(IntPtr job)
        {
            return job == IntPtr.Zero || CloseHandle(job);
        }

        public static bool IsCurrentProcessInOwnedJob()
        {
            bool inJob;
            if (!IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out inJob) ||
                !inJob)
            {
                return false;
            }

            int size = Marshal.SizeOf(
                typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
            );
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (!QueryInformationJobObject(
                    IntPtr.Zero,
                    JobObjectExtendedLimitInformation,
                    buffer,
                    (uint)size,
                    IntPtr.Zero
                ))
                {
                    return false;
                }
                var information =
                    (JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
                    Marshal.PtrToStructure(
                        buffer,
                        typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
                    );
                uint flags =
                    information.BasicLimitInformation.LimitFlags;
                return
                    (flags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) != 0 &&
                    (flags & JOB_OBJECT_LIMIT_BREAKAWAY_OK) == 0 &&
                    (flags & JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK) == 0;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }
}
'@
}

# Windows初回起動はtarget自身をsuspendedで作り、stdio以外のhandleを渡さない。
# Job割当後にだけresumeするため、native byte列とimmediate descendantを同時に守る。
if ($script:privateMarkerIsWindows -and
    $null -eq ('BoundedPlaywrightContainedProcess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class BoundedPlaywrightContainedProcess : IDisposable
{
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const int JobObjectExtendedLimitInformationClass = 9;
    private const uint CreateSuspended = 0x00000004;
    private const uint CreateUnicodeEnvironment = 0x00000400;
    private const uint ExtendedStartupInfoPresent = 0x00080000;
    private const uint CreateNoWindow = 0x08000000;
    private const uint StartfUseStdHandles = 0x00000100;
    private const uint HandleFlagInherit = 0x00000001;
    private const uint ResumeFailed = 0xFFFFFFFF;
    private const uint WaitObject0 = 0x00000000;
    private const uint WaitFailed = 0xFFFFFFFF;
    private static readonly IntPtr ProcThreadAttributeHandleList =
        new IntPtr(0x00020002);

    private IntPtr jobHandle;
    private IntPtr processHandle;
    private bool disposed;
    private int syntheticCloseFailuresRemaining;
    private const int CleanupTimeoutMilliseconds = 5000;
    private readonly Stopwatch cleanupClock = new Stopwatch();

    public Stream StandardInput { get; private set; }
    public Stream StandardOutput { get; private set; }
    public Stream StandardError { get; private set; }
    public static int LastSyntheticFailureProcessId { get; private set; }
    public static int LastSyntheticCloseAttemptCount { get; private set; }
    public static int LastSyntheticTerminateAttemptCount { get; private set; }

    private BoundedPlaywrightContainedProcess(
        IntPtr childProcess,
        Stream standardInput,
        Stream standardOutput,
        Stream standardError,
        IntPtr job,
        int syntheticCloseFailures)
    {
        processHandle = childProcess;
        StandardInput = standardInput;
        StandardOutput = standardOutput;
        StandardError = standardError;
        jobHandle = job;
        syntheticCloseFailuresRemaining = syntheticCloseFailures;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreatePipe(
        out IntPtr readPipe,
        out IntPtr writePipe,
        ref SECURITY_ATTRIBUTES pipeAttributes,
        int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetHandleInformation(
        IntPtr handle,
        uint mask,
        uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref STARTUPINFOEX startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr attributeList,
        int attributeCount,
        int flags,
        ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr attributeList,
        uint flags,
        IntPtr attribute,
        IntPtr value,
        IntPtr size,
        IntPtr previousValue,
        IntPtr returnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(
        IntPtr attributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        int informationClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION information,
        uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(
        IntPtr process,
        out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    private static string Quote(string value)
    {
        if (value.Length == 0)
            return "\"\"";
        if (value.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0)
            return value;

        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                slashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', (slashes * 2) + 1);
                result.Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes);
            slashes = 0;
            result.Append(character);
        }
        result.Append('\\', slashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static StringBuilder BuildCommandLine(
        string filePath,
        string[] arguments)
    {
        StringBuilder commandLine = new StringBuilder(Quote(filePath));
        foreach (string argument in arguments)
        {
            commandLine.Append(' ');
            commandLine.Append(Quote(argument ?? String.Empty));
        }
        return commandLine;
    }

    private static IntPtr BuildEnvironmentBlock(IDictionary environment)
    {
        List<string> entries = new List<string>();
        foreach (DictionaryEntry entry in environment)
        {
            string name = Convert.ToString(entry.Key);
            string value = Convert.ToString(entry.Value) ?? String.Empty;
            if (String.IsNullOrEmpty(name) ||
                name.IndexOf('=') >= 0 ||
                name.IndexOf('\0') >= 0 ||
                value.IndexOf('\0') >= 0)
            {
                throw new ArgumentException("Invalid child environment entry.");
            }
            entries.Add(name + "=" + value);
        }
        entries.Sort(StringComparer.OrdinalIgnoreCase);
        string block = String.Join("\0", entries.ToArray()) + "\0\0";
        return Marshal.StringToHGlobalUni(block);
    }

    private static IntPtr CreateKillOnCloseJob()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "CreateJobObject failed.");

        JOBOBJECT_EXTENDED_LIMIT_INFORMATION information =
            new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        information.BasicLimitInformation.LimitFlags =
            JobObjectLimitKillOnJobClose;
        if (!SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformationClass,
                ref information,
                (uint)Marshal.SizeOf(
                    typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))))
        {
            int error = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(error, "SetInformationJobObject failed.");
        }
        return job;
    }

    private static void CloseOwnedHandle(ref IntPtr handle)
    {
        if (handle != IntPtr.Zero)
        {
            CloseHandle(handle);
            handle = IntPtr.Zero;
        }
    }

    private static Exception TryCloseOwnedJobHandle(ref IntPtr handle)
    {
        if (handle == IntPtr.Zero)
            return null;
        IntPtr ownedHandle = handle;
        if (!CloseHandle(ownedHandle))
        {
            // Job handle は kill-on-close 境界そのものなので、失敗時に所有権を
            // 捨てない。caller が direct terminate 後に同じ値を再試行する。
            return new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Closing the owned Job failed.");
        }
        handle = IntPtr.Zero;
        return null;
    }

    private static int GetRemainingMilliseconds(
        Stopwatch clock,
        int deadlineMilliseconds)
    {
        if (!clock.IsRunning)
            clock.Start();
        long remaining = deadlineMilliseconds - clock.ElapsedMilliseconds;
        if (remaining <= 0)
            return 0;
        return remaining > Int32.MaxValue
            ? Int32.MaxValue
            : (int)remaining;
    }

    public static BoundedPlaywrightContainedProcess StartContained(
        string filePath,
        string[] arguments,
        IDictionary environment,
        string currentDirectory,
        int timeoutMilliseconds,
        string testFailureMode)
    {
        // pipe/environment prep、CreateProcess、Job assign、resume前確認を同じ時計へ含める。
        Stopwatch operationClock = Stopwatch.StartNew();
        // Self-test が直前の PID を誤認しないよう、fault injection ごとに
        // probe state を初期化する。production path では共有状態を更新しない。
        if (!String.IsNullOrEmpty(testFailureMode))
        {
            LastSyntheticFailureProcessId = 0;
            LastSyntheticCloseAttemptCount = 0;
            LastSyntheticTerminateAttemptCount = 0;
        }

        IntPtr stdinRead = IntPtr.Zero;
        IntPtr stdinWrite = IntPtr.Zero;
        IntPtr stdoutRead = IntPtr.Zero;
        IntPtr stdoutWrite = IntPtr.Zero;
        IntPtr stderrRead = IntPtr.Zero;
        IntPtr stderrWrite = IntPtr.Zero;
        IntPtr environmentBlock = IntPtr.Zero;
        IntPtr attributeList = IntPtr.Zero;
        IntPtr inheritedHandleList = IntPtr.Zero;
        IntPtr job = IntPtr.Zero;
        PROCESS_INFORMATION processInformation = new PROCESS_INFORMATION();
        SafeFileHandle stdinSafeHandle = null;
        SafeFileHandle stdoutSafeHandle = null;
        SafeFileHandle stderrSafeHandle = null;
        FileStream stdout = null;
        FileStream stderr = null;
        FileStream stdin = null;
        bool processCreated = false;
        bool processAssigned = false;
        bool attributeListInitialized = false;
        try
        {
            SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES();
            attributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            attributes.bInheritHandle = true;

            if (!CreatePipe(out stdinRead, out stdinWrite, ref attributes, 0) ||
                !CreatePipe(out stdoutRead, out stdoutWrite, ref attributes, 0) ||
                !CreatePipe(out stderrRead, out stderrWrite, ref attributes, 0))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreatePipe failed.");
            if (!SetHandleInformation(stdinWrite, HandleFlagInherit, 0) ||
                !SetHandleInformation(stdoutRead, HandleFlagInherit, 0) ||
                !SetHandleInformation(stderrRead, HandleFlagInherit, 0))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "SetHandleInformation failed.");

            // bInheritHandles=true でも child stdio 以外を渡さない。親側の
            // unrelated inheritable handle が Git やその孫へ漏れるのを防ぐ。
            IntPtr attributeListSize = IntPtr.Zero;
            InitializeProcThreadAttributeList(
                IntPtr.Zero, 1, 0, ref attributeListSize);
            if (attributeListSize == IntPtr.Zero)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "InitializeProcThreadAttributeList size query failed.");
            attributeList = Marshal.AllocHGlobal(attributeListSize);
            if (!InitializeProcThreadAttributeList(
                    attributeList, 1, 0, ref attributeListSize))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "InitializeProcThreadAttributeList failed.");
            attributeListInitialized = true;

            inheritedHandleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(inheritedHandleList, 0, stdinRead);
            Marshal.WriteIntPtr(inheritedHandleList, IntPtr.Size, stdoutWrite);
            Marshal.WriteIntPtr(
                inheritedHandleList, IntPtr.Size * 2, stderrWrite);
            if (!UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    ProcThreadAttributeHandleList,
                    inheritedHandleList,
                    new IntPtr(IntPtr.Size * 3),
                    IntPtr.Zero,
                    IntPtr.Zero))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "UpdateProcThreadAttribute failed.");

            STARTUPINFOEX startupInfo = new STARTUPINFOEX();
            startupInfo.StartupInfo.cb =
                Marshal.SizeOf(typeof(STARTUPINFOEX));
            startupInfo.StartupInfo.dwFlags = StartfUseStdHandles;
            startupInfo.StartupInfo.hStdInput = stdinRead;
            startupInfo.StartupInfo.hStdOutput = stdoutWrite;
            startupInfo.StartupInfo.hStdError = stderrWrite;
            startupInfo.lpAttributeList = attributeList;

            job = CreateKillOnCloseJob();
            environmentBlock = BuildEnvironmentBlock(environment);
            if (operationClock.ElapsedMilliseconds >= timeoutMilliseconds)
                throw new TimeoutException(
                    "Contained child operation deadline expired before CreateProcessW.");
            if (!CreateProcessW(
                    filePath,
                    BuildCommandLine(filePath, arguments),
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CreateSuspended |
                        CreateUnicodeEnvironment |
                        CreateNoWindow |
                        ExtendedStartupInfoPresent,
                    environmentBlock,
                    String.IsNullOrWhiteSpace(currentDirectory)
                        ? null
                        : currentDirectory,
                    ref startupInfo,
                    out processInformation))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "CreateProcessW failed.");
            }
            processCreated = true;
            if (!String.IsNullOrEmpty(testFailureMode))
                LastSyntheticFailureProcessId =
                    processInformation.dwProcessId;

            // Job 割当前の synthetic failure でも target は suspended のまま。
            // catch で terminate と wait の成否を検証してからだけ失敗を返す。
            if (String.Equals(
                    testFailureMode,
                    "assign",
                    StringComparison.Ordinal))
                throw new InvalidOperationException(
                    "Synthetic Job assignment failure.");
            if (!AssignProcessToJobObject(job, processInformation.hProcess))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "AssignProcessToJobObject failed.");
            processAssigned = true;

            stdinSafeHandle = new SafeFileHandle(stdinWrite, true);
            stdinWrite = IntPtr.Zero;
            stdoutSafeHandle = new SafeFileHandle(stdoutRead, true);
            stdoutRead = IntPtr.Zero;
            stderrSafeHandle = new SafeFileHandle(stderrRead, true);
            stderrRead = IntPtr.Zero;
            stdin = new FileStream(
                stdinSafeHandle, FileAccess.Write, 8192, false);
            stdinSafeHandle = null;
            stdout = new FileStream(
                stdoutSafeHandle, FileAccess.Read, 8192, false);
            stdoutSafeHandle = null;
            stderr = new FileStream(
                stderrSafeHandle, FileAccess.Read, 8192, false);
            stderrSafeHandle = null;

            // Child pipe ends must be closed in the parent before resume.
            CloseOwnedHandle(ref stdinRead);
            CloseOwnedHandle(ref stdoutWrite);
            CloseOwnedHandle(ref stderrWrite);

            // Job 割当後も resume 前に失敗させ、kill-on-close と bounded wait を
            // target codeを一度も実行せず実測できるようにする。
            if (String.Equals(
                    testFailureMode,
                    "deadline-before-resume",
                    StringComparison.Ordinal))
                System.Threading.Thread.Sleep(timeoutMilliseconds + 100);
            if (operationClock.ElapsedMilliseconds >= timeoutMilliseconds)
                throw new TimeoutException(
                    "Contained child operation deadline expired before ResumeThread.");
            if (String.Equals(
                    testFailureMode,
                    "resume",
                    StringComparison.Ordinal))
                throw new InvalidOperationException(
                    "Synthetic ResumeThread failure.");
            if (ResumeThread(processInformation.hThread) == ResumeFailed)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "ResumeThread failed.");
            CloseOwnedHandle(ref processInformation.hThread);

            BoundedPlaywrightContainedProcess result =
                new BoundedPlaywrightContainedProcess(
                    processInformation.hProcess,
                    stdin,
                    stdout,
                    stderr,
                    job,
                    String.Equals(
                        testFailureMode,
                        "close-once",
                        StringComparison.Ordinal) ? 1 : 0);
            processInformation.hProcess = IntPtr.Zero;
            stdin = null;
            stdout = null;
            stderr = null;
            job = IntPtr.Zero;
            return result;
        }
        catch (Exception launchFailure)
        {
            // launch failure cleanupは複数waitを跨いでも単一のabsolute slackに収める。
            Stopwatch cleanupClock = Stopwatch.StartNew();
            Exception cleanupFailure = null;
            if (processCreated)
            {
                if (processAssigned && job != IntPtr.Zero)
                {
                    // Job close failure時はhandleをfinallyの再試行用に残し、
                    // suspended processを直接terminateするfallbackも要求する。
                    Exception closeFailure =
                        TryCloseOwnedJobHandle(ref job);
                    if (closeFailure != null)
                    {
                        cleanupFailure = closeFailure;
                        if (!TerminateProcess(
                                processInformation.hProcess,
                                1))
                        {
                            Exception terminateFailure =
                                new Win32Exception(
                                    Marshal.GetLastWin32Error(),
                                    "Fallback process termination failed.");
                            cleanupFailure = new AggregateException(
                                cleanupFailure,
                                terminateFailure);
                        }
                    }
                }
                else if (!TerminateProcess(processInformation.hProcess, 1))
                {
                    cleanupFailure = new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Terminating the suspended process failed.");
                }

                uint waitResult = WaitForSingleObject(
                    processInformation.hProcess,
                    (uint)GetRemainingMilliseconds(
                        cleanupClock,
                        CleanupTimeoutMilliseconds));
                if (waitResult != WaitObject0)
                {
                    Exception waitFailure = waitResult == WaitFailed
                        ? (Exception)new Win32Exception(
                            Marshal.GetLastWin32Error(),
                            "Waiting for launch-failure cleanup failed.")
                        : new TimeoutException(
                            "Launch-failure cleanup exceeded 5000 ms.");
                    cleanupFailure = cleanupFailure == null
                        ? waitFailure
                        : new AggregateException(cleanupFailure, waitFailure);
                }
            }
            // CreateProcess前の失敗でもJob handleを成功確認なしに捨てない。
            // post-launch close失敗時はdirect termination + wait後に同じhandleを再試行する。
            if (job != IntPtr.Zero)
            {
                Exception retryCloseFailure =
                    TryCloseOwnedJobHandle(ref job);
                if (retryCloseFailure != null)
                {
                    cleanupFailure = cleanupFailure == null
                        ? retryCloseFailure
                        : new AggregateException(
                            cleanupFailure,
                            retryCloseFailure);
                }
                else if (processCreated)
                {
                    // direct terminateが失敗してもretry closeのkill-on-closeが効く。
                    // handleを閉じた後にも終了を有限時間で確認してから失敗を返す。
                    uint postRetryWaitResult = WaitForSingleObject(
                        processInformation.hProcess,
                        (uint)GetRemainingMilliseconds(
                            cleanupClock,
                            CleanupTimeoutMilliseconds));
                    if (postRetryWaitResult != WaitObject0)
                    {
                        Exception postRetryWaitFailure =
                            postRetryWaitResult == WaitFailed
                                ? (Exception)new Win32Exception(
                                    Marshal.GetLastWin32Error(),
                                    "Waiting after launch cleanup retry failed.")
                                : new TimeoutException(
                                    "Launch cleanup retry exceeded 5000 ms.");
                        cleanupFailure = cleanupFailure == null
                            ? postRetryWaitFailure
                            : new AggregateException(
                                cleanupFailure,
                                postRetryWaitFailure);
                    }
                }
            }
            if (cleanupFailure != null)
                throw new AggregateException(
                    "Contained child launch cleanup failed.",
                    launchFailure,
                    cleanupFailure);
            throw;
        }
        finally
        {
            if (environmentBlock != IntPtr.Zero)
                Marshal.FreeHGlobal(environmentBlock);
            if (attributeListInitialized)
                DeleteProcThreadAttributeList(attributeList);
            if (attributeList != IntPtr.Zero)
                Marshal.FreeHGlobal(attributeList);
            if (inheritedHandleList != IntPtr.Zero)
                Marshal.FreeHGlobal(inheritedHandleList);
            CloseOwnedHandle(ref stdinRead);
            CloseOwnedHandle(ref stdinWrite);
            CloseOwnedHandle(ref stdoutRead);
            CloseOwnedHandle(ref stdoutWrite);
            CloseOwnedHandle(ref stderrRead);
            CloseOwnedHandle(ref stderrWrite);
            CloseOwnedHandle(ref processInformation.hThread);
            CloseOwnedHandle(ref processInformation.hProcess);
            if (job != IntPtr.Zero)
            {
                // catch側の有限再試行が失敗した場合だけ最後のbest effortを行う。
                // ここでもCloseHandle成功後にだけzero化する。
                TryCloseOwnedJobHandle(ref job);
            }
            if (stdout != null)
                stdout.Dispose();
            if (stderr != null)
                stderr.Dispose();
            if (stdin != null)
                stdin.Dispose();
            if (stdinSafeHandle != null)
                stdinSafeHandle.Dispose();
            if (stdoutSafeHandle != null)
                stdoutSafeHandle.Dispose();
            if (stderrSafeHandle != null)
                stderrSafeHandle.Dispose();
        }
    }

    public bool WaitForExit(int milliseconds)
    {
        return WaitForSingleObject(processHandle, (uint)milliseconds) ==
            WaitObject0;
    }

    public bool HasExited
    {
        get { return WaitForSingleObject(processHandle, 0) == WaitObject0; }
    }

    public int ExitCode
    {
        get
        {
            uint exitCode;
            if (!GetExitCodeProcess(processHandle, out exitCode))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return unchecked((int)exitCode);
        }
    }

    public void CloseJob()
    {
        if (jobHandle == IntPtr.Zero)
            return;
        GetRemainingMilliseconds(
            cleanupClock,
            CleanupTimeoutMilliseconds);
        LastSyntheticCloseAttemptCount++;
        if (syntheticCloseFailuresRemaining > 0)
        {
            syntheticCloseFailuresRemaining--;
            throw new InvalidOperationException(
                "Synthetic Job close failure.");
        }
        IntPtr handle = jobHandle;
        if (!CloseHandle(handle))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        // CloseHandle 成功後だけ ownership を放棄する。失敗時は caller / Dispose
        // が同じ handle を再試行でき、kill-on-close 境界を失わない。
        jobHandle = IntPtr.Zero;
    }

    public void Terminate()
    {
        LastSyntheticTerminateAttemptCount++;
        if (processHandle == IntPtr.Zero || HasExited)
            return;
        if (!TerminateProcess(processHandle, 1))
        {
            int error = Marshal.GetLastWin32Error();
            if (HasExited)
                return;
            throw new Win32Exception(
                error,
                "Fallback process termination failed.");
        }
    }

    public void Dispose()
    {
        if (disposed)
            return;
        List<Exception> cleanupFailures = new List<Exception>();
        try
        {
            try
            {
                CloseJob();
            }
            catch (Exception closeFailure)
            {
                cleanupFailures.Add(closeFailure);
                // Job close が失敗しても direct child を走らせ続けない。
                // process termination と有限 wait の後、保持した Job handle を再試行する。
                try
                {
                    Terminate();
                    if (!HasExited &&
                        !WaitForExit(GetRemainingMilliseconds(
                            cleanupClock,
                            CleanupTimeoutMilliseconds)))
                    {
                        throw new TimeoutException(
                            "Fallback process termination exceeded 5000 ms.");
                    }
                }
                catch (Exception terminateFailure)
                {
                    cleanupFailures.Add(terminateFailure);
                }
                try
                {
                    CloseJob();
                    // TerminateProcessが失敗してもJob closeで停止できるため、
                    // retry成功後にprocess終了を改めてbounded確認する。
                    if (!HasExited &&
                        !WaitForExit(GetRemainingMilliseconds(
                            cleanupClock,
                            CleanupTimeoutMilliseconds)))
                    {
                        throw new TimeoutException(
                            "Fallback Job close exceeded 5000 ms.");
                    }
                }
                catch (Exception retryFailure)
                {
                    cleanupFailures.Add(retryFailure);
                }
            }
        }
        finally
        {
            try
            {
                StandardInput.Dispose();
                StandardOutput.Dispose();
                StandardError.Dispose();
            }
            finally
            {
                CloseOwnedHandle(ref processHandle);
            }
        }
        disposed = jobHandle == IntPtr.Zero;
        if (cleanupFailures.Count > 0)
        {
            throw new AggregateException(
                "Contained child cleanup required a fallback.",
                cleanupFailures.ToArray());
        }
    }
}
'@
}
# POSIX group signaling must distinguish ESRCH ("already gone") from EPERM
# and other failures. The kill utility commonly maps both to exit 1, so its
# process exit code is not a sufficient cleanup proof.
if (-not $script:privateMarkerIsWindows -and
    $null -eq ('BoundedPlaywrightUiVerification.PrivateMarkerPosixSignal' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace BoundedPlaywrightUiVerification
{
    public static class PrivateMarkerPosixSignal
    {
        private const int SIGKILL = 9;
        private const int ESRCH = 3;

        [DllImport("libc", SetLastError = true)]
        private static extern int kill(int pid, int signal);

        [DllImport("libc", SetLastError = true)]
        private static extern int getpgid(int pid);

        public static bool IsSuccessfulResult(int result, int error)
        {
            return result == 0 || (result == -1 && error == ESRCH);
        }

        public static bool IsProcessGroupLeader(int processId)
        {
            return processId > 0 && getpgid(processId) == processId;
        }

        public static bool KillProcessGroup(int processGroupId)
        {
            if (processGroupId <= 0)
            {
                return false;
            }
            int result = kill(-processGroupId, SIGKILL);
            int error = result == 0 ? 0 : Marshal.GetLastWin32Error();
            return IsSuccessfulResult(result, error);
        }
    }
}
'@
}

# PS5.1のnative process引数はArgumentListを使えないため、Windows規則で安全にquoteする。
function ConvertTo-PrivateMarkerProcessArgument {
    param([AllowEmptyString()][string]$Argument)

    if ([string]::IsNullOrEmpty($Argument)) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    # Windows PowerShell 5.1 lacks ProcessStartInfo.ArgumentList. Apply the
    # C-runtime escaping rules only for that compatibility path.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (($backslashes * 2) + 1))
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append([char]92, $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append([char]92, ($backslashes * 2))
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Get-PrivateMarkerPosixSetsidArguments {
    param(
        [string]$PowerShellExecutable,
        [string]$EncodedCommand
    )

    # BusyBox / util-linuxの共通契約は先頭operandのprogram pathだけに絞る。
    # util-linux固有optionを追加するとBusyBox hostが常時fail closedになる。
    return [string[]]@(
        $PowerShellExecutable,
        '-NoProfile',
        '-EncodedCommand',
        $EncodedCommand
    )
}

# operation / cleanup の各absolute deadlineから、次の有限waitへ渡せる残時間を求める。
function Get-PrivateMarkerRemainingMilliseconds {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Stopwatch,

        [Parameter(Mandatory = $true)]
        [long]$DeadlineMilliseconds
    )

    $remaining = $DeadlineMilliseconds - $Stopwatch.ElapsedMilliseconds
    if ($remaining -le 0) {
        return 0
    }
    if ($remaining -gt [int]::MaxValue) {
        return [int]::MaxValue
    }
    return [int]$remaining
}

# Git child はambient cloneをdenylistで削るのではなく、固定allowlistから再構築する。
function Set-PrivateMarkerHermeticGitEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.StringDictionary]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$IsolationRoot,

        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath
    )

    # PATHの先頭へ置くtarget directoryもcaller入力から解決させない。
    if (-not [System.IO.Path]::IsPathRooted($ExecutablePath) -or
        -not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        throw 'Sanitized Git executable must be an existing absolute file.'
    }
    $executableDirectory = Split-Path -Parent (
        [System.IO.Path]::GetFullPath($ExecutablePath)
    )
    $Environment.Clear()

    $homeDirectory = Join-Path $IsolationRoot 'home'
    $xdgDirectory = Join-Path $IsolationRoot 'xdg'
    $temporaryDirectory = Join-Path $IsolationRoot 'tmp'
    $templateDirectory = Join-Path $IsolationRoot 'empty-template'
    $hooksDirectory = Join-Path $IsolationRoot 'empty-hooks'
    foreach ($directory in @(
        $homeDirectory,
        $xdgDirectory,
        $temporaryDirectory,
        $templateDirectory,
        $hooksDirectory
    )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $emptyGlobalConfig = Join-Path $IsolationRoot 'empty-global.gitconfig'
    $emptySystemConfig = Join-Path $IsolationRoot 'empty-system.gitconfig'
    $emptyAttributes = Join-Path $IsolationRoot 'empty-attributes'
    $emptyExcludes = Join-Path $IsolationRoot 'empty-excludes'
    foreach ($emptyFile in @(
        $emptyGlobalConfig,
        $emptySystemConfig,
        $emptyAttributes,
        $emptyExcludes
    )) {
        if (-not (Test-Path -LiteralPath $emptyFile -PathType Leaf)) {
            [System.IO.File]::WriteAllText(
                $emptyFile,
                '',
                [System.Text.UTF8Encoding]::new($false)
            )
        }
    }

    # executable自身と固定OS directoryだけを許し、ambient shimやcredential helperを除く。
    $safePathEntries = New-Object System.Collections.Generic.List[string]
    $safePathEntries.Add($executableDirectory) | Out-Null
    if ($script:privateMarkerIsWindows) {
        $systemDirectory = [Environment]::SystemDirectory
        if (-not [string]::IsNullOrWhiteSpace($systemDirectory) -and
            (Test-Path -LiteralPath $systemDirectory -PathType Container)) {
            $safePathEntries.Add($systemDirectory) | Out-Null
            $windowsDirectory = Split-Path -Parent $systemDirectory
            $Environment['SystemRoot'] = $windowsDirectory
            $Environment['WINDIR'] = $windowsDirectory
            $Environment['ComSpec'] = Join-Path $systemDirectory 'cmd.exe'
        }
        $Environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
    } else {
        foreach ($systemPath in @('/usr/bin', '/bin')) {
            if (Test-Path -LiteralPath $systemPath -PathType Container) {
                $safePathEntries.Add($systemPath) | Out-Null
            }
        }
        $Environment['TMPDIR'] = $temporaryDirectory
    }
    $Environment['PATH'] = @($safePathEntries | Select-Object -Unique) -join (
        [System.IO.Path]::PathSeparator
    )

    $Environment['HOME'] = $homeDirectory
    $Environment['USERPROFILE'] = $homeDirectory
    $Environment['XDG_CONFIG_HOME'] = $xdgDirectory
    $Environment['TEMP'] = $temporaryDirectory
    $Environment['TMP'] = $temporaryDirectory
    $Environment['LC_ALL'] = 'C'
    $Environment['LANG'] = 'C'
    $Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $Environment['GIT_ATTR_NOSYSTEM'] = '1'
    $Environment['GIT_CONFIG_GLOBAL'] = $emptyGlobalConfig.Replace(
        [string][char]92,
        '/'
    )
    $Environment['GIT_CONFIG_SYSTEM'] = $emptySystemConfig.Replace(
        [string][char]92,
        '/'
    )
    $Environment['GIT_TERMINAL_PROMPT'] = '0'
    $Environment['GIT_LFS_SKIP_SMUDGE'] = '1'
    $Environment['GIT_OPTIONAL_LOCKS'] = '0'
    $Environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    $Environment['GIT_NO_LAZY_FETCH'] = '1'

    $safeConfig = @(
        [pscustomobject]@{
            Key = 'core.hooksPath'
            Value = $hooksDirectory.Replace([string][char]92, '/')
        },
        [pscustomobject]@{
            Key = 'core.attributesFile'
            Value = $emptyAttributes.Replace([string][char]92, '/')
        },
        [pscustomobject]@{
            Key = 'core.excludesFile'
            Value = $emptyExcludes.Replace([string][char]92, '/')
        },
        [pscustomobject]@{ Key = 'core.fsmonitor'; Value = 'false' },
        [pscustomobject]@{ Key = 'protocol.allow'; Value = 'never' },
        [pscustomobject]@{ Key = 'submodule.recurse'; Value = 'false' },
        [pscustomobject]@{
            Key = 'init.templateDir'
            Value = $templateDirectory.Replace([string][char]92, '/')
        }
    )
    $Environment['GIT_CONFIG_COUNT'] = [string]$safeConfig.Count
    for ($index = 0; $index -lt $safeConfig.Count; $index++) {
        $Environment["GIT_CONFIG_KEY_$index"] = $safeConfig[$index].Key
        $Environment["GIT_CONFIG_VALUE_$index"] = $safeConfig[$index].Value
    }
}

function New-PrivateMarkerTimedOutProcessResult {
    param(
        [int]$TimeoutMilliseconds,
        [bool]$ContainmentEstablished = $false
    )

    return [pscustomobject]@{
        ExitCode = -1
        StdoutBytes = [byte[]]@()
        StderrBytes = [byte[]]@()
        Output = "Process timed out after $TimeoutMilliseconds ms."
        TimedOut = $true
        OutputLimitExceeded = $false
        TreeStopped = $true
        StreamsDrained = $true
        ContainmentEstablished = $ContainmentEstablished
    }
}

# Windows PowerShell 5.1 は redirected StandardInput 用 StreamWriter を
# console encoding から生成し、UTF-8 BOM を raw BaseStream の前へ出す場合がある。
# property がある runtime は BOM なし encoding を StartInfo に固定し、無い
# runtime だけ Process.Start の瞬間に限って caller の console encoding を退避する。
function Start-PrivateMarkerProcessWithRawInput {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    $restoreConsoleInputEncoding = $false
    $originalConsoleInputEncoding = $null
    if ($script:privateMarkerIsWindows -and
        $Process.StartInfo.RedirectStandardInput -and
        $null -eq $Process.StartInfo.PSObject.Properties[
            'StandardInputEncoding'
        ]) {
        $originalConsoleInputEncoding = [Console]::InputEncoding
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
        $restoreConsoleInputEncoding = $true
    }
    try {
        return $Process.Start()
    }
    finally {
        if ($restoreConsoleInputEncoding) {
            [Console]::InputEncoding = $originalConsoleInputEncoding
        }
    }
}

# POSIXでは負のPGIDへsignalを送り、callerと別groupの子孫だけを有限時間で停止する。
function Stop-PrivateMarkerPosixProcessGroupBounded {
    param(
        [int]$ProcessGroupId,
        [int]$WaitMilliseconds = 5000
    )

    # kill(2) is synchronous as a signal-delivery decision. Success means
    # SIGKILL was accepted; ESRCH means the group was already gone. EPERM and
    # every other errno remain a cleanup failure.
    return [BoundedPlaywrightUiVerification.PrivateMarkerPosixSignal]::KillProcessGroup(
        $ProcessGroupId
    )
}

# 自分が所有権を証明できたJob/process groupだけを閉じ、無関係なprocessを殺さない。
function Stop-PrivateMarkerOwnedProcessTreeBounded {
    param(
        [System.Diagnostics.Process]$Process,
        [ref]$WindowsJobHandle,
        [int]$PosixProcessGroupId,
        [int]$WaitMilliseconds = 5000
    )

    $cleanupClock = [System.Diagnostics.Stopwatch]::StartNew()
    $cleanupDeadlineMilliseconds = [long][Math]::Max(0, $WaitMilliseconds)
    if ($WindowsJobHandle.Value -ne [IntPtr]::Zero) {
        $closed = [BoundedPlaywrightUiVerification.PrivateMarkerJob]::Close(
            $WindowsJobHandle.Value
        )
        if ($closed) {
            $WindowsJobHandle.Value = [IntPtr]::Zero
        } else {
            # Close failureでも direct child を放置せず、Process.Kill
            # （WindowsではTerminateProcess）と有限wait後に同じhandleを再試行する。
            if (-not $Process.HasExited) {
                try { $Process.Kill() } catch { }
                if (-not $Process.HasExited) {
                    $remaining = Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $cleanupClock `
                        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
                    [void]$Process.WaitForExit($remaining)
                }
            }
            $retryClosed =
                [BoundedPlaywrightUiVerification.PrivateMarkerJob]::Close(
                    $WindowsJobHandle.Value
                )
            if ($retryClosed) {
                $WindowsJobHandle.Value = [IntPtr]::Zero
                if (-not $Process.HasExited) {
                    $remaining = Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $cleanupClock `
                        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
                    [void]$Process.WaitForExit($remaining)
                }
            }
            # 一度でもcloseに失敗した境界は、再試行成功後もfail closedにする。
            return $false
        }
        if (-not $Process.HasExited) {
            $remaining = Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $cleanupClock `
                -DeadlineMilliseconds $cleanupDeadlineMilliseconds
            [void]$Process.WaitForExit($remaining)
        }
        return $closed -and $Process.HasExited
    }
    if ($PosixProcessGroupId -gt 0) {
        $groupStopped = Stop-PrivateMarkerPosixProcessGroupBounded `
            -ProcessGroupId $PosixProcessGroupId `
            -WaitMilliseconds (
                Get-PrivateMarkerRemainingMilliseconds `
                    -Stopwatch $cleanupClock `
                    -DeadlineMilliseconds $cleanupDeadlineMilliseconds
            )
        if (-not $Process.HasExited) {
            $remaining = Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $cleanupClock `
                -DeadlineMilliseconds $cleanupDeadlineMilliseconds
            [void]$Process.WaitForExit($remaining)
        }
        return $groupStopped -and $Process.HasExited
    }
    return Stop-PrivateMarkerProcessTreeBounded `
        -Process $Process `
        -WaitMilliseconds (
            Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $cleanupClock `
                -DeadlineMilliseconds $cleanupDeadlineMilliseconds
        )
}

# containment確立前の失敗時も直下processをboundedに回収する最後の防衛線。
function Stop-PrivateMarkerProcessTreeBounded {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$WaitMilliseconds = 5000
    )

    $cleanupClock = [System.Diagnostics.Stopwatch]::StartNew()
    $cleanupDeadlineMilliseconds = [long][Math]::Max(0, $WaitMilliseconds)
    if ($Process.HasExited) {
        return $true
    }

    try {
        $killTreeMethod = $Process.GetType().GetMethod('Kill', [Type[]]@([bool]))
        if ($null -ne $killTreeMethod) {
            [void]$killTreeMethod.Invoke($Process, @($true))
        } elseif ($script:privateMarkerIsWindows) {
            # .NET Framework has no Kill(entireProcessTree). taskkill /T is the
            # bounded Windows fallback and is itself bounded below.
            $taskkillInfo = New-Object System.Diagnostics.ProcessStartInfo
            $taskkillInfo.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $taskkillInfo.Arguments = "/PID $($Process.Id) /T /F"
            $taskkillInfo.UseShellExecute = $false
            $taskkillInfo.CreateNoWindow = $true
            $taskkill = [System.Diagnostics.Process]::Start($taskkillInfo)
            try {
                $remaining = Get-PrivateMarkerRemainingMilliseconds `
                    -Stopwatch $cleanupClock `
                    -DeadlineMilliseconds $cleanupDeadlineMilliseconds
                if (-not $taskkill.WaitForExit($remaining)) {
                    $taskkill.Kill()
                    $remaining = Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $cleanupClock `
                        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
                    [void]$taskkill.WaitForExit($remaining)
                }
            }
            finally {
                $taskkill.Dispose()
            }
        } else {
            $Process.Kill()
        }
    }
    catch {
        if (-not $Process.HasExited) {
            try { $Process.Kill() } catch { }
        }
    }

    $remaining = Get-PrivateMarkerRemainingMilliseconds `
        -Stopwatch $cleanupClock `
        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
    if (-not $Process.WaitForExit($remaining) -and -not $Process.HasExited) {
        try { $Process.Kill() } catch { }
        $remaining = Get-PrivateMarkerRemainingMilliseconds `
            -Stopwatch $cleanupClock `
            -DeadlineMilliseconds $cleanupDeadlineMilliseconds
        [void]$Process.WaitForExit($remaining)
    }
    return $Process.HasExited
}

# Atomic launcher の Job close failureは direct process termination、有限wait、
# 保持handleのclose再試行まで完了させる。回復できても異常自体は隠さない。
function Stop-PrivateMarkerAtomicWindowsChildBounded {
    param(
        [Parameter(Mandatory = $true)]
        [BoundedPlaywrightContainedProcess]$Child,
        [int]$WaitMilliseconds = 5000
    )

    $cleanupClock = [System.Diagnostics.Stopwatch]::StartNew()
    $cleanupDeadlineMilliseconds = [long][Math]::Max(0, $WaitMilliseconds)
    $firstCloseFailure = $null
    try {
        $Child.CloseJob()
    }
    catch {
        $firstCloseFailure = $_.Exception
    }

    if ($null -ne $firstCloseFailure) {
        $cleanupFailures =
            New-Object System.Collections.Generic.List[System.Exception]
        $cleanupFailures.Add($firstCloseFailure)
        try {
            $Child.Terminate()
            $remaining = Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $cleanupClock `
                -DeadlineMilliseconds $cleanupDeadlineMilliseconds
            if (-not $Child.HasExited -and
                -not $Child.WaitForExit($remaining)) {
                throw 'Fallback direct process termination exceeded its bounded wait.'
            }
        }
        catch {
            $cleanupFailures.Add($_.Exception)
        }
        $retryCloseSucceeded = $false
        try {
            # CloseJob は失敗時にhandle ownershipを保持するため再試行できる。
            $Child.CloseJob()
            $retryCloseSucceeded = $true
        }
        catch {
            $cleanupFailures.Add($_.Exception)
        }
        $remaining = Get-PrivateMarkerRemainingMilliseconds `
            -Stopwatch $cleanupClock `
            -DeadlineMilliseconds $cleanupDeadlineMilliseconds
        if ($retryCloseSucceeded -and
            -not $Child.HasExited -and
            -not $Child.WaitForExit($remaining)) {
            $cleanupFailures.Add(
                [TimeoutException]::new(
                    'Fallback Job close exceeded its bounded wait.'
                )
            )
        }
        throw [AggregateException]::new(
            'Atomic Windows child cleanup required a fallback.',
            [Exception[]]$cleanupFailures.ToArray()
        )
    }

    $remaining = Get-PrivateMarkerRemainingMilliseconds `
        -Stopwatch $cleanupClock `
        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
    if (-not $Child.HasExited -and
        -not $Child.WaitForExit($remaining)) {
        throw 'Child process did not exit after bounded Job termination.'
    }
}

# Windows atomic launcher専用のstream pump。全pipeをraw byteのまま同一deadlineで進める。
function Complete-PrivateMarkerAtomicStreams {
    param(
        [System.IO.Stream[]]$Streams,
        [System.Threading.Tasks.Task[]]$Tasks,
        [int]$WaitMilliseconds = 1000
    )

    $cleanupClock = [System.Diagnostics.Stopwatch]::StartNew()
    $cleanupDeadlineMilliseconds = [long][Math]::Max(0, $WaitMilliseconds)
    # child tree 停止後も pipe を継承した descendant が残る場合がある。まず
    # EOF を有限時間待ち、残った parent endpoint を閉じてから task 完了を
    # もう一度有限時間で確認する。未完了 task を残したまま return しない。
    $pending = @($Tasks | Where-Object {
        $null -ne $_ -and -not $_.IsCompleted
    })
    if ($pending.Count -gt 0) {
        try {
            $remaining = Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $cleanupClock `
                -DeadlineMilliseconds $cleanupDeadlineMilliseconds
            [void][System.Threading.Tasks.Task]::WaitAll(
                [System.Threading.Tasks.Task[]]$pending,
                $remaining)
        }
        catch {
            # fault/cancel も task 完了状態である。下の IsCompleted で判定する。
        }
    }

    $pending = @($Tasks | Where-Object {
        $null -ne $_ -and -not $_.IsCompleted
    })
    if ($pending.Count -gt 0) {
        foreach ($stream in $Streams) {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
        try {
            $remaining = Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $cleanupClock `
                -DeadlineMilliseconds $cleanupDeadlineMilliseconds
            [void][System.Threading.Tasks.Task]::WaitAll(
                [System.Threading.Tasks.Task[]]$pending,
                $remaining)
        }
        catch {
            # endpoint close に伴う fault/cancel は許容するが、未完了は拒否する。
        }
    }

    if (@($Tasks | Where-Object {
            $null -ne $_ -and -not $_.IsCompleted
        }).Count -gt 0) {
        throw 'Child process pipe cleanup did not complete after bounded disposal.'
    }
}

function Invoke-PrivateMarkerAtomicWindowsProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [hashtable]$Environment,
        [string]$WorkingDirectory = '',
        [byte[]]$StandardInputBytes = @(),
        [int]$TimeoutMilliseconds = 15000,
        [int]$MaxStandardOutputBytes = (4 * 1024 * 1024),
        [int]$MaxStandardErrorBytes = (1024 * 1024),
        [ValidateSet(
            '',
            'assign',
            'resume',
            'close-once',
            'deadline-before-resume'
        )]
        [string]$ForceWindowsLaunchFailure = ''
    )

    # suspended launch、Job assign、resume、stdio setupもtargetと同じ期限に含める。
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = [long]$TimeoutMilliseconds
    $cleanupClock = $null
    $cleanupDeadlineMilliseconds = 5000L

    # PowerShellは空byte[]をparameter binding時に`$null`へunrollし得る。
    if ($null -eq $StandardInputBytes) {
        $StandardInputBytes = New-Object byte[] 0
    }

    $process = $null
    $nativeChild = $null
    $stdinStream = $null
    $stdoutStream = $null
    $stderrStream = $null
    $stdoutBuffer = New-Object System.IO.MemoryStream
    $stderrBuffer = New-Object System.IO.MemoryStream
    $processStarted = $false
    $stdinTask = $null
    $stdoutTask = $null
    $stderrTask = $null
    try {
        if ($script:privateMarkerIsWindows) {
            try {
                $nativeChild = [BoundedPlaywrightContainedProcess]::StartContained(
                    $FilePath,
                    [string[]]$ArgumentList,
                    $Environment,
                    $WorkingDirectory,
                    $TimeoutMilliseconds,
                    $ForceWindowsLaunchFailure)
                $stdinStream = $nativeChild.StandardInput
                $stdoutStream = $nativeChild.StandardOutput
                $stderrStream = $nativeChild.StandardError
            }
            catch {
                $launchException = $_.Exception
                $launchTimedOut = $false
                while ($null -ne $launchException) {
                    # cleanup failureを含むAggregateは単純timeoutへ格下げしない。
                    if ($launchException -is [AggregateException]) {
                        break
                    }
                    if ($launchException -is [TimeoutException]) {
                        $launchTimedOut = $true
                        break
                    }
                    $launchException = $launchException.InnerException
                }
                if ($launchTimedOut) {
                    return [pscustomobject]@{
                        ExitCode = -1
                        StandardOutputBytes = [byte[]]@()
                        StandardErrorBytes = [byte[]]@()
                        TimedOut = $true
                        OutputLimitExceeded = ''
                        ContainmentEstablished = $false
                    }
                }
                throw 'child-process-containment-unavailable'
            }
        } else {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $FilePath
            if ($null -ne $startInfo.PSObject.Properties['ArgumentList']) {
                foreach ($argument in $ArgumentList) {
                    $startInfo.ArgumentList.Add([string]$argument)
                }
            } else {
                $startInfo.Arguments = (($ArgumentList | ForEach-Object {
                    ConvertTo-PrivateMarkerProcessArgument -Argument ([string]$_)
                }) -join ' ')
            }
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            if ($null -ne $startInfo.PSObject.Properties[
                'StandardInputEncoding'
            ]) {
                $startInfo.StandardInputEncoding =
                    [Text.UTF8Encoding]::new($false)
            }
            $startInfo.EnvironmentVariables.Clear()
            foreach ($entry in $Environment.GetEnumerator()) {
                $startInfo.EnvironmentVariables[[string]$entry.Key] =
                    [string]$entry.Value
            }
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            if (-not (Start-PrivateMarkerProcessWithRawInput `
                -Process $process)) {
                throw 'Bounded child start failed.'
            }
            $stdinStream = $process.StandardInput.BaseStream
            $stdoutStream = $process.StandardOutput.BaseStream
            $stderrStream = $process.StandardError.BaseStream
        }
        $processStarted = $true

        # stdin write と stdout/stderr read を同時に進め、batch input/output の
        # pipe backpressure で相互待ちしない。全taskが同じdeadlineを共有する。
        $stdinClosed = $StandardInputBytes.Length -eq 0
        if ($stdinClosed) {
            $stdinStream.Dispose()
        } else {
            $stdinTask = $stdinStream.WriteAsync(
                $StandardInputBytes, 0, $StandardInputBytes.Length)
        }
        $stdoutChunk = New-Object byte[] 8192
        $stderrChunk = New-Object byte[] 8192
        $stdoutTask = $stdoutStream.ReadAsync(
            $stdoutChunk, 0, $stdoutChunk.Length)
        $stderrTask = $stderrStream.ReadAsync(
            $stderrChunk, 0, $stderrChunk.Length)
        $stdoutClosed = $false
        $stderrClosed = $false
        $limitExceeded = ''
        # callerの残時間を秒へ切り上げず、launch前から続く同じ時計で全stdioへ適用する。
        $jobClosedAfterParentExit = $false

        while ((-not $stdinClosed -or -not $stdoutClosed -or
                -not $stderrClosed) -and
            [string]::IsNullOrEmpty($limitExceeded)) {
            $remaining = if ($null -eq $cleanupClock) {
                Get-PrivateMarkerRemainingMilliseconds `
                    -Stopwatch $stopwatch `
                    -DeadlineMilliseconds $deadline
            } else {
                Get-PrivateMarkerRemainingMilliseconds `
                    -Stopwatch $cleanupClock `
                    -DeadlineMilliseconds $cleanupDeadlineMilliseconds
            }
            if ($remaining -le 0) {
                break
            }
            $pendingTasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
            if (-not $stdoutClosed) {
                $pendingTasks.Add($stdoutTask)
            }
            if (-not $stderrClosed) {
                $pendingTasks.Add($stderrTask)
            }
            if (-not $stdinClosed) {
                $pendingTasks.Add($stdinTask)
            }
            [void][System.Threading.Tasks.Task]::WaitAny(
                $pendingTasks.ToArray(),
                [Math]::Min(100, $remaining))

            if (-not $stdoutClosed -and $stdoutTask.IsCompleted) {
                try {
                    $count = $stdoutTask.GetAwaiter().GetResult()
                }
                catch {
                    throw 'Child process stdout read failed.'
                }
                if ($count -eq 0) {
                    $stdoutClosed = $true
                } elseif (($stdoutBuffer.Length + $count) -gt $MaxStandardOutputBytes) {
                    $limitExceeded = 'stdout'
                } else {
                    $stdoutBuffer.Write($stdoutChunk, 0, $count)
                    $stdoutTask = $stdoutStream.ReadAsync(
                        $stdoutChunk, 0, $stdoutChunk.Length)
                }
            }

            if (-not $stderrClosed -and $stderrTask.IsCompleted) {
                try {
                    $count = $stderrTask.GetAwaiter().GetResult()
                }
                catch {
                    throw 'Child process stderr read failed.'
                }
                if ($count -eq 0) {
                    $stderrClosed = $true
                } elseif (($stderrBuffer.Length + $count) -gt $MaxStandardErrorBytes) {
                    $limitExceeded = 'stderr'
                } else {
                    $stderrBuffer.Write($stderrChunk, 0, $count)
                    $stderrTask = $stderrStream.ReadAsync(
                        $stderrChunk, 0, $stderrChunk.Length)
                }
            }

            if (-not $stdinClosed -and $stdinTask.IsCompleted) {
                try {
                    [void]$stdinTask.GetAwaiter().GetResult()
                }
                catch {
                    throw 'Child process stdin write failed.'
                }
                $stdinStream.Dispose()
                $stdinClosed = $true
            }

            # direct childが先に終了してもpipeを握る孫をdeadlineまで放置しない。
            # Jobを即時closeし、残るasync readは下のbounded drainで回収する。
            if ($null -ne $nativeChild -and
                -not $jobClosedAfterParentExit -and
                $nativeChild.HasExited -and
                (-not $stdoutClosed -or -not $stderrClosed)) {
                if ($null -eq $cleanupClock) {
                    $cleanupClock =
                        [System.Diagnostics.Stopwatch]::StartNew()
                }
                $cleanupRemaining =
                    Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $cleanupClock `
                        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
                Stop-PrivateMarkerAtomicWindowsChildBounded `
                    -Child $nativeChild `
                    -WaitMilliseconds $cleanupRemaining
                $jobClosedAfterParentExit = $true
            }
        }

        $remaining = if ($null -eq $cleanupClock) {
            Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $stopwatch `
                -DeadlineMilliseconds $deadline
        } else {
            Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $cleanupClock `
                -DeadlineMilliseconds $cleanupDeadlineMilliseconds
        }
        $streamsCompleted = $stdinClosed -and $stdoutClosed -and $stderrClosed
        $processExited = $false
        if ($streamsCompleted -and [string]::IsNullOrEmpty($limitExceeded)) {
            $processExited = if ($null -ne $nativeChild) {
                $nativeChild.WaitForExit($remaining)
            } else {
                $process.WaitForExit($remaining)
            }
        }
        $timedOut = (
            [string]::IsNullOrEmpty($limitExceeded) -and
            -not ($streamsCompleted -and $processExited))
        if ($timedOut -or -not [string]::IsNullOrEmpty($limitExceeded)) {
            if ($null -eq $cleanupClock) {
                $cleanupClock =
                    [System.Diagnostics.Stopwatch]::StartNew()
            }
            $cleanupRemaining =
                Get-PrivateMarkerRemainingMilliseconds `
                    -Stopwatch $cleanupClock `
                    -DeadlineMilliseconds $cleanupDeadlineMilliseconds
            if ($null -ne $nativeChild) {
                Stop-PrivateMarkerAtomicWindowsChildBounded `
                    -Child $nativeChild `
                    -WaitMilliseconds $cleanupRemaining
            } elseif (-not $process.HasExited) {
                [void](Stop-PrivateMarkerProcessTreeBounded `
                    -Process $process `
                    -WaitMilliseconds $cleanupRemaining)
                $cleanupRemaining =
                    Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $cleanupClock `
                        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
                if (-not $process.HasExited -and
                    -not $process.WaitForExit($cleanupRemaining)) {
                    throw 'Child process did not exit after bounded tree termination.'
                }
            }
            $cleanupRemaining =
                Get-PrivateMarkerRemainingMilliseconds `
                    -Stopwatch $cleanupClock `
                    -DeadlineMilliseconds $cleanupDeadlineMilliseconds
            Complete-PrivateMarkerAtomicStreams `
                -Streams @($stdinStream, $stdoutStream, $stderrStream) `
                -Tasks @($stdinTask, $stdoutTask, $stderrTask) `
                -WaitMilliseconds $cleanupRemaining
        }

        [byte[]]$stdoutBytes = @()
        [byte[]]$stderrBytes = @()
        if (-not $timedOut -and [string]::IsNullOrEmpty($limitExceeded)) {
            $stdoutBytes = $stdoutBuffer.ToArray()
            $stderrBytes = $stderrBuffer.ToArray()
        }
        return [pscustomobject]@{
            ExitCode = if ($timedOut -or -not [string]::IsNullOrEmpty($limitExceeded)) {
                -1
            } elseif ($null -ne $nativeChild) {
                $nativeChild.ExitCode
            } else {
                $process.ExitCode
            }
            StandardOutputBytes = $stdoutBytes
            StandardErrorBytes = $stderrBytes
            TimedOut = $timedOut
            OutputLimitExceeded = $limitExceeded
            ContainmentEstablished = $true
        }
    }
    catch {
        $originalFailure = $_
        $cleanupFailure = $null
        if ($processStarted) {
            if ($null -eq $cleanupClock) {
                $cleanupClock =
                    [System.Diagnostics.Stopwatch]::StartNew()
            }
            try {
                $cleanupRemaining =
                    Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $cleanupClock `
                        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
                if ($null -ne $nativeChild) {
                    Stop-PrivateMarkerAtomicWindowsChildBounded `
                        -Child $nativeChild `
                        -WaitMilliseconds $cleanupRemaining
                } elseif (-not $process.HasExited) {
                    [void](Stop-PrivateMarkerProcessTreeBounded `
                        -Process $process `
                        -WaitMilliseconds $cleanupRemaining)
                    $cleanupRemaining =
                        Get-PrivateMarkerRemainingMilliseconds `
                            -Stopwatch $cleanupClock `
                            -DeadlineMilliseconds `
                                $cleanupDeadlineMilliseconds
                    if (-not $process.HasExited -and
                        -not $process.WaitForExit($cleanupRemaining)) {
                        throw 'Child process did not exit after bounded tree termination.'
                    }
                }
                $cleanupRemaining =
                    Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $cleanupClock `
                        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
                Complete-PrivateMarkerAtomicStreams `
                    -Streams @($stdinStream, $stdoutStream, $stderrStream) `
                    -Tasks @($stdinTask, $stdoutTask, $stderrTask) `
                    -WaitMilliseconds $cleanupRemaining
            }
            catch {
                $cleanupFailure = $_
            }
        }
        if ($null -ne $cleanupFailure) {
            throw $cleanupFailure
        }
        throw $originalFailure
    }
    finally {
        $stdoutBuffer.Dispose()
        $stderrBuffer.Dispose()
        if ($null -ne $nativeChild) {
            $nativeChild.Dispose()
        } elseif ($null -ne $process) {
            if ($null -ne $stdinStream) { $stdinStream.Dispose() }
            if ($null -ne $stdoutStream) { $stdoutStream.Dispose() }
            if ($null -ne $stderrStream) { $stderrStream.Dispose() }
            $process.Dispose()
        }
    }
}

# child-only環境、出力量、deadline、tree cleanupを1か所で強制するprocess境界。
function Invoke-PrivateMarkerBoundedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$IsolationRoot,

        [string]$WorkingDirectory = '',

        [hashtable]$InheritedEnvironment = @{},

        [AllowNull()]
        [byte[]]$StandardInputBytes = $null,

        [int]$MaxStdinBytes = 1048576,

        [int]$TimeoutMilliseconds = 30000,

        # Native child output is untrusted. Bound both streams independently so
        # a corrupted repository, fake executable, or noisy failure cannot grow
        # the scanner process without limit.
        [int]$MaxStdoutBytes = 16777216,

        [int]$MaxStderrBytes = 1048576,

        [int]$DrainTimeoutMilliseconds = 5000,

        # Test-only selector for the portable libc setsid gate. Production
        # POSIX calls use it automatically when an external setsid is absent.
        [switch]$ForceNativePosixSessionGate,

        # Use only when testing the public scanner entrypoint. The scanner must
        # receive the hostile parent environment and isolate its own Git child.
        [switch]$PassThroughGitEnvironment,

        # Self-test専用。Job割当前/Resume前のfailureでもsuspended targetを
        # 実行せず、Terminate/Job closeとwaitをboundedに完了させる。
        [ValidateSet(
            '',
            'assign',
            'resume',
            'close-once',
            'deadline-before-resume'
        )]
        [string]$ForceWindowsLaunchFailure = '',

        # Self-test専用。prep開始後の遅延もoperation deadlineへ含まれることを検証する。
        [ValidateRange(0, 5000)]
        [int]$ForcePreLaunchDelayMilliseconds = 0,

        # Self-test専用。POSIX session確立後・ready公開前の期限切れを再現する。
        [ValidateRange(0, 5000)]
        [int]$ForcePosixGateDelayMilliseconds = 0
    )

    if ($TimeoutMilliseconds -le 0 -or
        $MaxStdinBytes -lt 0 -or
        $MaxStdoutBytes -lt 0 -or
        $MaxStderrBytes -lt 0 -or
        $DrainTimeoutMilliseconds -le 0) {
        throw 'Bounded process limits must be positive (output limits may be zero).'
    }
    if ($null -ne $StandardInputBytes -and
        $StandardInputBytes.Length -gt $MaxStdinBytes) {
        throw 'Bounded process standard input exceeds the configured byte limit.'
    }

    # prep、Process.Start、containment、target、stdioは全てこのabsolute deadlineを共有する。
    $operationClock = [System.Diagnostics.Stopwatch]::StartNew()
    $operationDeadlineMilliseconds = [long]$TimeoutMilliseconds
    if ($ForcePreLaunchDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $ForcePreLaunchDelayMilliseconds
    }

    $ownedJobMarkerName =
        'BOUNDED_PLAYWRIGHT_UI_VERIFICATION_OWNED_WINDOWS_JOB'
    $reuseOwnedWindowsJob = $false
    if ($script:privateMarkerIsWindows -and
        [Environment]::GetEnvironmentVariable($ownedJobMarkerName) -eq '1') {
        $reuseOwnedWindowsJob =
            [BoundedPlaywrightUiVerification.PrivateMarkerJob]::
                IsCurrentProcessInOwnedJob()
    }

    $effectiveFileName = $FileName
    $effectiveArguments = @($Arguments)
    $useAtomicWindowsContainment =
        $script:privateMarkerIsWindows -and -not $reuseOwnedWindowsJob
    $usePosixProcessGroup = $false
    $useNativePosixSessionGate = $false
    $posixGateReadyPath = $null
    $posixGateReleasePath = $null
    if (-not $script:privateMarkerIsWindows) {
        $setsidPath = @('/usr/bin/setsid', '/bin/setsid') |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        $usePosixProcessGroup = $true
        $useNativePosixSessionGate =
            $ForceNativePosixSessionGate -or
            [string]::IsNullOrWhiteSpace($setsidPath)

        # external / native の両経路でready PIDを公開し、kernelが同じPGIDを返すまで
        # targetをreleaseしない。これによりProcess.Start直後のESRCH raceを閉じる。
        $gateId = [Guid]::NewGuid().ToString('N')
        $posixGateReadyPath = Join-Path `
            $IsolationRoot `
            "posix-session-ready-$gateId"
        $posixGateReleasePath = Join-Path `
            $IsolationRoot `
            "posix-session-release-$gateId"
        $payloadJson = [pscustomobject]@{
            FileName = $FileName
            Arguments = @($Arguments)
        } | ConvertTo-Json -Compress -Depth 4
        $payloadBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($payloadJson)
        )
        $readyPathBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($posixGateReadyPath)
        )
        $releasePathBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes($posixGateReleasePath)
        )
        $posixWrapperTemplate = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (__CREATE_SESSION__) {
    if ($null -eq ('BoundedPlaywrightUiVerification.PrivateMarkerPosixSession' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;

namespace BoundedPlaywrightUiVerification
{
    public static class PrivateMarkerPosixSession
    {
        [DllImport("libc", SetLastError = true)]
        private static extern int setsid();

        public static int Create()
        {
            return setsid();
        }
    }
}
"@
    }
}
try {
    if (__CREATE_SESSION__) {
        if ([BoundedPlaywrightUiVerification.PrivateMarkerPosixSession]::Create() -lt 0) {
            [Console]::Error.WriteLine('Bounded POSIX session setup failed.')
            exit 126
        }
    }
    if (__GATE_DELAY_MILLISECONDS__ -gt 0) {
        Start-Sleep -Milliseconds __GATE_DELAY_MILLISECONDS__
    }
    $readyPath = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__READY_PATH__')
    )
    $releasePath = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__RELEASE_PATH__')
    )
    [IO.File]::WriteAllText(
        $readyPath,
        [Diagnostics.Process]::GetCurrentProcess().Id.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ),
        [Text.UTF8Encoding]::new($false)
    )
    $released = $false
    for ($gateAttempt = 0; $gateAttempt -lt 3000; $gateAttempt++) {
        if ([IO.File]::Exists($releasePath)) {
            $released = $true
            break
        }
        Start-Sleep -Milliseconds 10
    }
    if (-not $released) {
        exit 124
    }
    $payloadJson = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String('__PAYLOAD__')
    )
    $payload = ConvertFrom-Json -InputObject $payloadJson
    $invokeArguments = @($payload.Arguments | ForEach-Object { [string]$_ })
    & ([string]$payload.FileName) @invokeArguments
    $childExitCode = $LASTEXITCODE
    if ($null -eq $childExitCode) {
        $childExitCode = 0
    }
    exit [int]$childExitCode
}
catch {
    [Console]::Error.WriteLine('Bounded child launch failed.')
    exit 127
}
'@
        $createSessionLiteral = if ($useNativePosixSessionGate) {
            '$true'
        } else {
            '$false'
        }
        $posixWrapperScript = $posixWrapperTemplate.Replace(
            '__CREATE_SESSION__',
            $createSessionLiteral
        ).Replace(
            '__GATE_DELAY_MILLISECONDS__',
            [string]$ForcePosixGateDelayMilliseconds
        ).Replace(
            '__READY_PATH__',
            $readyPathBase64
        ).Replace(
            '__RELEASE_PATH__',
            $releasePathBase64
        ).Replace(
            '__PAYLOAD__',
            $payloadBase64
        )
        $posixWrapperBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($posixWrapperScript)
        )
        $currentPowerShellExecutable = (
            [Diagnostics.Process]::GetCurrentProcess()
        ).MainModule.FileName
        if ($useNativePosixSessionGate) {
            $effectiveFileName = $currentPowerShellExecutable
            $effectiveArguments = @(
                '-NoProfile',
                '-EncodedCommand',
                $posixWrapperBase64
            )
        } else {
            # util-linux固有optionを使わないoption-free operand形はBusyBoxでも解釈できる。
            $effectiveFileName = $setsidPath
            $effectiveArguments =
                Get-PrivateMarkerPosixSetsidArguments `
                    -PowerShellExecutable $currentPowerShellExecutable `
                    -EncodedCommand $posixWrapperBase64
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $effectiveFileName
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $StandardInputBytes
    if ($null -ne $StandardInputBytes -and
        $null -ne $startInfo.PSObject.Properties['StandardInputEncoding']) {
        $startInfo.StandardInputEncoding =
            [Text.UTF8Encoding]::new($false)
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentListProperty) {
        foreach ($argument in $effectiveArguments) {
            $startInfo.ArgumentList.Add($argument)
        }
    } else {
        $startInfo.Arguments = (
            $effectiveArguments | ForEach-Object {
                ConvertTo-PrivateMarkerProcessArgument -Argument $_
            }
        ) -join ' '
    }

    # ProcessStartInfoのchild cloneへtest overrideを適用し、親processは変更しない。
    $childEnvironment = $startInfo.EnvironmentVariables
    foreach ($name in $InheritedEnvironment.Keys) {
        $childEnvironment["$name"] = [string]$InheritedEnvironment[$name]
    }
    if (-not $PassThroughGitEnvironment) {
        # overrideも含むclone全体を最後に捨て、非Git名のcredential/markerも渡さない。
        Set-PrivateMarkerHermeticGitEnvironment `
            -Environment $childEnvironment `
            -IsolationRoot $IsolationRoot `
            -ExecutablePath $FileName
    }

    # allowlist再構築後だけ所有markerを足し、親由来の偽markerは必ず捨てる。
    $childEnvironment.Remove($ownedJobMarkerName)
    if ($script:privateMarkerIsWindows) {
        $childEnvironment[$ownedJobMarkerName] = '1'
    }

    $remainingOperationMilliseconds =
        Get-PrivateMarkerRemainingMilliseconds `
            -Stopwatch $operationClock `
            -DeadlineMilliseconds $operationDeadlineMilliseconds
    if ($remainingOperationMilliseconds -le 0) {
        return New-PrivateMarkerTimedOutProcessResult `
            -TimeoutMilliseconds $TimeoutMilliseconds
    }

    if ($useAtomicWindowsContainment) {
        # StringDictionaryをplain hashtableへ写し、C#へcaller-owned objectを渡さない。
        $atomicEnvironment = @{}
        foreach ($environmentName in @($childEnvironment.Keys)) {
            $atomicEnvironment["$environmentName"] =
                [string]$childEnvironment[$environmentName]
        }
        $atomicInput = if ($null -eq $StandardInputBytes) {
            [byte[]]@()
        } else {
            $StandardInputBytes
        }
        $remainingOperationMilliseconds =
            Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $operationClock `
                -DeadlineMilliseconds $operationDeadlineMilliseconds
        if ($remainingOperationMilliseconds -le 0) {
            return New-PrivateMarkerTimedOutProcessResult `
                -TimeoutMilliseconds $TimeoutMilliseconds
        }
        $atomicResult = Invoke-PrivateMarkerAtomicWindowsProcess `
            -FilePath $FileName `
            -ArgumentList ([string[]]$Arguments) `
            -Environment $atomicEnvironment `
            -WorkingDirectory $WorkingDirectory `
            -StandardInputBytes $atomicInput `
            -TimeoutMilliseconds $remainingOperationMilliseconds `
            -MaxStandardOutputBytes $MaxStdoutBytes `
            -MaxStandardErrorBytes $MaxStderrBytes `
            -ForceWindowsLaunchFailure $ForceWindowsLaunchFailure

        $atomicOutputLimitExceeded =
            -not [string]::IsNullOrEmpty($atomicResult.OutputLimitExceeded)
        $utf8 = [Text.UTF8Encoding]::new($false, $false)
        $atomicOutput = @(
            $utf8.GetString($atomicResult.StandardOutputBytes),
            $utf8.GetString($atomicResult.StandardErrorBytes)
        ) -join [Environment]::NewLine
        if ($atomicResult.TimedOut) {
            $atomicOutput += [Environment]::NewLine +
                "Process timed out after $TimeoutMilliseconds ms."
        }
        if ($atomicOutputLimitExceeded) {
            $atomicOutput += [Environment]::NewLine +
                'Process output exceeded the configured byte limit.'
        }
        return [pscustomobject]@{
            ExitCode = $atomicResult.ExitCode
            StdoutBytes = $atomicResult.StandardOutputBytes
            StderrBytes = $atomicResult.StandardErrorBytes
            Output = $atomicOutput.TrimEnd()
            TimedOut = $atomicResult.TimedOut
            OutputLimitExceeded = $atomicOutputLimitExceeded
            TreeStopped = $true
            StreamsDrained = $true
            ContainmentEstablished =
                $atomicResult.ContainmentEstablished
        }
    }

    $process = $null
    $processStarted = $false
    $windowsJobHandle = [IntPtr]::Zero
    $posixProcessGroupId = 0
    $containmentEstablished = $false
    $operationExpiredBeforeTarget = $false
    $cleanupClock = $null
    $cleanupDeadlineMilliseconds =
        [long]$DrainTimeoutMilliseconds + 5000L
    $ownedTreeStopRequested = $false
    $stdinTask = $null
    $stdoutTask = $null
    $stderrTask = $null
    $stdoutChunk = New-Object byte[] 8192
    $stderrChunk = New-Object byte[] 8192
    $stdoutBuffer = New-Object System.IO.MemoryStream
    $stderrBuffer = New-Object System.IO.MemoryStream
    $timedOut = $false
    $outputLimitExceeded = $false
    $treeStopped = $true
    $streamsDrained = $false
    $streamReadFailed = $false
    $exitCode = -1
    $stdoutBytes = [byte[]]@()
    $stderrBytes = [byte[]]@()
    try {
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if ((Get-PrivateMarkerRemainingMilliseconds `
                    -Stopwatch $operationClock `
                    -DeadlineMilliseconds $operationDeadlineMilliseconds) -le 0) {
            return New-PrivateMarkerTimedOutProcessResult `
                -TimeoutMilliseconds $TimeoutMilliseconds
        }
        if (-not (Start-PrivateMarkerProcessWithRawInput `
            -Process $process)) {
            throw "Failed to start bounded child process: $FileName"
        }
        $processStarted = $true
        if ((Get-PrivateMarkerRemainingMilliseconds `
                    -Stopwatch $operationClock `
                    -DeadlineMilliseconds $operationDeadlineMilliseconds) -le 0) {
            $timedOut = $true
            $operationExpiredBeforeTarget = $true
        }
        if ($usePosixProcessGroup) {
            if (-not $operationExpiredBeforeTarget) {
                $posixGateReady = $false
                $readyProcessId = 0
                while ((Get-PrivateMarkerRemainingMilliseconds `
                            -Stopwatch $operationClock `
                            -DeadlineMilliseconds `
                                $operationDeadlineMilliseconds) -gt 0) {
                    if ([IO.File]::Exists($posixGateReadyPath)) {
                        try {
                            $readyProcessText = [IO.File]::ReadAllText(
                                $posixGateReadyPath,
                                [Text.Encoding]::UTF8
                            )
                            if ([int]::TryParse(
                                    $readyProcessText,
                                    [Globalization.NumberStyles]::None,
                                    [Globalization.CultureInfo]::InvariantCulture,
                                    [ref]$readyProcessId
                                ) -and $readyProcessId -gt 0) {
                                $posixGateReady = $true
                                break
                            }
                        }
                        catch {
                            # create直後のempty/locked fileは次のbounded pollで再読する。
                        }
                    }
                    if ($process.HasExited) {
                        break
                    }
                    $gateRemaining =
                        Get-PrivateMarkerRemainingMilliseconds `
                            -Stopwatch $operationClock `
                            -DeadlineMilliseconds `
                                $operationDeadlineMilliseconds
                    if ($gateRemaining -gt 0) {
                        Start-Sleep -Milliseconds ([Math]::Min(
                            5,
                            $gateRemaining
                        ))
                    }
                }
                if (-not $posixGateReady) {
                    if ((Get-PrivateMarkerRemainingMilliseconds `
                                -Stopwatch $operationClock `
                                -DeadlineMilliseconds `
                                    $operationDeadlineMilliseconds) -le 0) {
                        $timedOut = $true
                        $operationExpiredBeforeTarget = $true
                    } else {
                        throw 'Failed to establish the bounded POSIX session gate.'
                    }
                } elseif (-not [BoundedPlaywrightUiVerification.PrivateMarkerPosixSignal]::
                        IsProcessGroupLeader($readyProcessId)) {
                    throw 'Failed to establish the bounded POSIX session gate.'
                }
                if (-not $operationExpiredBeforeTarget) {
                    # ready PIDが実PGIDであることをkernelへ確認した後だけtargetをreleaseする。
                    $posixProcessGroupId = $readyProcessId
                    $containmentEstablished = $true
                    if ((Get-PrivateMarkerRemainingMilliseconds `
                                -Stopwatch $operationClock `
                                -DeadlineMilliseconds `
                                    $operationDeadlineMilliseconds) -le 0) {
                        $timedOut = $true
                        $operationExpiredBeforeTarget = $true
                    } else {
                        try {
                            [IO.File]::WriteAllText(
                                $posixGateReleasePath,
                                'release',
                                [Text.UTF8Encoding]::new($false)
                            )
                        }
                        catch {
                            [void](Stop-PrivateMarkerPosixProcessGroupBounded `
                                -ProcessGroupId $posixProcessGroupId)
                            throw
                        }
                    }
                }
            }
        } elseif (-not $operationExpiredBeforeTarget) {
            # 再利用済みWindows Job内は親Jobが子孫ownershipを保持する。
            $containmentEstablished = $true
        }
        if ($operationExpiredBeforeTarget) {
            $cleanupClock = [System.Diagnostics.Stopwatch]::StartNew()
            $cleanupRemaining = Get-PrivateMarkerRemainingMilliseconds `
                -Stopwatch $cleanupClock `
                -DeadlineMilliseconds $cleanupDeadlineMilliseconds
            $treeStopped = Stop-PrivateMarkerOwnedProcessTreeBounded `
                -Process $process `
                -WindowsJobHandle ([ref]$windowsJobHandle) `
                -PosixProcessGroupId $posixProcessGroupId `
                -WaitMilliseconds $cleanupRemaining
            $ownedTreeStopRequested = $true
            $streamsDrained = $treeStopped
        } elseif ($null -ne $StandardInputBytes) {
            if ($StandardInputBytes.Length -eq 0) {
                $process.StandardInput.Close()
            } else {
                $stdinTask = $process.StandardInput.BaseStream.WriteAsync(
                    $StandardInputBytes,
                    0,
                    $StandardInputBytes.Length
                )
            }
        }
        if (-not $operationExpiredBeforeTarget) {
            $stdoutTask = $process.StandardOutput.BaseStream.ReadAsync(
            $stdoutChunk,
            0,
            $stdoutChunk.Length
        )
            $stderrTask = $process.StandardError.BaseStream.ReadAsync(
            $stderrChunk,
            0,
            $stderrChunk.Length
        )

            # target/stdioはoperation deadline、tree stop/drainは別のabsolute slackで進める。
            $stdoutClosed = $false
            $stderrClosed = $false
            $stdoutDiscarding = $false
            $stderrDiscarding = $false
            $stdinClosed = $null -eq $StandardInputBytes -or
                $StandardInputBytes.Length -eq 0
            $stdinWriteFailed = $false
            $exitObservedAt = -1L
            while ($true) {
                $operationRemaining =
                    Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $operationClock `
                        -DeadlineMilliseconds $operationDeadlineMilliseconds
                if ($null -eq $cleanupClock -and
                    $operationRemaining -le 0) {
                    $timedOut = $true
                    $cleanupClock =
                        [System.Diagnostics.Stopwatch]::StartNew()
                }
                $phaseRemaining = if ($null -eq $cleanupClock) {
                    $operationRemaining
                } else {
                    Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $cleanupClock `
                        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
                }
                if ($phaseRemaining -le 0) {
                    $streamsDrained = $false
                    break
                }

                if (-not $stdinClosed -and $stdinTask.IsCompleted) {
                    try {
                        [void]$stdinTask.GetAwaiter().GetResult()
                    }
                    catch {
                        $stdinWriteFailed = $true
                    }
                    try {
                        $process.StandardInput.Close()
                    }
                    catch {
                        $stdinWriteFailed = $true
                    }
                    $stdinClosed = $true
                }

                if (-not $stdoutClosed -and $stdoutTask.IsCompleted) {
                    try {
                        $stdoutCount = $stdoutTask.GetAwaiter().GetResult()
                    }
                    catch {
                        $streamReadFailed = $true
                        $stdoutCount = 0
                    }
                    if ($stdoutCount -eq 0) {
                        $stdoutClosed = $true
                    } elseif ($stdoutDiscarding -or
                        ($stdoutBuffer.Length + $stdoutCount) -gt
                        $MaxStdoutBytes) {
                        $outputLimitExceeded = $true
                        $stdoutDiscarding = $true
                        $stdoutTask =
                            $process.StandardOutput.BaseStream.ReadAsync(
                                $stdoutChunk,
                                0,
                                $stdoutChunk.Length
                            )
                    } else {
                        $stdoutBuffer.Write(
                            $stdoutChunk,
                            0,
                            $stdoutCount
                        )
                        $stdoutTask =
                            $process.StandardOutput.BaseStream.ReadAsync(
                                $stdoutChunk,
                                0,
                                $stdoutChunk.Length
                            )
                    }
                }

                if (-not $stderrClosed -and $stderrTask.IsCompleted) {
                    try {
                        $stderrCount = $stderrTask.GetAwaiter().GetResult()
                    }
                    catch {
                        $streamReadFailed = $true
                        $stderrCount = 0
                    }
                    if ($stderrCount -eq 0) {
                        $stderrClosed = $true
                    } elseif ($stderrDiscarding -or
                        ($stderrBuffer.Length + $stderrCount) -gt
                        $MaxStderrBytes) {
                        $outputLimitExceeded = $true
                        $stderrDiscarding = $true
                        $stderrTask =
                            $process.StandardError.BaseStream.ReadAsync(
                                $stderrChunk,
                                0,
                                $stderrChunk.Length
                            )
                    } else {
                        $stderrBuffer.Write(
                            $stderrChunk,
                            0,
                            $stderrCount
                        )
                        $stderrTask =
                            $process.StandardError.BaseStream.ReadAsync(
                                $stderrChunk,
                                0,
                                $stderrChunk.Length
                            )
                    }
                }

                if (($outputLimitExceeded -or $timedOut) -and
                    -not $ownedTreeStopRequested) {
                    if ($null -eq $cleanupClock) {
                        $cleanupClock =
                            [System.Diagnostics.Stopwatch]::StartNew()
                    }
                    $cleanupRemaining =
                        Get-PrivateMarkerRemainingMilliseconds `
                            -Stopwatch $cleanupClock `
                            -DeadlineMilliseconds `
                                $cleanupDeadlineMilliseconds
                    $ownedTreeStopRequested = $true
                    $treeStopped =
                        Stop-PrivateMarkerOwnedProcessTreeBounded `
                            -Process $process `
                            -WindowsJobHandle ([ref]$windowsJobHandle) `
                            -PosixProcessGroupId $posixProcessGroupId `
                            -WaitMilliseconds $cleanupRemaining
                }

                if ($process.HasExited -and $exitObservedAt -lt 0) {
                    $exitObservedAt =
                        $operationClock.ElapsedMilliseconds
                    $exitCode = $process.ExitCode
                }

                if ($process.HasExited -and $stdinClosed -and
                    $stdoutClosed -and $stderrClosed) {
                    $streamsDrained = -not $streamReadFailed -and
                        -not $stdinWriteFailed
                    break
                }

                if ($exitObservedAt -ge 0 -and
                    -not $ownedTreeStopRequested -and
                    ($operationClock.ElapsedMilliseconds -
                        $exitObservedAt) -ge 250) {
                    # 直下child終了後もpipeを握る孫は、独立cleanup slackで停止・drainする。
                    $cleanupClock =
                        [System.Diagnostics.Stopwatch]::StartNew()
                    $cleanupRemaining =
                        Get-PrivateMarkerRemainingMilliseconds `
                            -Stopwatch $cleanupClock `
                            -DeadlineMilliseconds `
                                $cleanupDeadlineMilliseconds
                    $ownedTreeStopRequested = $true
                    $treeStopped =
                        Stop-PrivateMarkerOwnedProcessTreeBounded `
                            -Process $process `
                            -WindowsJobHandle ([ref]$windowsJobHandle) `
                            -PosixProcessGroupId $posixProcessGroupId `
                            -WaitMilliseconds $cleanupRemaining
                }

                if ($exitObservedAt -ge 0 -and
                    ($operationClock.ElapsedMilliseconds -
                        $exitObservedAt) -ge $DrainTimeoutMilliseconds) {
                    $streamsDrained = $false
                    break
                }

                $phaseRemaining = if ($null -eq $cleanupClock) {
                    Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $operationClock `
                        -DeadlineMilliseconds `
                            $operationDeadlineMilliseconds
                } else {
                    Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $cleanupClock `
                        -DeadlineMilliseconds `
                            $cleanupDeadlineMilliseconds
                }
                if ($phaseRemaining -gt 0) {
                    Start-Sleep -Milliseconds ([Math]::Min(
                        5,
                        $phaseRemaining
                    ))
                }
            }

            $stdoutBytes = $stdoutBuffer.ToArray()
            $stderrBytes = $stderrBuffer.ToArray()
        }
    }
    finally {
        if ($null -eq $cleanupClock) {
            $cleanupClock = [System.Diagnostics.Stopwatch]::StartNew()
        }
        if ($null -ne $process) {
            if ($processStarted -and -not $process.HasExited) {
                $cleanupRemaining =
                    Get-PrivateMarkerRemainingMilliseconds `
                        -Stopwatch $cleanupClock `
                        -DeadlineMilliseconds $cleanupDeadlineMilliseconds
                $treeStopped = Stop-PrivateMarkerOwnedProcessTreeBounded `
                    -Process $process `
                    -WindowsJobHandle ([ref]$windowsJobHandle) `
                    -PosixProcessGroupId $posixProcessGroupId `
                    -WaitMilliseconds $cleanupRemaining
            } elseif ($windowsJobHandle -ne [IntPtr]::Zero) {
                $jobClosed =
                    [BoundedPlaywrightUiVerification.PrivateMarkerJob]::Close(
                        $windowsJobHandle
                    )
                if ($jobClosed) {
                    $windowsJobHandle = [IntPtr]::Zero
                } else {
                    # direct child終了後でもJobにはpipeを持たない孫が残り得る。
                    # ownershipを保持したまま一度再試行し、異常は結果へ残す。
                    $jobClosed =
                        [BoundedPlaywrightUiVerification.PrivateMarkerJob]::Close(
                            $windowsJobHandle
                        )
                    if ($jobClosed) {
                        $windowsJobHandle = [IntPtr]::Zero
                    }
                    $treeStopped = $false
                }
            } elseif ($posixProcessGroupId -gt 0) {
                # Kill detached descendants even when they did not inherit a
                # redirected pipe and the direct command already exited.
                $treeStopped =
                    (Stop-PrivateMarkerPosixProcessGroupBounded `
                        -ProcessGroupId $posixProcessGroupId) -and
                    $treeStopped
            }
            if ($startInfo.RedirectStandardInput) {
                try { $process.StandardInput.Dispose() } catch { }
            }
            $process.Dispose()
        } elseif ($windowsJobHandle -ne [IntPtr]::Zero) {
            $jobClosed =
                [BoundedPlaywrightUiVerification.PrivateMarkerJob]::Close(
                    $windowsJobHandle
                )
            if (-not $jobClosed) {
                # start後の例外でもhandleを先に捨てず、最後に一度だけ再試行する。
                [void][BoundedPlaywrightUiVerification.PrivateMarkerJob]::Close(
                    $windowsJobHandle
                )
            }
        }
        foreach ($gatePath in @(
            $posixGateReadyPath,
            $posixGateReleasePath
        )) {
            if (-not [string]::IsNullOrWhiteSpace($gatePath)) {
                try { [IO.File]::Delete($gatePath) } catch { }
            }
        }
        $stdoutBuffer.Dispose()
        $stderrBuffer.Dispose()
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false, $false)
    $stdoutText = $utf8.GetString($stdoutBytes)
    $stderrText = $utf8.GetString($stderrBytes)
    $output = @($stdoutText, $stderrText) -join [Environment]::NewLine
    if ($timedOut) {
        $output += [Environment]::NewLine +
            "Process timed out after $TimeoutMilliseconds ms."
    }
    if (-not $treeStopped) {
        $output += [Environment]::NewLine +
            'Process tree did not stop within the bounded cleanup window.'
    }
    if (-not $streamsDrained) {
        $output += [Environment]::NewLine +
            'Process output streams did not close within the bounded drain window.'
    }
    if ($outputLimitExceeded) {
        $output += [Environment]::NewLine +
            'Process output exceeded the configured byte limit.'
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdoutBytes = $stdoutBytes
        StderrBytes = $stderrBytes
        Output = $output.TrimEnd()
        TimedOut = $timedOut
        OutputLimitExceeded = $outputLimitExceeded
        TreeStopped = $treeStopped
        StreamsDrained = $streamsDrained
        ContainmentEstablished = $containmentEstablished
    }
}
