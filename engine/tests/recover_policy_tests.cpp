#include "../src/recover_policy.hpp"
#include <iostream>
#include <stdexcept>
#include <limits>
int main() {
    using namespace ame; unsigned checks=0;
    const auto check=[&](bool ok,const char* text) { ++checks; if(!ok)throw std::runtime_error(text); };
    try {
        check(selected_identity("123:456")==std::make_pair(123u,std::uint64_t{456}),"selected identity parsed");
        for(const auto* text:{"0:1","1:0","1",":1","1:","1:2:3","-1:2","1:x","4294967296:1","1:18446744073709551616"}) {
            bool rejected=false; try { (void)selected_identity(text); } catch(const std::exception&) { rejected=true; }
            check(rejected,"invalid selected identity rejected");
        }
        RecoverPressure pressure;
        SystemSample high{16000*MiB,2000*MiB,10000*MiB,24000*MiB};
        for(unsigned t=0;t<30;t+=2)check(!pressure.update(high,t),"pressure must persist");
        check(pressure.update(high,30),"pressure after 30 seconds");
        auto middle=high; middle.available=3000*MiB;
        check(pressure.update(middle,32),"hysteresis");
        middle.available=4000*MiB; check(!pressure.update(middle,34),"pressure recovered");
        check(!pressure.update(high,36),"new interval");
        check(!pressure.update(high,60),"sampling gap");
        check(!pressure.update(high,59),"backward clock");
        check(!pressure.update({},62),"invalid metrics");
        const auto reason=[&](bool active=true,bool allowed=true,bool fg=false,bool known=true,bool owner=true,bool session=true,bool critical_known=true,bool critical=false,double idle=60,std::uint64_t ws=256*MiB,std::optional<std::uint64_t> private_ws=200*MiB) {
            return std::string(recover_reason(active,allowed,fg,known,owner,session,critical_known,critical,idle,ws,private_ws));
        };
        check(reason()=="eligible","valid selection");
        check(reason(false)=="waiting_pressure_85_percent_30_seconds","no pressure");
        check(reason(true,false)=="not_selected","opt in");
        check(reason(true,true,true)=="foreground_family","protect foreground");
        check(reason(true,true,false,false)=="telemetry_missing","unknown rates");
        check(reason(true,true,false,true,false)=="owner_or_session","foreign user");
        check(reason(true,true,false,true,true,false)=="owner_or_session","other session");
        check(reason(true,true,false,true,true,true,false)=="critical_or_unknown","unknown critical");
        check(reason(true,true,false,true,true,true,true,true)=="critical_or_unknown","critical process");
        check(reason(true,true,false,true,true,true,true,false,59)=="low_activity_under_60_seconds","idle persistence");
        check(reason(true,true,false,true,true,true,true,false,60,3ULL*1024*MiB)=="target_over_2_GiB","large target");
        check(reason(true,true,false,true,true,true,true,false,60,256*MiB,std::nullopt)=="telemetry_missing","private residency missing");
        check(reason(true,true,false,true,true,true,true,false,60,256*MiB,100*MiB)=="private_resident_below_128_MiB","small private target");
        check(recover_activity(0.5,0,0),"activity guard");
        check(recover_activity(0,101,0),"fault guard");
        check(!recover_activity(0.1,10,5),"quiet feedback");
        check(recover_activity(std::numeric_limits<double>::quiet_NaN(),0,0),"missing feedback");
        check(recover_observation_allowed(179.9,180,false),"ordinary action window");
        check(!recover_observation_allowed(180,180,false),"no pending observation at deadline");
        check(recover_observation_allowed(180,180,true),"finish pending observation only");
        check(recover_observation_allowed(485.9,180,true),"bounded observation extension");
        check(!recover_observation_allowed(486,180,true),"extension has hard upper bound");
        check(!recover_observation_allowed(-1,180,true),"invalid observation start");
        check(!recover_observation_allowed(std::numeric_limits<double>::quiet_NaN(),180,true),"invalid observation deadline input");
        RecoverBenefit stable(256*MiB,0);
        check(stable.update(64*MiB,0),"immediate benefit recorded");
        for(int t=2;t<=60;t+=2)check(stable.update(96*MiB,t)&&!stable.early_reason(t),"retained reduction is not a rebound");
        check(stable.retained()&&stable.best_drop()==192*MiB&&stable.remaining_drop()==160*MiB,"retained and peak drops separated");
        RecoverBenefit rebound(256*MiB,0);
        check(rebound.update(64*MiB,0),"rebound baseline");
        check(rebound.update(240*MiB,2)&&!rebound.early_reason(2),"early one sample cannot classify");
        check(rebound.update(240*MiB,6)&&!rebound.early_reason(6),"rebound requires confirmation interval");
        check(rebound.update(240*MiB,8)&&!rebound.early_reason(8),"two seconds insufficient");
        check(rebound.update(240*MiB,10)&&std::string(rebound.early_reason(10))=="rapid_resident_rebound","confirmed 80 percent refill cancels");
        check(!rebound.retained(),"16 MiB cannot mask 80 percent refill");
        RecoverBenefit spike(256*MiB,0);spike.update(64*MiB,0);spike.update(250*MiB,6);spike.update(64*MiB,8);
        check(spike.update(250*MiB,10)&&!spike.early_reason(10),"temporary spike resets rebound timer");
        RecoverBenefit none(256*MiB,0);none.update(250*MiB,0);none.update(250*MiB,2);
        check(!none.early_reason(2),"small initial drop still observed before five seconds");
        check(none.update(250*MiB,6)&&std::string(none.early_reason(6))=="no_meaningful_resident_reduction","small drop distinguished from refill");
        RecoverBenefit late(256*MiB,0);late.update(64*MiB,0);
        check(!late.update(64*MiB,7),"missing observation gap not benefit");
        RecoverBenefit reverse(256*MiB,0);reverse.update(64*MiB,2);
        check(!reverse.update(64*MiB,1),"reverse time not benefit");
        check(!reverse.update(64*MiB,std::numeric_limits<double>::quiet_NaN()),"invalid observation time");
        RecoverBenefit grows(256*MiB,0);grows.update(64*MiB,0);grows.update(300*MiB,6);grows.update(300*MiB,10);
        check(std::string(grows.early_reason(10))=="rapid_resident_rebound"&&grows.remaining_drop()==0,"growth after trim is not negative underflow");
        check(!stable.retained_last_minute(),"sixty seconds cannot prove a five-minute reduction");
        for(int t=62;t<=300;t+=2)stable.update(96*MiB,t);
        check(stable.retained_last_minute()&&stable.minimum_recent_drop()==160*MiB,"stable complete last minute retained at five minutes");
        RecoverBenefit unstable(256*MiB,0);unstable.update(64*MiB,0);
        for(int t=2;t<=300;t+=2)unstable.update((t==298?250:64)*MiB,t);
        check(unstable.retained()&&!unstable.retained_last_minute()&&unstable.minimum_recent_drop()==6*MiB,"single rebound in final minute cannot be hidden by the final sample");
        RecoverBenefit old_spike(256*MiB,0);old_spike.update(64*MiB,0);
        for(int t=2;t<=300;t+=2)old_spike.update((t==180?250:64)*MiB,t);
        check(old_spike.retained_last_minute()&&old_spike.minimum_recent_drop()==192*MiB,"old isolated spike expires from final-minute window");
        RecoverBenefit threshold(256*MiB,0);threshold.update(176*MiB,0);
        for(int t=2;t<=300;t+=2)threshold.update(240*MiB,t);
        check(!threshold.retained_last_minute(),"exactly eighty percent refill cannot qualify");
        RecoverBenefit tiny(256*MiB,0);tiny.update(248*MiB,0);
        for(int t=2;t<=300;t+=2)tiny.update(248*MiB,t);
        check(!tiny.retained_last_minute(),"tiny consistent reduction cannot qualify");
        RecoverGate gate;
        check(gate.allowed(10,100,60,false),"initial gate"); gate.attempt(10,100,60); gate.succeeded();
        check(!gate.allowed(10,100,120,false),"same identity once");
        check(!gate.allowed(11,100,119,false),"global cooldown");
        check(!gate.allowed(11,100,120,true),"one feedback window");
        check(gate.allowed(11,100,120,false),"next identity"); gate.attempt(11,100,120); gate.succeeded();
        check(gate.allowed(10,101,180,false),"PID reuse independent"); gate.attempt(10,101,180); gate.succeeded();
        check(!gate.allowed(12,100,240,false),"maximum three");
        check(std::string(recover_reason(false,true,false,true,true,true,true,false,60,256*MiB,200*MiB,true))=="eligible","explicit single test bypasses only pressure");
        check(std::string(recover_reason(false,true,true,true,true,true,true,false,60,256*MiB,200*MiB,true))=="foreground_family","single test protects foreground");
        check(std::string(recover_reason(false,true,false,true,true,true,true,false,59,256*MiB,200*MiB,true))=="low_activity_under_60_seconds","single test retains quiet interval");
        check(std::string(recover_reason(false,true,false,false,true,true,true,false,60,256*MiB,200*MiB,true))=="telemetry_missing","single test retains metrics");
        check(std::string(recover_reason(false,true,false,true,false,true,true,false,60,256*MiB,200*MiB,true))=="owner_or_session","single test retains owner");
        check(std::string(recover_reason(false,true,false,true,true,false,true,false,60,256*MiB,200*MiB,true))=="owner_or_session","single test retains session");
        check(std::string(recover_reason(false,true,false,true,true,true,false,false,60,256*MiB,200*MiB,true))=="critical_or_unknown","single test retains critical-known");
        check(std::string(recover_reason(false,true,false,true,true,true,true,true,60,256*MiB,200*MiB,true))=="critical_or_unknown","single test retains critical exclusion");
        check(std::string(recover_reason(false,true,false,true,true,true,true,false,60,3ULL*1024*MiB,200*MiB,true))=="target_over_2_GiB","single test retains size ceiling");
        check(std::string(recover_reason(false,true,false,true,true,true,true,false,60,256*MiB,100*MiB,true))=="private_resident_below_128_MiB","single test retains private threshold");
        RecoverGate single(1);
        check(single.allowed(10,100,60,false),"single first action");single.attempt(10,100,60);single.succeeded();
        check(single.attempted()&&!single.allowed(11,200,120,false),"single maximum one action");
        RecoverGate failed(1);failed.attempt(10,100,60);
        check(failed.attempted()&&!failed.allowed(10,100,120,false),"failed attempt cannot retry");
        RecoverGate stopped; stopped.disable(); check(!stopped.allowed(10,100,0,false),"disabled cannot mutate");
        std::cout<<"PASS "<<checks<<" recovery policy checks\n";
    } catch(const std::exception& e) { std::cerr<<"FAIL "<<e.what()<<'\n'; return 1; }
}
