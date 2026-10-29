namespace AmeHub {
    public static class ResourceApiClientTests {
        private static int count;
        private static void Check(bool value) { count++; if(!value) throw new System.Exception("API client contract check "+count); }
        private static void Refuses(System.Action action) {
            bool refused=false; try { action(); } catch { refused=true; } Check(refused);
        }
        private static int Fill(uint pid, System.IntPtr output) {
            Check(System.Runtime.InteropServices.Marshal.ReadInt32(output)==65552);
            System.Runtime.InteropServices.Marshal.WriteInt32(output,4,unchecked((int)pid));
            System.Runtime.InteropServices.Marshal.WriteInt64(output,8,134362770626194055L);
            byte[] path=System.Text.Encoding.Unicode.GetBytes("D:\\Apps con spazi\\caff\u00e8.exe\0");
            System.Runtime.InteropServices.Marshal.Copy(path,0,System.IntPtr.Add(output,16),path.Length);
            return 0;
        }
        public static ResourceApiClient ValidClient() {
            return new ResourceApiClient(delegate {return 1;},delegate {return 0;},Fill);
        }
        public static int Run() {
            count=0;
            Refuses(delegate { using(var c=new ResourceApiClient(delegate {return 2;},delegate {return 0;},Fill)) {} });
            var client=ValidClient();
            var id=client.Read(22452);
            Check(id.Pid==22452 && id.Creation==134362770626194055UL && id.Path=="D:\\Apps con spazi\\caff\u00e8.exe");
            client.Validate("22452:134362770626194055","d:\\apps con spazi\\CAFF\u00c8.exe");
            Refuses(delegate {client.Validate("22452:134362770626194054",id.Path);});
            Refuses(delegate {client.Validate("22452:134362770626194055","D:\\different.exe");});
            Refuses(delegate {client.Validate("22452",id.Path);});
            Refuses(delegate {client.Validate("22452:0",id.Path);});
            Refuses(delegate {client.Validate("4294967296:134362770626194055",id.Path);});
            Refuses(delegate {client.Validate("22452:134362770626194055","");});
            Refuses(delegate {client.Read(0);});
            Check(client.SuccessfulReads==4);
            client.Dispose();client.Dispose();
            Refuses(delegate {client.Read(22452);});
            using(var bad=new ResourceApiClient(delegate {return 1;},delegate {return 5;},delegate(uint p,System.IntPtr b){return 3;})) {
                string message="";try {bad.Read(22452);} catch(System.Exception e){message=e.Message;}
                Check(message.Contains("API 3, Windows 5") && bad.SuccessfulReads==0);
            }
            ResourceApiClient.ReadIdentity[] invalid={
                delegate(uint p,System.IntPtr b){Fill(p,b);System.Runtime.InteropServices.Marshal.WriteInt32(b,1);return 0;},
                delegate(uint p,System.IntPtr b){Fill(p,b);System.Runtime.InteropServices.Marshal.WriteInt32(b,4,7);return 0;},
                delegate(uint p,System.IntPtr b){Fill(p,b);System.Runtime.InteropServices.Marshal.WriteInt64(b,8,0);return 0;},
                delegate(uint p,System.IntPtr b){Fill(p,b);System.Runtime.InteropServices.Marshal.WriteInt16(b,16,0);return 0;},
                delegate(uint p,System.IntPtr b){Fill(p,b);for(int i=16;i<65552;i+=2)System.Runtime.InteropServices.Marshal.WriteInt16(b,i,65);return 0;}
            };
            foreach(var r in invalid) using(var bad=new ResourceApiClient(delegate {return 1;},delegate {return 0;},r)) {
                Refuses(delegate {bad.Read(22452);});Check(bad.SuccessfulReads==0);
            }
            return count;
        }
    }
}
