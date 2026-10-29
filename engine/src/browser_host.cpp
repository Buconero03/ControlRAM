#include <windows.h>
#include <sddl.h>
#include <cstdint>
#include <string>
#include <vector>
#include "browser_identity.hpp"

namespace {
constexpr std::uint32_t limit = 262144;
bool transfer(HANDLE h,void* buffer,DWORD count,DWORD& transferred,bool writing,bool overlapped) {
    if(!overlapped) return writing ? WriteFile(h,buffer,count,&transferred,nullptr)!=FALSE
                                  : ReadFile(h,buffer,count,&transferred,nullptr)!=FALSE;
    OVERLAPPED operation{};
    operation.hEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    if(!operation.hEvent)return false;
    const BOOL immediate=writing ? WriteFile(h,buffer,count,&transferred,&operation)
                                 : ReadFile(h,buffer,count,&transferred,&operation);
    bool ok=immediate!=FALSE;
    if(!ok && GetLastError()==ERROR_IO_PENDING)
        ok=GetOverlappedResult(h,&operation,&transferred,TRUE)!=FALSE;
    // Each direction owns its event and OVERLAPPED until completion.
    CloseHandle(operation.hEvent);
    return ok;
}
bool read_exact(HANDLE h,void* buffer,DWORD length,bool overlapped) {
    auto p=static_cast<unsigned char*>(buffer);
    while(length) { DWORD n=0; if(!transfer(h,p,length,n,false,overlapped)||n==0||n>length)return false; p+=n; length-=n; }
    return true;
}
bool write_exact(HANDLE h,void* buffer,DWORD length,bool overlapped) {
    auto p=static_cast<unsigned char*>(buffer);
    while(length) { DWORD n=0; if(!transfer(h,p,length,n,true,overlapped)||n==0||n>length)return false; p+=n; length-=n; }
    return true;
}
bool forward(HANDLE from,HANDLE to,bool from_overlapped,bool to_overlapped) {
    std::uint32_t length=0;
    if(!read_exact(from,&length,4,from_overlapped)||length==0||length>limit)return false;
    std::vector<unsigned char> data(length);
    return read_exact(from,data.data(),length,from_overlapped)&&write_exact(to,&length,4,to_overlapped)&&write_exact(to,data.data(),length,to_overlapped);
}
struct Channel { HANDLE pipe, output; };
DWORD WINAPI output_loop(void* raw) {
    auto c=static_cast<Channel*>(raw);
    while(forward(c->pipe,c->output,true,false)) { }
    // stdin may be blocked: native host has no state to restore.
    ExitProcess(0);
}
std::wstring pipe_name() {
    HANDLE token=nullptr;
    if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return {};
    DWORD size=0; GetTokenInformation(token,TokenUser,nullptr,0,&size);
    std::vector<unsigned char> data(size);
    if(!size||!GetTokenInformation(token,TokenUser,data.data(),size,&size)) { CloseHandle(token); return {}; }
    CloseHandle(token); LPWSTR sid=nullptr;
    if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid,&sid))return {};
    DWORD session=0;
    if(!ProcessIdToSessionId(GetCurrentProcessId(),&session)) { LocalFree(sid); return {}; }
    std::wstring name=L"\\\\.\\pipe\\AME.v03."+std::wstring(sid)+L"."+std::to_wstring(session);
    LocalFree(sid); return name;
}
}
int wmain(int argc,wchar_t** argv) {
    wchar_t executable[32768]{};
    const DWORD length=GetModuleFileNameW(nullptr,executable,32768);
    bool firefox_manifest_matches=false;
    if(argc==3 && length && length<32768) {
        const std::wstring path(executable,length);
        const auto slash=path.find_last_of(L"\\/");
        if(slash!=std::wstring::npos) {
            const auto expected=path.substr(0,slash+1)+L"firefox-native-host.json";
            firefox_manifest_matches=CompareStringOrdinal(argv[1],-1,expected.c_str(),-1,TRUE)==CSTR_EQUAL;
        }
    }
    if(!ame_browser_launch_allowed(argc,argv,firefox_manifest_matches))return 2;
    const auto name=pipe_name(); if(name.empty())return 3;
    if(!WaitNamedPipeW(name.c_str(),3000))return 4;
    HANDLE pipe=CreateFileW(name.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
    if(pipe==INVALID_HANDLE_VALUE)return 5;
    Channel channel{pipe,GetStdHandle(STD_OUTPUT_HANDLE)};
    HANDLE thread=CreateThread(nullptr,0,output_loop,&channel,0,nullptr);
    if(!thread) { CloseHandle(pipe); return 6; }
    while(forward(GetStdHandle(STD_INPUT_HANDLE),pipe,false,true)) { }
    // Process exit tears down the blocked forwarding thread and its handles.
    ExitProcess(0);
}
