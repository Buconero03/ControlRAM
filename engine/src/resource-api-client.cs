using System;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.IO;
using System.IO.Pipes;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace AmeHub {
    public sealed class ResourceIdentity {
        public uint Pid;
        public ulong Creation;
        public string Path;
    }
    public sealed class ResourceReclaimOutcome {
        public uint Pid;
        public uint AppliedStages;
        public ulong MonotonicMs;
        public ulong WorkingSetBeforeBytes;
        public ulong WorkingSetAfterBytes;
        public ulong PrivateCommitBeforeBytes;
        public ulong PrivateCommitAfterBytes;
        public long WorkingSetDeltaBytes;
        public ulong CooperativeReleasedBytes;
    }
    public sealed class GroupBudgetOutcome {
        public ulong GroupId;
        public ulong TotalReclaimedBytes;
        public uint AffectedProcesses;
    }
    public sealed class ResourceApiClient : IDisposable {
        internal const int IdentitySize = 65552;
        internal const int ReclaimResultSize = 64;
        public const uint StageCooperativeCache = 1u;
        public const uint StageMemoryPriority = 2u;
        public const uint StageEcoQos = 4u;
        public const uint StageWorkingSetTrim = 8u;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate uint Getter();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int ReadIdentity(uint pid, IntPtr identity);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int CompactProcess(ulong requestedBytes, out ulong releasedBytes);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int ExecuteReclaim(IntPtr identity, uint stageFlags, IntPtr output);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int CreateGroupDelegate(out ulong group);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int AttachProcessDelegate(ulong group, IntPtr identity);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int ReclaimGroupDelegate(ulong group, ulong targetBytes, uint stageFlags, out ulong totalReclaimed, out uint affected);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int CloseGroupDelegate(ulong group);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int RestoreProcessDelegate(IntPtr identity);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int RestoreAllDelegate(out uint restoredCount);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int GetCompBytesDelegate(out ulong compBytes);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int PulseFlushDelegate(ulong targetPulseBytes, out ulong freedBytes);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int SetGroupCpuRateDelegate(ulong group, uint maxPercent);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int ClampProcessDelegate(IntPtr identity, ulong maxBytes, IntPtr output);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int UnclampProcessDelegate(IntPtr identity);

        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern IntPtr LoadLibraryExW(string path, IntPtr reserved, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Ansi, ExactSpelling=true, SetLastError=true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool FreeLibrary(IntPtr module);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetPriorityClass(IntPtr hProcess, uint priorityClass);
        [StructLayout(LayoutKind.Sequential)]
        private struct MEMORY_PRIORITY_INFORMATION { public uint MemoryPriority; }
        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_POWER_THROTTLING_STATE { public uint Version; public uint ControlMask; public uint StateMask; }
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetProcessInformation(IntPtr hProcess, int infoClass, ref MEMORY_PRIORITY_INFORMATION info, int size);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetProcessInformation(IntPtr hProcess, int infoClass, ref PROCESS_POWER_THROTTLING_STATE info, int size);

        private IntPtr module;
        private Getter version, error;
        private ReadIdentity read;
        private CompactProcess compact;
        private ExecuteReclaim executeReclaim;
        private CreateGroupDelegate createGroup;
        private AttachProcessDelegate attachProcess;
        private ReclaimGroupDelegate reclaimGroup;
        private CloseGroupDelegate closeGroup;
        private RestoreProcessDelegate restoreProcess;
        private RestoreAllDelegate restoreAll;
        private GetCompBytesDelegate getCompBytes;
        private PulseFlushDelegate pulseFlush;
        private SetGroupCpuRateDelegate setGroupCpuRate;
        private ClampProcessDelegate clampProcess;
        private UnclampProcessDelegate unclampProcess;
        private bool disposed;
        private readonly object sync = new object();
        public uint ApiVersion { get; private set; }
        public int SuccessfulReads { get; private set; }
        public int SuccessfulReclaims { get; private set; }
        public string LibraryPath { get; private set; }

        public ResourceApiClient(string path) {
            if (IntPtr.Size != 8) throw new NotSupportedException("API AME: serve un processo x64.");
            if (!System.IO.Path.IsPathRooted(path)) throw new ArgumentException("Percorso DLL assoluto richiesto.");
            LibraryPath = System.IO.Path.GetFullPath(path);
            // Search dependencies only beside this DLL and in default safe directories.
            module = LoadLibraryExW(LibraryPath, IntPtr.Zero, 0x100u | 0x1000u);
            if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Caricamento API AME fallito.");
            try {
                version = (Getter)Resolve("AmeGetApiVersion", typeof(Getter));
                error = (Getter)Resolve("AmeGetLastWindowsError", typeof(Getter));
                read = (ReadIdentity)Resolve("AmeReadProcessIdentity", typeof(ReadIdentity));
                compact = (CompactProcess)TryResolve("AmeCompactCurrentProcess", typeof(CompactProcess));
                executeReclaim = (ExecuteReclaim)TryResolve("AmeExecuteProcessReclaim", typeof(ExecuteReclaim));
                createGroup = (CreateGroupDelegate)TryResolve("AmeCreateGroup", typeof(CreateGroupDelegate));
                attachProcess = (AttachProcessDelegate)TryResolve("AmeAttachProcess", typeof(AttachProcessDelegate));
                reclaimGroup = (ReclaimGroupDelegate)TryResolve("AmeReclaimGroupBudget", typeof(ReclaimGroupDelegate));
                closeGroup = (CloseGroupDelegate)TryResolve("AmeCloseGroup", typeof(CloseGroupDelegate));
                restoreProcess = (RestoreProcessDelegate)TryResolve("AmeRestoreProcess", typeof(RestoreProcessDelegate));
                restoreAll = (RestoreAllDelegate)TryResolve("AmeRestoreAllProcesses", typeof(RestoreAllDelegate));
                getCompBytes = (GetCompBytesDelegate)TryResolve("AmeGetMemoryCompressionBytes", typeof(GetCompBytesDelegate));
                pulseFlush = (PulseFlushDelegate)TryResolve("AmePulseFlushMemory", typeof(PulseFlushDelegate));
                setGroupCpuRate = (SetGroupCpuRateDelegate)TryResolve("AmeSetGroupCpuRate", typeof(SetGroupCpuRateDelegate));
                clampProcess = (ClampProcessDelegate)TryResolve("AmeClampProcessWorkingSet", typeof(ClampProcessDelegate));
                unclampProcess = (UnclampProcessDelegate)TryResolve("AmeUnclampProcessWorkingSet", typeof(UnclampProcessDelegate));
                CheckVersion();
            } catch { Dispose(); throw; }
        }
        // Injection is internal and used only by the managed contract tests.
        internal ResourceApiClient(Getter v, Getter e, ReadIdentity r) {
            version=v; error=e; read=r; CheckVersion();
        }
        private Delegate Resolve(string name, Type type) {
            IntPtr address=GetProcAddress(module, name);
            if(address==IntPtr.Zero) throw new EntryPointNotFoundException(name);
            return Marshal.GetDelegateForFunctionPointer(address,type);
        }
        private Delegate TryResolve(string name, Type type) {
            IntPtr address=GetProcAddress(module, name);
            if(address==IntPtr.Zero) return null;
            return Marshal.GetDelegateForFunctionPointer(address,type);
        }
        private void CheckVersion() {
            ApiVersion=version();
            if(ApiVersion!=1) throw new NotSupportedException("Versione API AME incompatibile: "+ApiVersion);
        }
        private static void WriteIdentityBuffer(IntPtr buffer, uint pid, ulong creation, string path) {
            Marshal.Copy(new byte[IdentitySize], 0, buffer, IdentitySize);
            Marshal.WriteInt32(buffer, 0, IdentitySize);
            Marshal.WriteInt32(buffer, 4, unchecked((int)pid));
            Marshal.WriteInt64(buffer, 8, unchecked((long)creation));
            byte[] pathBytes = Encoding.Unicode.GetBytes(path + "\0");
            if (pathBytes.Length > (IdentitySize - 16)) throw new ArgumentException("Percorso troppo lungo.");
            Marshal.Copy(pathBytes, 0, IntPtr.Add(buffer, 16), pathBytes.Length);
        }
        public ResourceIdentity Read(uint pid) {
            lock(sync) {
                if(disposed) throw new ObjectDisposedException("ResourceApiClient");
                if(pid==0) throw new ArgumentException("PID non valido.");
                IntPtr buffer=Marshal.AllocHGlobal(IdentitySize);
                try {
                    Marshal.Copy(new byte[IdentitySize],0,buffer,IdentitySize);
                    Marshal.WriteInt32(buffer,IdentitySize);
                    int status=read(pid,buffer);
                    uint winError=error(); // Same thread, immediately after the API operation.
                    if(status!=0) throw new InvalidOperationException("Identita PID "+pid+" non verificabile: API "+status+", Windows "+winError+".");
                    uint actualPid=unchecked((uint)Marshal.ReadInt32(buffer,4));
                    ulong creation=unchecked((ulong)Marshal.ReadInt64(buffer,8));
                    string bounded=Marshal.PtrToStringUni(IntPtr.Add(buffer,16),32768);
                    int end=bounded.IndexOf('\0');
                    if(Marshal.ReadInt32(buffer)!=IdentitySize || actualPid!=pid || creation==0 || end<=0)
                        throw new InvalidDataException("Risposta identita API non valida.");
                    SuccessfulReads++;
                    return new ResourceIdentity { Pid=actualPid, Creation=creation, Path=bounded.Substring(0,end) };
                } finally { Marshal.FreeHGlobal(buffer); }
            }
        }
        public void Validate(string key, string expectedPath) {
            uint pid; ulong creation;
            string[] parts=(key??"").Split(':');
            if(parts.Length!=2 || !uint.TryParse(parts[0],out pid) || !ulong.TryParse(parts[1],out creation) ||
               pid==0 || creation==0 || String.IsNullOrWhiteSpace(expectedPath))
                throw new ArgumentException("Identita selezionata incompleta.");
            ResourceIdentity actual=Read(pid);
            if(actual.Creation!=creation || !String.Equals(actual.Path,expectedPath,StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Processo cambiato (PID "+pid+"): aggiorna la selezione. Nessun intervento avviato.");
        }
        public ulong CompactCurrentProcess(ulong requestedBytes) {
            lock(sync) {
                if(disposed) throw new ObjectDisposedException("ResourceApiClient");
                long managedBefore = GC.GetTotalMemory(false);
                try {
                    GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
                    GC.Collect(2, GCCollectionMode.Forced, true, true);
                    GC.WaitForPendingFinalizers();
                } catch {}
                long managedAfter = GC.GetTotalMemory(false);
                ulong managedDrop = managedBefore > managedAfter ? (ulong)(managedBefore - managedAfter) : 0UL;
                if(compact == null) return managedDrop;
                ulong nativeReleased = 0;
                int status = compact(requestedBytes, out nativeReleased);
                if(status != 0) throw new InvalidOperationException("Compattazione interna fallita: API " + status + ", Windows " + error());
                return managedDrop + nativeReleased;
            }
        }
        public ResourceReclaimOutcome ExecuteProcessReclaim(string key, string expectedPath, uint stageFlags) {
            lock(sync) {
                if(disposed) throw new ObjectDisposedException("ResourceApiClient");
                if(executeReclaim == null) throw new NotSupportedException("AmeExecuteProcessReclaim non supportata dalla DLL caricata.");
                uint pid; ulong creation;
                string[] parts=(key??"").Split(':');
                if(parts.Length!=2 || !uint.TryParse(parts[0],out pid) || !ulong.TryParse(parts[1],out creation) ||
                   pid==0 || creation==0 || String.IsNullOrWhiteSpace(expectedPath))
                    throw new ArgumentException("Identita selezionata incompleta.");
                IntPtr idBuffer = Marshal.AllocHGlobal(IdentitySize);
                IntPtr outBuffer = Marshal.AllocHGlobal(ReclaimResultSize);
                try {
                    WriteIdentityBuffer(idBuffer, pid, creation, expectedPath);
                    Marshal.Copy(new byte[ReclaimResultSize], 0, outBuffer, ReclaimResultSize);
                    Marshal.WriteInt32(outBuffer, 0, ReclaimResultSize);
                    int status = executeReclaim(idBuffer, stageFlags, outBuffer);
                    uint winError = error();
                    if(status != 0) throw new InvalidOperationException("Intervento API su PID "+pid+" rifiutato: API "+status+", Windows "+winError+".");
                    SuccessfulReclaims++;
                    return new ResourceReclaimOutcome {
                        Pid = pid,
                        AppliedStages = unchecked((uint)Marshal.ReadInt32(outBuffer, 4)),
                        MonotonicMs = unchecked((ulong)Marshal.ReadInt64(outBuffer, 8)),
                        WorkingSetBeforeBytes = unchecked((ulong)Marshal.ReadInt64(outBuffer, 16)),
                        WorkingSetAfterBytes = unchecked((ulong)Marshal.ReadInt64(outBuffer, 24)),
                        PrivateCommitBeforeBytes = unchecked((ulong)Marshal.ReadInt64(outBuffer, 32)),
                        PrivateCommitAfterBytes = unchecked((ulong)Marshal.ReadInt64(outBuffer, 40)),
                        WorkingSetDeltaBytes = Marshal.ReadInt64(outBuffer, 48),
                        CooperativeReleasedBytes = unchecked((ulong)Marshal.ReadInt64(outBuffer, 56))
                    };
                } finally {
                    Marshal.FreeHGlobal(idBuffer);
                    Marshal.FreeHGlobal(outBuffer);
                }
            }
        }
        public GroupBudgetOutcome ExecuteDistributedGroupReclaim(string[] keys, string[] paths, ulong targetBytes, uint stageFlags) {
            lock(sync) {
                if(disposed) throw new ObjectDisposedException("ResourceApiClient");
                if(createGroup == null || attachProcess == null || reclaimGroup == null || closeGroup == null)
                    throw new NotSupportedException("API di gruppo AME non disponibile.");
                if(keys == null || paths == null || keys.Length != paths.Length || keys.Length == 0)
                    throw new ArgumentException("Elenco processi per il gruppo non valido.");
                ulong group = 0;
                int status = createGroup(out group);
                if(status != 0 || group == 0) throw new InvalidOperationException("Creazione gruppo AME fallita: API "+status);
                IntPtr idBuffer = Marshal.AllocHGlobal(IdentitySize);
                IntPtr resBuffer = Marshal.AllocHGlobal(ReclaimResultSize);
                try {
                    int attached = 0;
                    var fallbackIndices = new System.Collections.Generic.List<int>();
                    for(int i=0; i<keys.Length; i++) {
                        uint pid; ulong creation;
                        string[] parts = (keys[i] ?? "").Split(':');
                        if(parts.Length != 2 || !uint.TryParse(parts[0], out pid) || !ulong.TryParse(parts[1], out creation) || String.IsNullOrWhiteSpace(paths[i]))
                            continue;
                        WriteIdentityBuffer(idBuffer, pid, creation, paths[i]);
                        if(attachProcess(group, idBuffer) == 0) attached++;
                        else fallbackIndices.Add(i);
                    }
                    ulong reclaimed = 0; uint affected = 0;
                    if(attached > 0) {
                        if(setGroupCpuRate != null) {
                            try { setGroupCpuRate(group, 10u); } catch {}
                        }
                        status = reclaimGroup(group, targetBytes, stageFlags, out reclaimed, out affected);
                        if(status != 0) throw new InvalidOperationException("Rilascio budget gruppo fallito: API "+status);
                        SuccessfulReclaims += (int)affected;
                    }
                    foreach(int idx in fallbackIndices) {
                        if(targetBytes > 0 && reclaimed >= targetBytes) break;
                        uint pid; ulong creation;
                        string[] parts = (keys[idx] ?? "").Split(':');
                        if(parts.Length != 2 || !uint.TryParse(parts[0], out pid) || !ulong.TryParse(parts[1], out creation)) continue;
                        WriteIdentityBuffer(idBuffer, pid, creation, paths[idx]);
                        for(int b=0; b<ReclaimResultSize; b++) Marshal.WriteByte(resBuffer, b, 0);
                        Marshal.WriteInt32(resBuffer, 0, ReclaimResultSize);
                        if(executeReclaim(idBuffer, stageFlags, resBuffer) == 0) {
                            if(affected > 0) {
                                System.Threading.Thread.Sleep(60);
                            }
                            ulong wsBefore = unchecked((ulong)Marshal.ReadInt64(resBuffer, 16));
                            ulong wsAfter = unchecked((ulong)Marshal.ReadInt64(resBuffer, 24));
                            if(wsBefore > wsAfter) reclaimed += (wsBefore - wsAfter);
                            affected++;
                            SuccessfulReclaims++;
                        }
                    }
                    return new GroupBudgetOutcome { GroupId = group, TotalReclaimedBytes = reclaimed, AffectedProcesses = affected };
                } finally {
                    Marshal.FreeHGlobal(resBuffer);
                    Marshal.FreeHGlobal(idBuffer);
                    closeGroup(group);
                }
            }
        }
        public bool RestoreProcess(string key, string expectedPath) {
            lock(sync) {
                if(disposed || restoreProcess == null) return false;
                uint pid; ulong creation;
                string[] parts = (key ?? "").Split(':');
                if(parts.Length != 2 || !uint.TryParse(parts[0], out pid) || !ulong.TryParse(parts[1], out creation) ||
                   pid == 0 || creation == 0 || String.IsNullOrWhiteSpace(expectedPath))
                    return false;
                IntPtr idBuffer = Marshal.AllocHGlobal(IdentitySize);
                try {
                    WriteIdentityBuffer(idBuffer, pid, creation, expectedPath);
                    return restoreProcess(idBuffer) == 0;
                } finally {
                    Marshal.FreeHGlobal(idBuffer);
                }
            }
        }
        public uint RestoreAllProcesses() {
            lock(sync) {
                if(disposed || restoreAll == null) return 0u;
                uint count = 0u;
                try { restoreAll(out count); } catch {}
                return count;
            }
        }
        public ulong GetMemoryCompressionWorkingSetBytes() {
            lock(sync) {
                if(disposed || getCompBytes == null) return 0u;
                ulong b = 0u;
                try { getCompBytes(out b); } catch {}
                return b;
            }
        }
        public ulong PulseFlushMemory(ulong targetBytes = 0u) {
            lock(sync) {
                if(disposed || pulseFlush == null) return 0u;
                ulong freed = 0u;
                try { pulseFlush(targetBytes, out freed); } catch {}
                return freed;
            }
        }
        public ResourceReclaimOutcome ClampProcessWorkingSet(string key, string path, ulong maxBytes) {
            lock(sync) {
                if (disposed || clampProcess == null) throw new NotSupportedException("Clamping non supportato dall'API nativa.");
                uint pid; ulong creation;
                string[] parts = (key ?? "").Split(':');
                if (parts.Length != 2 || !uint.TryParse(parts[0], out pid) || !ulong.TryParse(parts[1], out creation) || String.IsNullOrWhiteSpace(path))
                    throw new ArgumentException("Identità non valida per clamping.");
                IntPtr idBuffer = Marshal.AllocHGlobal(IdentitySize);
                IntPtr resBuffer = Marshal.AllocHGlobal(ReclaimResultSize);
                try {
                    WriteIdentityBuffer(idBuffer, pid, creation, path);
                    for (int b = 0; b < ReclaimResultSize; b++) Marshal.WriteByte(resBuffer, b, 0);
                    Marshal.WriteInt32(resBuffer, 0, ReclaimResultSize);
                    int status = clampProcess(idBuffer, maxBytes, resBuffer);
                    if (status != 0) throw new InvalidOperationException("Clamping fallito con codice API " + status);
                    return new ResourceReclaimOutcome {
                        Pid = pid,
                        AppliedStages = unchecked((uint)Marshal.ReadInt32(resBuffer, 4)),
                        WorkingSetBeforeBytes = unchecked((ulong)Marshal.ReadInt64(resBuffer, 16)),
                        WorkingSetAfterBytes = unchecked((ulong)Marshal.ReadInt64(resBuffer, 24)),
                        PrivateCommitBeforeBytes = unchecked((ulong)Marshal.ReadInt64(resBuffer, 32)),
                        PrivateCommitAfterBytes = unchecked((ulong)Marshal.ReadInt64(resBuffer, 40)),
                        WorkingSetDeltaBytes = Marshal.ReadInt64(resBuffer, 48),
                        CooperativeReleasedBytes = unchecked((ulong)Marshal.ReadInt64(resBuffer, 56))
                    };
                } finally {
                    Marshal.FreeHGlobal(resBuffer);
                    Marshal.FreeHGlobal(idBuffer);
                }
            }
        }
        public bool UnclampProcessWorkingSet(string key, string path) {
            lock(sync) {
                if (disposed || unclampProcess == null) return false;
                uint pid; ulong creation;
                string[] parts = (key ?? "").Split(':');
                if (parts.Length != 2 || !uint.TryParse(parts[0], out pid) || !ulong.TryParse(parts[1], out creation) || String.IsNullOrWhiteSpace(path))
                    return false;
                IntPtr idBuffer = Marshal.AllocHGlobal(IdentitySize);
                try {
                    WriteIdentityBuffer(idBuffer, pid, creation, path);
                    return unclampProcess(idBuffer) == 0;
                } finally {
                    Marshal.FreeHGlobal(idBuffer);
                }
            }
        }
        public static int RestoreAllUserSessionProcesses() {
            int restored = 0;
            try {
                int currentSession = System.Diagnostics.Process.GetCurrentProcess().SessionId;
                foreach(var p in System.Diagnostics.Process.GetProcesses()) {
                    try {
                        if(p.Id <= 4 || p.SessionId != currentSession) continue;
                        IntPtr h = OpenProcess(0x0200u | 0x1000u, false, (uint)p.Id);
                        if(h == IntPtr.Zero) continue;
                        try {
                            var mem = new MEMORY_PRIORITY_INFORMATION { MemoryPriority = 5u };
                            bool b1 = SetProcessInformation(h, 0, ref mem, Marshal.SizeOf(mem));
                            var qos = new PROCESS_POWER_THROTTLING_STATE { Version = 1u, ControlMask = 0u, StateMask = 0u };
                            bool b2 = SetProcessInformation(h, 4, ref qos, Marshal.SizeOf(qos));
                            bool b3 = SetPriorityClass(h, 0x00000020u); // NORMAL_PRIORITY_CLASS
                            if(b1 || b2 || b3) restored++;
                        } finally {
                            CloseHandle(h);
                        }
                    } catch {}
                    finally { p.Dispose(); }
                }
            } catch {}
            return restored;
        }
        public void Dispose() {
            lock(sync) {
                if(disposed) return;
                if(restoreAll != null) {
                    uint ignored = 0u;
                    try { restoreAll(out ignored); } catch {}
                }
                disposed=true;
                if(module!=IntPtr.Zero) { FreeLibrary(module); module=IntPtr.Zero; }
                version=null; error=null; read=null; compact=null; executeReclaim=null;
                createGroup=null; attachProcess=null; reclaimGroup=null; closeGroup=null;
                restoreProcess=null; restoreAll=null;
                getCompBytes=null; pulseFlush=null;
            }
        }
    }

    public sealed class InternalApiRequest {
        public string Id;
        public string Payload;
    }

    public sealed class InternalApiBusServer : IDisposable {
        public const string DefaultPipeName = "AME-Internal-Api-v1";
        private readonly string pipeName;
        private readonly ConcurrentQueue<InternalApiRequest> requests = new ConcurrentQueue<InternalApiRequest>();
        private readonly ConcurrentDictionary<string, string> replies = new ConcurrentDictionary<string, string>();
        private readonly ConcurrentDictionary<string, ManualResetEventSlim> waiters = new ConcurrentDictionary<string, ManualResetEventSlim>();
        private volatile bool running = true;
        private Thread listenerThread;

        public InternalApiBusServer() : this(DefaultPipeName) {}

        public InternalApiBusServer(string name) {
            pipeName = String.IsNullOrWhiteSpace(name) ? DefaultPipeName : name;
            listenerThread = new Thread(ListenLoop) { IsBackground = true, Name = "AME-Internal-Api-Listener" };
            listenerThread.Start();
        }
        private PipeSecurity CreatePipeSecurity() {
            PipeSecurity security = new PipeSecurity();
            SecurityIdentifier currentSid = WindowsIdentity.GetCurrent().User;
            if (currentSid != null) {
                security.AddAccessRule(new PipeAccessRule(currentSid, PipeAccessRights.FullControl, AccessControlType.Allow));
            }
            return security;
        }
        private void ListenLoop() {
            while (running) {
                NamedPipeServerStream server = null;
                try {
                    server = new NamedPipeServerStream(
                        pipeName,
                        PipeDirection.InOut,
                        4,
                        PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous,
                        16384,
                        16384,
                        CreatePipeSecurity());
                    IAsyncResult ar = server.BeginWaitForConnection(null, null);
                    while (running && !ar.AsyncWaitHandle.WaitOne(200)) {}
                    if (!running) { server.Dispose(); break; }
                    server.EndWaitForConnection(ar);
                    using (var reader = new StreamReader(server, new UTF8Encoding(false), false, 4096, true))
                    using (var writer = new StreamWriter(server, new UTF8Encoding(false), 4096, true) { AutoFlush = true }) {
                        string line = reader.ReadLine();
                        if (!String.IsNullOrWhiteSpace(line) && line.Length <= 16384) {
                            string id = Guid.NewGuid().ToString("N");
                            var evt = new ManualResetEventSlim(false);
                            waiters[id] = evt;
                            requests.Enqueue(new InternalApiRequest { Id = id, Payload = line });
                            string response = "{\"ok\":false,\"error\":\"timeout\"}";
                            if (evt.Wait(4000)) {
                                string reply;
                                if (replies.TryRemove(id, out reply)) response = reply;
                            }
                            waiters.TryRemove(id, out evt);
                            evt.Dispose();
                            writer.WriteLine(response);
                        }
                    }
                } catch {
                    Thread.Sleep(50);
                } finally {
                    if (server != null) { try { server.Dispose(); } catch {} }
                }
            }
        }
        public InternalApiRequest[] DrainRequests() {
            var list = new System.Collections.Generic.List<InternalApiRequest>();
            InternalApiRequest item;
            while (list.Count < 16 && requests.TryDequeue(out item)) list.Add(item);
            return list.ToArray();
        }
        public void CompleteRequest(string id, string jsonResponse) {
            if (String.IsNullOrWhiteSpace(id)) return;
            replies[id] = String.IsNullOrWhiteSpace(jsonResponse) ? "{\"ok\":true}" : jsonResponse;
            ManualResetEventSlim evt;
            if (waiters.TryGetValue(id, out evt)) {
                try { evt.Set(); } catch {}
            }
        }
        public void Dispose() {
            running = false;
        }
    }

    public static class InternalApiBusClient {
        public static string SendRequest(string jsonPayload, int timeoutMs = 3000, string pipeName = InternalApiBusServer.DefaultPipeName) {
            if (String.IsNullOrWhiteSpace(jsonPayload)) throw new ArgumentException("Richiesta JSON vuota.");
            using (var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.None)) {
                client.Connect(timeoutMs);
                using (var writer = new StreamWriter(client, new UTF8Encoding(false), 4096, true) { AutoFlush = true })
                using (var reader = new StreamReader(client, new UTF8Encoding(false), false, 4096, true)) {
                    writer.WriteLine(jsonPayload);
                    return reader.ReadLine();
                }
            }
        }
        public static System.Threading.Tasks.Task<string> SendRequestAsync(string jsonPayload, int timeoutMs = 3000, string pipeName = InternalApiBusServer.DefaultPipeName) {
            return System.Threading.Tasks.Task.Run(() => SendRequest(jsonPayload, timeoutMs, pipeName));
        }
    }
}
