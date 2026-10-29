// Executes the production RecoverController with deterministic Win32 substitutes.
// No process is opened or modified by this test, on either Linux or Windows.
#include "../src/recover_policy.hpp"
#include <fstream>
#include <filesystem>
#include <sstream>
#include <iostream>
#include <cwchar>
#include <cwctype>
#include <algorithm>
#include <cstdio>
namespace {
using DWORD=std::uint32_t; using BOOL=int; using HANDLE=std::uintptr_t;
constexpr BOOL FALSE=0,TRUE=1;
constexpr DWORD ERROR_ALREADY_EXISTS=183,PROCESS_QUERY_LIMITED_INFORMATION=1,PROCESS_SET_QUOTA=2,SYNCHRONIZE=4,WAIT_TIMEOUT=258,MAX_PATH=260;
struct FILETIME { DWORD dwLowDateTime=0,dwHighDateTime=0; };
struct PROCESS_MEMORY_COUNTERS { DWORD cb=0,PageFaultCount=0; std::uint64_t WorkingSetSize=0,PrivateUsage=0; };
struct CountersEx2 { PROCESS_MEMORY_COUNTERS base; std::uint64_t private_ws=0,shared_commit=0; };
struct Handle { HANDLE value=0; explicit Handle(HANDLE h):value(h){} explicit Handle(std::nullptr_t):value(0){} };
struct Process {
    DWORD pid=0,parent=0,session=1,faults=0; std::uint64_t creation=0,cpu_ticks=0,ws=0,private_ws=0,commit=0;
    std::wstring image; bool foreground=false,critical_known=true,critical=false,rate_known=true,memory_known=true,private_ws_known=true,own_user=true;
    double low_activity_seconds=60,cpu_percent=0,faults_per_second=0;
};
unsigned trim_calls=0;bool trimmed=false;DWORD foreground_pid=99;
std::wstring lower_image(std::wstring s){std::transform(s.begin(),s.end(),s.begin(),[](wchar_t c){return static_cast<wchar_t>(std::towlower(c));});return s;}
std::string utf8(const wchar_t* s){std::wstring w(s);return std::string(w.begin(),w.end());}
std::string quote(const std::string& s){std::string out="\"";for(char c:s){if(c=='\\'||c=='"')out+='\\';out+=c;}return out+'"';}
std::uint64_t ticks(const FILETIME& t){return (static_cast<std::uint64_t>(t.dwHighDateTime)<<32)|t.dwLowDateTime;}
HANDLE CreateMutexW(void*,BOOL,const wchar_t*){return 1;}
DWORD GetLastError(){return 0;}
DWORD GetCurrentProcessId(){return 999;}
BOOL ProcessIdToSessionId(DWORD,DWORD* session){*session=1;return TRUE;}
DWORD GetWindowsDirectoryW(wchar_t* p,DWORD){constexpr wchar_t value[]=L"C:\\Windows";std::copy(std::begin(value),std::end(value),p);return 10;}
BOOL GetProcessMemoryInfo(HANDLE,PROCESS_MEMORY_COUNTERS* p,DWORD){
    auto& out=*reinterpret_cast<CountersEx2*>(p);out.base.WorkingSetSize=(trimmed?4:400)*ame::MiB;
    out.base.PrivateUsage=500*ame::MiB;out.private_ws=(trimmed?1:320)*ame::MiB;return TRUE;
}
HANDLE OpenProcess(DWORD,BOOL,DWORD pid){return pid;}
BOOL GetProcessTimes(HANDLE,FILETIME* created,FILETIME*,FILETIME*,FILETIME*){created->dwLowDateTime=100;return TRUE;}
std::wstring process_image(HANDLE h){return h==99?L"d:\\apps\\editor.exe":L"d:\\apps\\app.exe";}
bool same_user(HANDLE){return true;}
BOOL process_critical(HANDLE,BOOL* critical){*critical=FALSE;return TRUE;}
DWORD WaitForSingleObject(HANDLE,DWORD){return WAIT_TIMEOUT;}
HANDLE GetForegroundWindow(){return foreground_pid;}
DWORD GetWindowThreadProcessId(HANDLE,DWORD* pid){*pid=foreground_pid;return 1;}
BOOL EmptyWorkingSet(HANDLE){++trim_calls;trimmed=true;return TRUE;}
ame::SystemSample sample_system(){return {16000*ame::MiB,2000*ame::MiB,10000*ame::MiB,24000*ame::MiB};}
#include "../src/recover_controller.hpp"
std::vector<Process> rows(std::uint64_t private_mib=320,double faults=0,bool foreground=false){
    Process target;target.pid=10;target.creation=100;target.image=L"d:\\apps\\app.exe";
    target.ws=(private_mib+80)*ame::MiB;target.private_ws=private_mib*ame::MiB;target.commit=500*ame::MiB;
    target.faults_per_second=faults;target.foreground=foreground;
    Process editor;editor.pid=99;editor.creation=50;editor.image=L"d:\\apps\\editor.exe";editor.foreground=!foreground;
    return {target,editor};
}
void reset(){trim_calls=0;trimmed=false;foreground_pid=99;}
std::string read(const std::filesystem::path& file){std::ifstream in(file);return {std::istreambuf_iterator<char>(in),std::istreambuf_iterator<char>()};}
unsigned occurrences(const std::string& s,const std::string& part){unsigned n=0;std::size_t p=0;while((p=s.find(part,p))!=std::string::npos){++n;p+=part.size();}return n;}
}
int main(){
    unsigned checks=0;const auto check=[&](bool ok,const char* why){++checks;if(!ok)throw std::runtime_error(why);};
    const auto path=std::filesystem::temp_directory_path()/"ame-controller-replay-test.jsonl";
    try{
        reset();{
            std::ofstream log(path);
            RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),0);
            check(trim_calls==1&&controller.feedback_pending()&&!controller.finished(),"one action starts measurement");
            controller.update(sample_system(),rows(2,413.411),1.928);
            check(controller.feedback_pending()&&!controller.finished()&&trim_calls==1,"recorded 413 faults do not terminate measurement or permit retry");
            for(int t=4;t<=300;t+=2){controller.update(sample_system(),rows(2,t<10?413.411:0),t);check(trim_calls==1,"no second action during warning observation");}
            check(controller.finished()&&!controller.feedback_pending(),"complete assessment at five minutes");
        }
        auto result=read(path);
        check(result.find("\"engine_revision\":\"R10\"")!=std::string::npos,"diagnosis identifies the corrected foreground engine");
        check(occurrences(result,"\"type\":\"recover_activity_warning\"")==1,"one warning event despite repeated spike");
        check(result.find("\"phase\":\"5s\"")!=std::string::npos&&result.find("\"phase\":\"15s\"")!=std::string::npos&&result.find("\"phase\":\"60s\"")!=std::string::npos,"full observation milestones survive warning");
        check(result.find("resident_reduction_retained_5m_with_activity")!=std::string::npos,"resident-only outcome after warning");
        check(result.find("\"reason\":\"resident_reduction_retained_5m\"")==std::string::npos,"warning cannot become qualified success");
        reset();{
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),166);
            for(int t=168;t<=466;t+=2){
                check(ame::recover_observation_allowed(t,180,controller.feedback_pending()),"late action retains observation time");
                controller.update(sample_system(),rows(2,t==168?413.411:0),t,t<180);
                check(trim_calls==1,"deadline extension cannot mutate");
            }
            check(controller.finished(),"late measurement completes at action plus five minutes");
            check(!ame::recover_observation_allowed(468,180,controller.feedback_pending()),"no extension after final outcome");
        }
        reset();{
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),180,false);
            check(trim_calls==0&&!controller.feedback_pending(),"expired action window forbids new trim");
        }
        reset();{
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),0);controller.update(sample_system(),rows(2,413),2);
            controller.update(sample_system(),rows(2,0,true),4);
            check(!controller.finished()&&controller.feedback_pending()&&trim_calls==1,"foreground return retains read-only observation");
            for(int t=6;t<=300;t+=2)controller.update(sample_system(),rows(2,0,true),t,t<180);
            check(controller.finished()&&trim_calls==1,"foreground observation completes without another mutation");
        }
        result=read(path);check(result.find("resident_reduction_retained_5m_after_resume")!=std::string::npos,"foreground resume recorded without claiming performance benefit");
        reset();{
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),0);controller.update(sample_system(),rows(2,413),2);
            controller.update(sample_system(),rows(310),6);controller.update(sample_system(),rows(310),10);
            check(controller.finished()&&trim_calls==1,"confirmed rebound ends warning observation");
        }
        result=read(path);check(result.find("rapid_resident_rebound")!=std::string::npos,"negative rebound assessment persists");
        reset();{
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),0);controller.update(sample_system(),rows(2,413),2);controller.shutdown(4);
            check(!controller.feedback_pending()&&controller.finished(),"stop cancels read-only extension");
        }
        result=read(path);check(result.find("recover_incomplete")!=std::string::npos,"stop cannot claim complete reduction");
        // Stable residency reduction is not inferred from unrelated global available RAM.
        reset();{
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),0);
            auto busy_system=sample_system();busy_system.available=1000*ame::MiB;
            for(int t=2;t<=300;t+=2){
                controller.update(busy_system,rows(128),t,t<180);
                if(t==60||t==180)check(controller.feedback_pending()&&!controller.finished(),"one or three minutes cannot certify a five-minute result");
            }
            check(controller.finished()&&trim_calls==1,"stable five-minute trial performs exactly one trim");
        }
        result=read(path);
        check(result.find("\"reason\":\"resident_reduction_retained_5m\"")!=std::string::npos,"lower global available RAM does not erase observed process residency reduction");
        check(result.find("\"minimum_private_resident_reduction_last_60s_bytes\":201326592")!=std::string::npos,"assessment reports worst retained reduction in the final minute");
        check(result.find("\"phase\":\"180s\"")!=std::string::npos&&result.find("\"phase\":\"300s\"")!=std::string::npos,"three- and five-minute milestones emitted");
        check(occurrences(result,"\"type\":\"recover_assessed\"")==1,"one final assessment only");
        // A good final sample must not hide a near-complete refill within the last minute.
        reset();{
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),0);
            for(int t=2;t<=300;t+=2)controller.update(sample_system(),rows(t==298?310:128),t,t<180);
            check(controller.finished()&&trim_calls==1,"unstable final minute ends without a retry");
        }
        result=read(path);check(result.find("resident_reduction_not_retained_5m")!=std::string::npos,"single last sample cannot establish durable reduction");
        reset();{
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),0);
            controller.update(sample_system(),rows(310,0,true),6);
            controller.update(sample_system(),rows(310,0,true),10);
            check(controller.finished()&&trim_calls==1,"refill while reusing app ends the trial without another trim");
        }
        result=read(path);check(result.find("rapid_resident_rebound")!=std::string::npos&&result.find("recover_usage_warning")!=std::string::npos,"actual-use refill is a negative observation");
        reset();{
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),0);
            auto reused=rows(2);reused[0].creation=101;
            controller.update(sample_system(),reused,2);
            check(controller.finished()&&trim_calls==1,"identity replacement still terminates observation");
        }
        result=read(path);check(result.find("feedback_telemetry_or_identity_lost")!=std::string::npos,"identity loss cannot claim five-minute success");
        reset();{
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),rows(),0);controller.update(sample_system(),rows(128),8);
            check(controller.finished()&&trim_calls==1,"sampling gap terminates observation");
        }
        result=read(path);check(result.find("feedback_sampling_gap")!=std::string::npos,"missing samples cannot certify stable reduction");
        // The production controller must not confuse separate cmd/conhost
        // instances with app helpers belonging to the foreground editor.
        reset();{
            auto shared=rows();
            Process active_cmd;active_cmd.pid=70;active_cmd.parent=99;active_cmd.creation=150;active_cmd.image=L"cmd.exe";
            Process active_console=active_cmd;active_console.pid=71;active_console.parent=70;active_console.creation=160;active_console.image=L"conhost.exe";
            Process app_cmd=active_cmd;app_cmd.pid=80;app_cmd.parent=10;app_cmd.creation=200;
            Process app_console=active_console;app_console.pid=81;app_console.parent=80;app_console.creation=210;
            shared.insert(shared.end(),{active_cmd,active_console,app_cmd,app_console});
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),shared,0);
            check(trim_calls==1&&controller.feedback_pending(),"shared console images do not block unrelated eligible target");
        }
        result=read(path);check(result.find("recover_applied")!=std::string::npos,"console isolation reaches actual controller action");
        reset();{
            auto shared=rows();shared[1].image=L"powershell.exe";
            Process other_shell=shared[1];other_shell.pid=80;other_shell.creation=70;other_shell.foreground=false;
            shared[0].parent=80;shared.push_back(other_shell);
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),shared,0);
            check(trim_calls==1&&controller.feedback_pending(),"foreground shell does not protect independent shell target");
        }
        reset();{
            auto own_branch=rows();own_branch[1].image=L"powershell.exe";own_branch[0].parent=99;
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),own_branch,0);
            check(trim_calls==0&&!controller.feedback_pending(),"actual foreground shell descendant remains protected");
        }
        result=read(path);check(result.find("foreground_family")!=std::string::npos,"actual branch reports protection instead of applying action");
        reset();{
            auto active_helper=rows();active_helper[1].parent=10;active_helper[1].creation=150;
            std::ofstream log(path);RecoverController controller({L"d:\\apps\\app.exe"},{{10,100}},log,true);
            controller.update(sample_system(),active_helper,0);
            check(trim_calls==0,"different-image foreground helper still protects app ancestor");
        }
        std::filesystem::remove(path);
        std::cout<<"PASS "<<checks<<" production recovery controller replay checks\n";
    }catch(const std::exception& e){std::filesystem::remove(path);std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
}
