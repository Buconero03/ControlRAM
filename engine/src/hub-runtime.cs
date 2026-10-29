using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace AmeHub {
    public static class Frames {
        public const int Limit = 262144;
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        static bool Exact(Stream s, byte[] b, bool eof) {
            int at = 0;
            while (at < b.Length) {
                int n = s.Read(b, at, b.Length-at);
                if (n == 0) { if (at == 0 && eof) return false; throw new EndOfStreamException("Frame incompleto"); }
                at += n;
            }
            return true;
        }
        public static string Read(Stream s) {
            byte[] h = new byte[4]; if (!Exact(s,h,true)) return null;
            uint length = (uint)(h[0] | h[1]<<8 | h[2]<<16 | h[3]<<24);
            if (length == 0 || length > Limit) throw new InvalidDataException("Dimensione frame non valida");
            byte[] b = new byte[(int)length]; Exact(s,b,false); return Utf8.GetString(b);
        }
        public static void Write(Stream s, string value) {
            byte[] b = Utf8.GetBytes(value);
            if (b.Length == 0 || b.Length > Limit) throw new InvalidDataException("Dimensione frame non valida");
            uint n = (uint)b.Length;
            byte[] h = new byte[] {(byte)n,(byte)(n>>8),(byte)(n>>16),(byte)(n>>24)};
            s.Write(h,0,4); s.Write(b,0,b.Length); s.Flush();
        }
        public static string ReadWithTimeout(Stream s,int milliseconds) {
            Task<string> task=Task.Factory.StartNew(delegate { return Read(s); });
            if(!task.Wait(milliseconds))throw new TimeoutException("Risposta host non ricevuta");
            return task.Result;
        }
    }

    // Read bytes in C#: avoid PowerShell overload conversion of mutable buffers.
    public sealed class ReportTail : IDisposable {
        readonly FileStream stream;
        readonly Decoder decoder = new UTF8Encoding(false,true).GetDecoder();
        readonly StringBuilder partial = new StringBuilder();
        public ReportTail(string path) {
            stream = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);
        }
        public bool HasUnreadBytes { get { return stream.Position < stream.Length; } }
        public string[] ReadLines() {
            byte[] b = new byte[262144]; int n = stream.Read(b,0,b.Length);
            if (n == 0) return new string[0];
            char[] c = new char[n+2]; int count = decoder.GetChars(b,0,n,c,0,false);
            List<string> result = new List<string>();
            for (int i=0;i<count;i++) {
                if (c[i]=='\n') { result.Add(partial.ToString().TrimEnd('\r').TrimStart('\uFEFF')); partial.Clear(); }
                else { partial.Append(c[i]); if(partial.Length > 4194304) throw new InvalidDataException("Riga report oltre 4 MiB"); }
            }
            return result.ToArray();
        }
        public void Dispose() { stream.Dispose(); }
    }

    public sealed class BridgeEvent {
        public int Connection;
        public string Json;
        public string Error;
    }
    public sealed class BrowserBridge : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int Length; public IntPtr Descriptor; public int Inherit; }
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s,uint r,out IntPtr d,out uint size);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafePipeHandle CreateNamedPipe(string name,uint open,uint mode,uint max,uint output,uint input,uint timeout,ref SecurityAttributes attributes);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe,out uint pid);
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder name,ref int size);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        readonly object sync = new object();
        readonly ConcurrentDictionary<int,Client> clients = new ConcurrentDictionary<int,Client>();
        readonly ConcurrentQueue<BridgeEvent> events = new ConcurrentQueue<BridgeEvent>();
        readonly string pipeName, hostPath;
        Thread acceptThread;
        NamedPipeServerStream waiting;
        volatile bool stopping;
        int nextId, queued;
        sealed class Client {
            public readonly NamedPipeServerStream Pipe;
            public readonly BlockingCollection<string> Outbox = new BlockingCollection<string>(16);
            readonly BrowserBridge owner; readonly int id; int closed;
            public Client(BrowserBridge b,int n,NamedPipeServerStream p) { owner=b; id=n; Pipe=p; }
            public void Start() {
                Thread r = new Thread(delegate() {
                    try { string j; while((j=Frames.Read(Pipe))!=null) owner.Enqueue(new BridgeEvent {Connection=id,Json=j}); }
                    catch(Exception e) { Stop(e.Message); } finally { Stop("Collegamento browser chiuso"); }
                }); r.IsBackground=true; r.Start();
                Thread w = new Thread(delegate() {
                    try { foreach(string j in Outbox.GetConsumingEnumerable()) Frames.Write(Pipe,j); }
                    catch(Exception e) { Stop(e.Message); }
                }); w.IsBackground=true; w.Start();
            }
            public void Stop(string reason) {
                if(Interlocked.Exchange(ref closed,1)!=0)return;
                Outbox.CompleteAdding(); Pipe.Dispose();
                Client unused; owner.clients.TryRemove(id,out unused);
                owner.Enqueue(new BridgeEvent {Connection=id,Error=reason});
            }
        }
        public BrowserBridge(string expectedHostPath) {
            hostPath=Path.GetFullPath(expectedHostPath);
            pipeName="AME.v03."+WindowsIdentity.GetCurrent().User.Value+"."+Process.GetCurrentProcess().SessionId;
            // Create the first listener synchronously so duplicate hubs fail visibly.
            waiting=CreatePipe(true);
            acceptThread=new Thread(Accept); acceptThread.IsBackground=true; acceptThread.Start();
        }
        NamedPipeServerStream CreatePipe(bool first) {
            IntPtr sd; uint length;
            if(!ConvertStringSecurityDescriptorToSecurityDescriptor("D:P(A;;GA;;;"+WindowsIdentity.GetCurrent().User.Value+")",1,out sd,out length)) throw new System.ComponentModel.Win32Exception();
            try {
                SecurityAttributes a = new SecurityAttributes {Length=Marshal.SizeOf(typeof(SecurityAttributes)),Descriptor=sd,Inherit=0};
                SafePipeHandle h=CreateNamedPipe("\\\\.\\pipe\\"+pipeName,0x40000003u|(first?0x00080000u:0u),8u,8u,Frames.Limit,Frames.Limit,0,ref a);
                if(h.IsInvalid) { h.Dispose(); throw new System.ComponentModel.Win32Exception(); }
                try { return new NamedPipeServerStream(PipeDirection.InOut,true,false,h); }
                catch { h.Dispose(); throw; }
            } finally { LocalFree(sd); }
        }
        void CheckPeer(NamedPipeServerStream p) {
            uint pid; if(!GetNamedPipeClientProcessId(p.SafePipeHandle,out pid)) throw new IOException("Identita host non disponibile");
            IntPtr h=OpenProcess(0x1000,false,pid);
            if(h==IntPtr.Zero)throw new IOException("Host non verificabile");
            try {
                StringBuilder s=new StringBuilder(32768); int size=s.Capacity;
                if(!QueryFullProcessImageName(h,0,s,ref size)||!String.Equals(s.ToString(),hostPath,StringComparison.OrdinalIgnoreCase)) throw new IOException("Host diverso da questa installazione: aggiorna il collegamento del browser");
            } finally { CloseHandle(h); }
        }
        void Accept() {
            while(!stopping) {
                NamedPipeServerStream p=null;
                try {
                    lock(sync) { if(stopping)return; if(waiting==null)waiting=CreatePipe(false); p=waiting; }
                    p.WaitForConnection();
                    lock(sync) { waiting=null; }
                    CheckPeer(p);
                    int id=Interlocked.Increment(ref nextId); Client c=new Client(this,id,p); clients[id]=c; c.Start(); p=null;
                } catch(Exception e) {
                    if(p!=null)p.Dispose(); lock(sync) { if(waiting==p)waiting=null; }
                    if(!stopping) { Enqueue(new BridgeEvent {Error=e.Message}); Thread.Sleep(250); }
                }
            }
        }
        void Enqueue(BridgeEvent e) {
            if(Interlocked.Increment(ref queued)>128) { Interlocked.Decrement(ref queued); Client c; if(clients.TryGetValue(e.Connection,out c))c.Stop("Coda eventi oltre il limite"); return; }
            events.Enqueue(e);
        }
        public BridgeEvent[] Drain() {
            List<BridgeEvent> list=new List<BridgeEvent>(); BridgeEvent e;
            while(events.TryDequeue(out e)) { Interlocked.Decrement(ref queued); list.Add(e); }
            return list.ToArray();
        }
        public bool Send(int connection,string json) {
            Client c; if(!clients.TryGetValue(connection,out c))return false;
            try { return c.Outbox.TryAdd(json); } catch(InvalidOperationException) { return false; }
        }
        public void Disconnect(int id) { Client c; if(clients.TryGetValue(id,out c))c.Stop("Collegamento interrotto dall'hub"); }
        public void Dispose() {
            stopping=true; lock(sync) { if(waiting!=null)waiting.Dispose(); }
            foreach(Client c in clients.Values)c.Stop("Hub chiuso");
            acceptThread.Join(500);
        }
    }

    public sealed class MemoryReading {
        public long AvailableBytes, PrivateCommitBytes, WorkingSetBytes;
        public long? PrivateWorkingSetBytes;
        public int Processes, Unreadable;
    }
    public static class Metrics {
        [StructLayout(LayoutKind.Sequential)] struct Counters {
            public uint Cb,Faults;
            public UIntPtr PeakWs,Ws,PeakPaged,Paged,PeakNonPaged,NonPaged,Pagefile,PeakPagefile,PrivateUsage,PrivateWs,SharedCommit;
        }
        [StructLayout(LayoutKind.Sequential)] struct Status {
            public uint Length,Load; public ulong Total,Available,TotalPagefile,AvailablePagefile,TotalVirtual,AvailableVirtual,Extended;
        }
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GlobalMemoryStatusEx(ref Status s);
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("psapi.dll",SetLastError=true)] static extern bool GetProcessMemoryInfo(IntPtr h,ref Counters c,uint size);
        public static MemoryReading Chrome() { return Browser("chrome"); }
        public static MemoryReading Browser(string processName) {
            if(processName!="chrome" && processName!="firefox")throw new ArgumentException("Browser non supportato");
            MemoryReading r=new MemoryReading(); Status s=new Status(); s.Length=(uint)Marshal.SizeOf(typeof(Status));
            if(!GlobalMemoryStatusEx(ref s))throw new System.ComponentModel.Win32Exception();
            r.AvailableBytes=(long)s.Available; bool complete=true; long privateWs=0; int session=Process.GetCurrentProcess().SessionId;
            foreach(Process p in Process.GetProcessesByName(processName)) {
                using(p) { IntPtr h=IntPtr.Zero;
                    try {
                        if(p.SessionId!=session)continue; r.Processes++;
                        h=OpenProcess(0x410,false,(uint)p.Id); if(h==IntPtr.Zero)throw new IOException();
                        Counters c=new Counters(); c.Cb=(uint)Marshal.SizeOf(typeof(Counters));
                        bool ex2=GetProcessMemoryInfo(h,ref c,c.Cb);
                        if(!ex2) { c=new Counters(); c.Cb=80; if(!GetProcessMemoryInfo(h,ref c,c.Cb))throw new IOException(); complete=false; }
                        r.PrivateCommitBytes+=checked((long)c.PrivateUsage.ToUInt64()); r.WorkingSetBytes+=checked((long)c.Ws.ToUInt64());
                        if(ex2 && c.PrivateWs.ToUInt64()<=c.Ws.ToUInt64())privateWs+=checked((long)c.PrivateWs.ToUInt64());
                        else complete=false;
                    } catch { r.Unreadable++; complete=false; } finally { if(h!=IntPtr.Zero)CloseHandle(h); }
                }
            }
            r.PrivateWorkingSetBytes=complete?(long?)privateWs:null; return r;
        }
    }
}
