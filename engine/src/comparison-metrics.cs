using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace AmeComparison {
    public sealed class Reading {
        public long? AppPrivateBytes, OwnPrivateBytes;
        public long AppCommitBytes, AvailableBytes, TotalBytes;
        public int AppProcesses;
        public bool Complete, CounterCoverageComplete;
        public string IdentityKey;
        public double? CpuPercent, PageFaultsPerSecond, IoReadBytesPerSecond;
    }
    public sealed class Sampler {
        [StructLayout(LayoutKind.Sequential)] struct Memory {
            public uint Cb, Faults;
            public UIntPtr PeakWs, Ws, PeakPaged, Paged, PeakNonPaged, NonPaged, Pagefile, PeakPagefile, PrivateUsage, PrivateWs, SharedCommit;
        }
        [StructLayout(LayoutKind.Sequential)] struct Status {
            public uint Length, Load;
            public ulong Total, Available, TotalPagefile, AvailablePagefile, TotalVirtual, AvailableVirtual, Extended;
        }
        [StructLayout(LayoutKind.Sequential)] struct Io { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
        sealed class Counter { public long Cpu; public uint Faults; public ulong Reads; }
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GlobalMemoryStatusEx(ref Status s);
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr h, out long created, out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr h, uint flags, StringBuilder path, ref int size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessIoCounters(IntPtr h, out Io io);
        [DllImport("psapi.dll", SetLastError=true)] static extern bool GetProcessMemoryInfo(IntPtr h, ref Memory m, uint size);
        readonly string browser, enginePath, hostPath;
        readonly int ownPid, session;
        Dictionary<string,Counter> previous;
        long previousAt;
        public Sampler(string processName, string projectRoot) {
            if(processName!="chrome" && processName!="firefox")throw new ArgumentException("Browser non supportato");
            browser=processName; enginePath=Path.GetFullPath(Path.Combine(projectRoot,"build","ame.exe"));
            hostPath=Path.GetFullPath(Path.Combine(projectRoot,"build","ame-browser-host.exe"));
            using(Process p=Process.GetCurrentProcess()){ownPid=p.Id;session=p.SessionId;}
        }
        public Reading Read() {
            Reading r=new Reading(); Status status=new Status(); status.Length=(uint)Marshal.SizeOf(typeof(Status));
            if(!GlobalMemoryStatusEx(ref status))throw new System.ComponentModel.Win32Exception();
            r.AvailableBytes=checked((long)status.Available);r.TotalBytes=checked((long)status.Total);
            long appPrivate=0, ownPrivate=0; bool appComplete=true, ownComplete=true, countersComplete=true, ownFound=false;
            Dictionary<string,Counter> current=new Dictionary<string,Counter>(); List<string> identities=new List<string>();
            List<Process> candidates=new List<Process>();
            candidates.AddRange(Process.GetProcessesByName(browser));
            candidates.AddRange(Process.GetProcessesByName("ame"));candidates.AddRange(Process.GetProcessesByName("ame-browser-host"));
            candidates.Add(Process.GetProcessById(ownPid));
            foreach(Process p in candidates) {
                using(p) {
                    bool app=false; IntPtr h=IntPtr.Zero;
                    try {
                        if(p.SessionId!=session)continue;
                        app=string.Equals(p.ProcessName,browser,StringComparison.OrdinalIgnoreCase);
                        if(app)r.AppProcesses++;
                        h=OpenProcess(0x410,false,(uint)p.Id);if(h==IntPtr.Zero)throw new IOException("Lettura processo non disponibile");
                        long created,exited,kernel,user;
                        if(!GetProcessTimes(h,out created,out exited,out kernel,out user))throw new IOException("Identita non disponibile");
                        StringBuilder image=new StringBuilder(32768);int count=image.Capacity;
                        if(!QueryFullProcessImageName(h,0,image,ref count))throw new IOException("Percorso non disponibile");
                        if(created<=0 || (app && !string.Equals(Path.GetFileNameWithoutExtension(image.ToString()),browser,StringComparison.OrdinalIgnoreCase)))throw new IOException("Identita cambiata durante la lettura");
                        bool own=p.Id==ownPid || string.Equals(image.ToString(),enginePath,StringComparison.OrdinalIgnoreCase) || string.Equals(image.ToString(),hostPath,StringComparison.OrdinalIgnoreCase);
                        if(!app && !own)continue;
                        Memory m=new Memory();m.Cb=(uint)Marshal.SizeOf(typeof(Memory));
                        if(!GetProcessMemoryInfo(h,ref m,m.Cb) || m.PrivateWs.ToUInt64()>m.Ws.ToUInt64())throw new IOException("RAM privata residente non disponibile");
                        long bytes=checked((long)m.PrivateWs.ToUInt64());
                        if(own){ownPrivate=checked(ownPrivate+bytes);if(p.Id==ownPid)ownFound=true;}
                        if(app) {
                            appPrivate=checked(appPrivate+bytes);r.AppCommitBytes=checked(r.AppCommitBytes+(long)m.PrivateUsage.ToUInt64());
                            string key=p.Id+":"+created+":"+image.ToString().ToLowerInvariant();identities.Add(key);
                            Io io;if(GetProcessIoCounters(h,out io))current[key]=new Counter {Cpu=checked(kernel+user),Faults=m.Faults,Reads=io.ReadBytes};
                            else countersComplete=false;
                        }
                    } catch { if(app)appComplete=false;else ownComplete=false; }
                    finally {if(h!=IntPtr.Zero)CloseHandle(h);}
                }
            }
            identities.Sort(StringComparer.Ordinal);r.IdentityKey=string.Join("|",identities.ToArray());
            r.AppPrivateBytes=appComplete?(long?)appPrivate:null;r.OwnPrivateBytes=ownComplete && ownFound?(long?)ownPrivate:null;
            r.Complete=appComplete && ownComplete && ownFound;
            long now=Stopwatch.GetTimestamp();double seconds=(now-previousAt)/(double)Stopwatch.Frequency;
            bool covered=previous!=null && previous.Count==current.Count && countersComplete && appComplete && seconds>0 && seconds<=12;
            double cpu=0,faults=0,reads=0;
            if(covered)foreach(KeyValuePair<string,Counter> item in current) {
                Counter before;if(!previous.TryGetValue(item.Key,out before) || item.Value.Cpu<before.Cpu || item.Value.Reads<before.Reads || item.Value.Faults<before.Faults){covered=false;break;}
                cpu+=(item.Value.Cpu-before.Cpu)/10000000.0;faults+=item.Value.Faults-before.Faults;reads+=item.Value.Reads-before.Reads;
            }
            r.CounterCoverageComplete=covered;
            if(covered){r.CpuPercent=100*cpu/seconds/Environment.ProcessorCount;r.PageFaultsPerSecond=faults/seconds;r.IoReadBytesPerSecond=reads/seconds;}
            previous=current;previousAt=now;return r;
        }
    }
}
