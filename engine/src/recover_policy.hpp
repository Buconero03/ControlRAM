#pragma once
#include "native_policy.hpp"
#include <map>
#include <deque>
#include <stdexcept>

namespace ame {
inline std::pair<std::uint32_t,std::uint64_t> selected_identity(const std::string& text) {
    const auto colon=text.find(':');
    if(colon==std::string::npos||text.find(':',colon+1)!=std::string::npos)throw std::runtime_error("allow-process requires PID:creation_filetime");
    const auto pid=text.substr(0,colon),created=text.substr(colon+1);
    if(pid.empty()||created.empty()||pid.find_first_not_of("0123456789")!=std::string::npos||created.find_first_not_of("0123456789")!=std::string::npos)throw std::runtime_error("Invalid process identity");
    const auto p=std::stoull(pid),c=std::stoull(created);
    if(p==0||p>0xffffffffULL||c==0)throw std::runtime_error("Invalid process identity range");
    return {static_cast<std::uint32_t>(p),c};
}
class RecoverPressure {
    std::optional<double> since_, previous_;
    bool active_ = false;
public:
    bool update(const SystemSample& s, double now) {
        if (!s.valid() || !std::isfinite(now) || (previous_ && (now < *previous_ || now-*previous_>6))) {
            since_.reset(); previous_.reset(); return active_=false;
        }
        previous_=now;
        if(active_) { if(s.used_percent()<80) { active_=false; since_.reset(); } return active_; }
        if(s.used_percent()<85) { since_.reset(); return false; }
        if(!since_)since_=now;
        return active_=now-*since_>=30;
    }
};
inline const char* recover_reason(bool pressure,bool allowed,bool protected_family,bool known,
    bool same_owner,bool same_session,bool critical_known,bool critical,double idle,
    std::uint64_t ws,std::optional<std::uint64_t> private_ws,bool single_test=false) {
    if(!allowed)return "not_selected";
    if(!same_owner||!same_session)return "owner_or_session";
    if(!critical_known||critical)return "critical_or_unknown";
    if(protected_family)return "foreground_family";
    if(!known||!std::isfinite(idle)||!private_ws||*private_ws>ws)return "telemetry_missing";
    if(ws>2ULL*1024*MiB)return "target_over_2_GiB";
    if(*private_ws<128*MiB)return "private_resident_below_128_MiB";
    if(idle<60)return "low_activity_under_60_seconds";
    if(!pressure&&!single_test)return "waiting_pressure_85_percent_30_seconds";
    return "eligible";
}
inline bool recover_activity(double cpu,double faults,double baseline) {
    return !std::isfinite(cpu)||!std::isfinite(faults)||!std::isfinite(baseline)||
        cpu>=0.5||faults>std::max(100.0,5*baseline);
}
// An expired action window may only finish an already-started measurement.
constexpr double recover_observation_seconds=300;
inline bool recover_observation_allowed(double now,double deadline,bool pending) {
    return std::isfinite(now)&&std::isfinite(deadline)&&now>=0&&deadline>0&&
        (now<deadline||(pending&&now<deadline+recover_observation_seconds+6));
}
// Conservative observations, not a prediction of the application's future needs.
class RecoverBenefit {
    std::uint64_t before_, best_=0, remaining_=0;
    double began_;
    std::optional<double> previous_, rebound_since_;
    std::deque<std::pair<double,std::uint64_t>> recent_;
public:
    RecoverBenefit(std::uint64_t before,double began):before_(before),began_(began) {}
    bool update(std::uint64_t after,double now) {
        if(!std::isfinite(now)||now<began_||(previous_&&(now<*previous_||now-*previous_>6)))return false;
        previous_=now;
        remaining_=before_>after?before_-after:0;
        best_=std::max(best_,remaining_);
        if(!recent_.empty()&&recent_.back().first==now)recent_.back().second=remaining_;
        else recent_.push_back({now,remaining_});
        // Keep one boundary sample and at most 128 entries, independent of sample rate.
        while(recent_.size()>1&&recent_[1].first<=now-60)recent_.pop_front();
        while(recent_.size()>128)recent_.pop_front();
        if(now-began_>=5&&best_>=16*MiB&&remaining_<=best_/5) {
            if(!rebound_since_)rebound_since_=now;
        } else rebound_since_.reset();
        return true;
    }
    const char* early_reason(double now) const {
        if(!std::isfinite(now)||!previous_||now!=*previous_)return nullptr;
        if(now-began_>=5&&best_<16*MiB)return "no_meaningful_resident_reduction";
        if(rebound_since_&&now-*rebound_since_>=4)return "rapid_resident_rebound";
        return nullptr;
    }
    bool retained() const { return remaining_>=16*MiB&&remaining_>best_/5; }
    std::uint64_t minimum_recent_drop() const {
        if(recent_.empty())return 0;
        auto minimum=recent_.front().second;
        for(const auto& point:recent_)minimum=std::min(minimum,point.second);
        return minimum;
    }
    bool retained_last_minute() const {
        return previous_&&*previous_-began_>=recover_observation_seconds&&!recent_.empty()&&
            recent_.front().first<=*previous_-60&&minimum_recent_drop()>=16*MiB&&minimum_recent_drop()>best_/5;
    }
    std::uint64_t best_drop() const { return best_; }
    std::uint64_t remaining_drop() const { return remaining_; }
    double retained_percent() const { return best_?100.0*static_cast<double>(remaining_)/static_cast<double>(best_):0; }
};
class RecoverGate {
    std::set<std::pair<std::uint32_t,std::uint64_t>> attempts_;
    std::optional<double> last_;
    unsigned successes_=0;
    bool disabled_=false;
    unsigned maximum_=3;
public:
    explicit RecoverGate(unsigned maximum=3):maximum_(maximum) {
        if(maximum<1||maximum>3)throw std::runtime_error("Invalid recovery action limit");
    }
    bool allowed(std::uint32_t pid,std::uint64_t creation,double now,bool pending) const {
        return !disabled_ && !pending && successes_<maximum_ && pid!=0 && creation!=0 && std::isfinite(now) &&
            (!last_ || (now>=*last_ && now-*last_>=60)) && !attempts_.count({pid,creation});
    }
    void attempt(std::uint32_t pid,std::uint64_t creation,double now) { attempts_.insert({pid,creation}); last_=now; }
    void succeeded() { ++successes_; }
    void disable() { disabled_=true; }
    bool disabled() const { return disabled_; }
    unsigned count() const { return successes_; }
    bool attempted() const { return !attempts_.empty(); }
};
}
