#pragma once
// Included after Win32 utilities. No quotas or priorities are changed.
#include "recover_policy.hpp"

bool read_memory(HANDLE h, CountersEx2& counters) {
    counters={}; counters.base.cb=sizeof(counters);
    return GetProcessMemoryInfo(h,reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&counters),sizeof(counters)) &&
        counters.private_ws<=counters.base.WorkingSetSize;
}
class RecoverController {
    std::set<std::wstring> allowed_;
    std::set<std::pair<std::uint32_t,std::uint64_t>> selected_;
    ame::RecoverPressure pressure_;
    ame::RecoverGate gate_;
    Handle mutex_{nullptr};
    DWORD session_=0;
    std::ofstream& report_;
    struct Pending {
        DWORD pid; std::uint64_t creation,ws,private_ws,commit,available;
        double began,baseline_faults;
        ame::RecoverBenefit benefit;
        bool at5=false,at15=false,at60=false,at180=false,activity_warning=false,usage_resumed=false;
        double peak_cpu=0,peak_faults=0,baseline_cpu=0;
    };
    std::optional<Pending> pending_;
    std::string disabled_reason_;
    bool single_test_=false;
    void event(const char* type,DWORD pid,double now,const char* reason,DWORD error=0) {
        report_<<"{\"type\":"<<quote(type)<<",\"pid\":"<<pid<<",\"elapsed_seconds\":"<<now
            <<",\"reason\":"<<quote(reason)<<",\"win32_error\":"<<error<<"}\n";
    }
    void disable(const char* reason) { gate_.disable(); disabled_reason_=reason; }
    void assessed(const Process& row,double now,const char* reason) {
        const auto& p=*pending_;
        report_<<"{\"type\":\"recover_assessed\",\"pid\":"<<p.pid<<",\"creation_filetime\":\""<<p.creation
            <<"\",\"image_path\":"<<quote(utf8(row.image.c_str()))<<",\"elapsed_seconds\":"<<now
            <<",\"seconds_after_action\":"<<now-p.began<<",\"reason\":"<<quote(reason)
            <<",\"best_private_resident_reduction_bytes\":"<<p.benefit.best_drop()
            <<",\"remaining_private_resident_reduction_bytes\":"<<p.benefit.remaining_drop()
            <<",\"retained_percent\":"<<p.benefit.retained_percent()
            <<",\"minimum_private_resident_reduction_last_60s_bytes\":"<<p.benefit.minimum_recent_drop()
            <<",\"observation_target_seconds\":"<<ame::recover_observation_seconds
            <<",\"usage_resumed\":"<<(p.usage_resumed?"true":"false")
            <<",\"peak_cpu_percent\":"<<p.peak_cpu<<",\"peak_page_faults_per_second\":"<<p.peak_faults
            <<",\"baseline_page_faults_per_second\":"<<p.baseline_faults
            <<",\"baseline_cpu_percent\":"<<p.baseline_cpu
            <<",\"activity_warning\":"<<(p.activity_warning?"true":"false")
            <<",\"win32_error\":0,\"causation_established\":false,\"latency_measured\":false}\n";
    }
    void feedback(const Process& row,const ame::SystemSample& system,double now,const char* phase) {
        const auto& p=*pending_;
        const auto remaining=p.private_ws>row.private_ws?p.private_ws-row.private_ws:0;
        const auto peak=std::max(p.benefit.best_drop(),remaining);
        report_<<"{\"type\":\"recover_feedback\",\"pid\":"<<p.pid<<",\"creation_filetime\":\""<<p.creation
            <<"\",\"elapsed_seconds\":"<<now<<",\"seconds_after_action\":"<<now-p.began<<",\"phase\":"<<quote(phase)
            <<",\"private_resident_before_bytes\":"<<p.private_ws<<",\"private_resident_after_bytes\":"<<row.private_ws
            <<",\"private_resident_delta_bytes\":"<<static_cast<std::int64_t>(row.private_ws)-static_cast<std::int64_t>(p.private_ws)
            <<",\"working_set_delta_bytes\":"<<static_cast<std::int64_t>(row.ws)-static_cast<std::int64_t>(p.ws)
            <<",\"private_commit_delta_bytes\":"<<static_cast<std::int64_t>(row.commit)-static_cast<std::int64_t>(p.commit)
            <<",\"system_available_delta_bytes\":"<<static_cast<std::int64_t>(system.available)-static_cast<std::int64_t>(p.available)
            <<",\"best_private_resident_reduction_bytes\":"<<peak
            <<",\"remaining_private_resident_reduction_bytes\":"<<remaining
            <<",\"retained_percent\":"<<(peak?100.0*static_cast<double>(remaining)/static_cast<double>(peak):0)
            <<",\"activity_warning\":"<<(p.activity_warning?"true":"false")
            <<",\"cpu_percent\":"<<row.cpu_percent<<",\"page_faults_per_second\":"<<row.faults_per_second
            <<",\"usage_resumed\":"<<(p.usage_resumed?"true":"false")
            <<",\"causation_established\":false,\"latency_measured\":false,\"hard_faults_only\":false}\n";
    }
public:
    RecoverController(const std::vector<std::wstring>& allowed,const std::vector<std::pair<std::uint32_t,std::uint64_t>>& selected,std::ofstream& report,bool single_test=false):selected_(selected.begin(),selected.end()),gate_(single_test?1:3),report_(report),single_test_(single_test) {
        if(single_test_&&(selected_.size()!=1||allowed.size()!=1))throw std::runtime_error("Single test requires one process and image");
        mutex_.value=CreateMutexW(nullptr,FALSE,L"Local\\AME-MemoryPriority-Controller");
        const DWORD error=GetLastError();
        if(!mutex_.value||error==ERROR_ALREADY_EXISTS)throw std::runtime_error("Another AME mutation controller is already running in this session");
        if(!ProcessIdToSessionId(GetCurrentProcessId(),&session_))throw std::runtime_error("Session unavailable");
        wchar_t windows[MAX_PATH]{};
        if(!GetWindowsDirectoryW(windows,MAX_PATH))throw std::runtime_error("Windows directory unavailable");
        const auto prefix=lower_image(windows)+L"\\";
        for(const auto& image:allowed) {
            const auto value=lower_image(image);
            if(value.rfind(prefix,0)==0)throw std::runtime_error("Windows system images are excluded");
            allowed_.insert(value);
        }
        report_<<"{\"type\":\"recover_session\",\"engine_revision\":\"R10\",\"single_test\":"<<(single_test_?"true":"false")<<",\"selected\":[";
        bool first=true;
        for(const auto& id:selected_) { if(!first)report_<<',';first=false;report_<<"{\"pid\":"<<id.first<<",\"creation_filetime\":\""<<id.second<<"\"}"; }
        report_<<"],\"allowed_images\":[";first=true;
        for(const auto& image:allowed_) { if(!first)report_<<',';first=false;report_<<quote(utf8(image.c_str())); }
        report_<<"],\"observation_target_seconds\":"<<ame::recover_observation_seconds<<"}\n";
    }
    bool finished() const { return single_test_&&gate_.attempted()&&!pending_; }
    bool feedback_pending() const { return pending_.has_value(); }
    void shutdown(double now) {
        if(pending_) { event("recover_incomplete",pending_->pid,now,"stopped_before_full_feedback_no_rollback"); pending_.reset(); }
        else if(single_test_&&!gate_.attempted())event("recover_no_action",selected_.begin()->first,now,"stopped_or_timed_out_before_eligibility");
    }
    void update(const ame::SystemSample& system,const std::vector<Process>& rows,double now,bool actions_open=true) {
        const bool pressure=pressure_.update(system,now);
        std::vector<ame::Identity> identities;
        bool foreground_known=false;
        for(const auto& row:rows) {
            const auto base=lower_image(std::filesystem::path(row.image).filename().wstring());
            const bool launcher=base==L"explorer.exe"||base==L"windowsterminal.exe"||base==L"powershell.exe"||base==L"pwsh.exe"||base==L"cmd.exe"||base==L"conhost.exe"||!row.critical_known||row.critical;
            identities.push_back({row.pid,row.parent,row.creation,utf8(row.image.c_str()),row.foreground,launcher});
            if(row.foreground&&row.creation&&!row.image.empty())foreground_known=true;
        }
        const auto protected_ids=ame::foreground_family(identities);
        const auto target_reason=[&](const Process& row)->const char* {
            if(row.pid==GetCurrentProcessId()||std::filesystem::path(row.image).filename()==L"ame.exe")return "controller_self";
            if(!allowed_.count(row.image))return "image_not_allowed";
            if(!foreground_known)return "foreground_unknown";
            if(pending_)return "feedback_pending";
            if(gate_.disabled())return "session_disabled";
            if(!actions_open)return "action_window_closed";
            const auto reason=ame::recover_reason(pressure,true,protected_ids.count(row.pid)!=0,
                row.rate_known&&row.memory_known&&system.valid(),row.own_user,row.session==session_,row.critical_known,row.critical,
                row.low_activity_seconds,row.ws,row.private_ws_known?std::optional<std::uint64_t>(row.private_ws):std::nullopt,single_test_);
            if(std::string(reason)=="eligible"&&!gate_.allowed(row.pid,row.creation,now,false))return "session_limit_or_already_attempted";
            return reason;
        };
        if(pending_) {
            const auto p=*pending_; const Process* row=nullptr;
            for(const auto& r:rows)if(r.pid==p.pid&&r.creation==p.creation) { row=&r; break; }
            const bool valid=row&&row->rate_known&&row->memory_known&&row->private_ws_known&&system.valid()&&foreground_known;
            const char* guard=nullptr;
            if(!valid)guard="feedback_telemetry_or_identity_lost";
            else if(!pending_->benefit.update(row->private_ws,now))guard="feedback_sampling_gap";
            const char* early=guard?nullptr:pending_->benefit.early_reason(now);
            if(!guard) {
                pending_->peak_cpu=std::max(pending_->peak_cpu,row->cpu_percent);
                pending_->peak_faults=std::max(pending_->peak_faults,row->faults_per_second);
                if(!pending_->usage_resumed&&protected_ids.count(p.pid)) {
                    // Foreground protection still forbids mutations. Read-only measurements
                    // continue so that resuming the app cannot hide an immediate refill.
                    pending_->usage_resumed=true;disable("foreground_return_observation_only");
                    event("recover_usage_warning",p.pid,now,"foreground_return_observation_only");
                    feedback(*row,system,now,"usage_resumed");
                }
            }
            if(!guard&&!early&&!pending_->activity_warning&&ame::recover_activity(row->cpu_percent,row->faults_per_second,p.baseline_faults)) {
                // FaultCount combines soft and hard faults. Stop mutations immediately,
                // but retain the read-only observation; do not assert a performance gain.
                pending_->activity_warning=true;disable("activity_or_fault_increase_stop_further_actions");
                feedback(*row,system,now,"activity_warning");
                event("recover_activity_warning",p.pid,now,"activity_or_fault_increase_stop_further_actions");
            }
            if(guard) {
                if(valid)feedback(*row,system,now,"guard");
                disable(guard); event("recover_guard",p.pid,now,guard); pending_.reset();
            } else if(early) {
                feedback(*row,system,now,"rebound_check");
                disable(early); assessed(*row,now,early); pending_.reset();
            } else {
                const double elapsed=now-p.began;
                if((elapsed>=5&&!pending_->at5)||(elapsed>=15&&!pending_->at15)||
                    (elapsed>=60&&!pending_->at60)||(elapsed>=180&&!pending_->at180)||elapsed>=ame::recover_observation_seconds) {
                    feedback(*row,system,now,elapsed>=ame::recover_observation_seconds?"300s":elapsed>=180?"180s":elapsed>=60?"60s":elapsed>=15?"15s":"5s");
                    if(elapsed>=ame::recover_observation_seconds) {
                        const bool retained=pending_->benefit.retained_last_minute();
                        // Global available RAM is contextual: unrelated apps must neither
                        // establish nor invalidate this process's observed resident reduction.
                        const auto reason=!retained?"resident_reduction_not_retained_5m":pending_->usage_resumed?"resident_reduction_retained_5m_after_resume":pending_->activity_warning?"resident_reduction_retained_5m_with_activity":"resident_reduction_retained_5m";
                        if(!retained||pending_->activity_warning||pending_->usage_resumed)disable(reason);
                        assessed(*row,now,reason);
                        pending_.reset();
                    } else if(elapsed>=180)pending_->at180=true;else if(elapsed>=60)pending_->at60=true;
                    else if(elapsed>=15)pending_->at15=true; else pending_->at5=true;
                }
            }
        }
        std::map<std::string,unsigned> reasons;
        for(const auto& selected:selected_) {
            const Process* target=nullptr;
            for(const auto& row:rows)if(row.pid==selected.first&&row.creation==selected.second) { target=&row;break; }
            const auto reason=target?target_reason(*target):"selected_process_no_longer_running";
            report_<<"{\"type\":\"recover_target\",\"pid\":"<<selected.first<<",\"creation_filetime\":\""<<selected.second
                <<"\",\"elapsed_seconds\":"<<now<<",\"reason\":"<<quote(reason)<<",\"pressure\":"<<(pressure?"true":"false")
                <<",\"single_test\":"<<(single_test_?"true":"false")<<",\"low_activity_seconds\":"<<(target?target->low_activity_seconds:0)
                <<",\"cpu_percent\":";
            if(target&&target->rate_known)report_<<target->cpu_percent;else report_<<"null";
            report_<<",\"page_faults_per_second\":";
            if(target&&target->rate_known)report_<<target->faults_per_second;else report_<<"null";
            report_<<",\"private_resident_bytes\":";
            if(target&&target->memory_known&&target->private_ws_known)report_<<target->private_ws;else report_<<"null";
            report_<<",\"working_set_bytes\":";
            if(target&&target->memory_known)report_<<target->ws;else report_<<"null";
            report_<<",\"private_commit_bytes\":";
            if(target&&target->memory_known)report_<<target->commit;else report_<<"null";
            report_<<"}\n";
            if(!target)++reasons[reason];
        }
        unsigned candidates=0;
        if(actions_open&&!gate_.disabled()&&!pending_&&foreground_known)for(const auto& row:rows) {
            if(!allowed_.count(row.image)||!selected_.count({row.pid,row.creation}))continue;
            const char* reason=target_reason(row);
            if(std::string(reason)!="eligible") { ++reasons[reason]; continue; }
            if(!gate_.allowed(row.pid,row.creation,now,pending_.has_value())) { ++reasons["session_limit_or_already_attempted"]; continue; }
            ++candidates;
            gate_.attempt(row.pid,row.creation,now);
            Handle target(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|PROCESS_SET_QUOTA|SYNCHRONIZE,FALSE,row.pid));
            if(!target.value) { event("recover_skipped",row.pid,now,"access_denied",GetLastError()); break; }
            FILETIME created{},exited{},kernel{},user{}; DWORD session=0; BOOL critical=TRUE;
            if(!GetProcessTimes(target.value,&created,&exited,&kernel,&user)||ticks(created)!=row.creation||
                process_image(target.value)!=row.image||!same_user(target.value)||
                !ProcessIdToSessionId(row.pid,&session)||session!=session_||
                !process_critical(target.value,&critical)||critical||WaitForSingleObject(target.value,0)!=WAIT_TIMEOUT) {
                event("recover_skipped",row.pid,now,"identity_owner_or_critical_changed"); break;
            }
            CountersEx2 before{};
            if(!read_memory(target.value,before)||before.private_ws<128*ame::MiB||before.base.WorkingSetSize>2ULL*1024*ame::MiB) {
                event("recover_skipped",row.pid,now,"resident_memory_changed"); break;
            }
            // Fresh activity counters reduce races with a workload restarting.
            const auto current_cpu=ticks(kernel)+ticks(user);
            if(current_cpu<row.cpu_ticks||current_cpu-row.cpu_ticks>100000||
                static_cast<DWORD>(before.base.PageFaultCount-row.faults)>10) {
                event("recover_skipped",row.pid,now,"activity_changed_since_sample"); break;
            }
            DWORD foreground=0; GetWindowThreadProcessId(GetForegroundWindow(),&foreground);
            Handle fg(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,foreground));
            bool latest_known=false;
            for(auto& id:identities) { id.foreground=id.pid==foreground; if(id.foreground&&id.creation&&!id.image.empty())latest_known=true; }
            if(!fg.value||!latest_known||process_image(fg.value)==row.image||ame::foreground_family(identities).count(row.pid)) {
                event("recover_skipped",row.pid,now,"foreground_changed"); break;
            }
            const auto before_system=sample_system();
            if(!before_system.valid()||(!single_test_&&before_system.used_percent()<85)) { event("recover_skipped",row.pid,now,"pressure_changed"); break; }
            // Persist the intent before the irreversible resident-set change.
            event("recover_intent",row.pid,now,"single_process_empty_working_set"); report_.flush();
            if(!report_)throw std::runtime_error("Cannot record recovery intent");
            if(!EmptyWorkingSet(target.value)) { event("recover_skipped",row.pid,now,"empty_working_set_failed",GetLastError()); break; }
            gate_.succeeded();
            pending_=Pending{row.pid,row.creation,before.base.WorkingSetSize,before.private_ws,before.base.PrivateUsage,before_system.available,now,row.faults_per_second,ame::RecoverBenefit(before.private_ws,now)};
            pending_->baseline_cpu=row.cpu_percent;
            event("recover_applied",row.pid,now,"resident_pages_trimmed_allocations_not_freed");
            CountersEx2 after{};
            if(read_memory(target.value,after)) {
                Process immediate=row; immediate.ws=after.base.WorkingSetSize; immediate.private_ws=after.private_ws; immediate.commit=after.base.PrivateUsage;
                pending_->benefit.update(after.private_ws,now);
                feedback(immediate,sample_system(),now,"immediate");
            } else { disable("post_action_read_failed"); event("recover_guard",row.pid,now,"post_action_read_failed"); pending_.reset(); }
            break;
        }
        report_<<"{\"type\":\"recover_state\",\"elapsed_seconds\":"<<now<<",\"pressure\":"<<(pressure?"true":"false")
            <<",\"single_test\":"<<(single_test_?"true":"false")<<",\"max_actions\":"<<(single_test_?1:3)
            <<",\"completed\":"<<gate_.count()<<",\"feedback_pending\":"<<(pending_?"true":"false")
            <<",\"feedback_seconds_remaining\":"<<(pending_?std::max(0.0,ame::recover_observation_seconds-(now-pending_->began)):0)
            <<",\"observation_target_seconds\":"<<ame::recover_observation_seconds
            <<",\"usage_resumed\":"<<(pending_&&pending_->usage_resumed?"true":"false")
            <<",\"activity_warning\":"<<(pending_&&pending_->activity_warning?"true":"false")
            <<",\"disabled\":"<<(gate_.disabled()?"true":"false")<<",\"disabled_reason\":"<<quote(disabled_reason_)
            <<",\"foreground_known\":"<<(foreground_known?"true":"false")<<",\"candidates\":"<<candidates<<",\"reasons\":{";
        bool first=true; for(const auto& entry:reasons) { if(!first)report_<<','; first=false; report_<<quote(entry.first)<<':'<<entry.second; }
        report_<<"}}\n";
    }
};
