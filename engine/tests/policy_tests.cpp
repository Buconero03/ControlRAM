#include "../src/policy.hpp"
#include "../src/protocol.hpp"
#include "../src/native_policy.hpp"
#include "../src/browser_identity.hpp"
#include <iostream>
#include <stdexcept>
#include <limits>

static int checks = 0;
static void check(bool ok, const char* name) { ++checks; if (!ok) throw std::runtime_error(name); }
int main() {
    using namespace ame;
    try {
        const wchar_t* chrome_args[]{L"host.exe",ame_browser_origin};
        const wchar_t* firefox_args[]{L"host.exe",L"D:/AME/firefox-native-host.json",ame_firefox_id};
        const wchar_t* wrong_id[]{L"host.exe",L"manifest.json",L"other@example.org"};
        const wchar_t* wrong_origin[]{L"host.exe",L"chrome-extension://other/"};
        check(ame_browser_launch_allowed(2,chrome_args,false),"Chrome origin retained");
        check(ame_browser_launch_allowed(3,firefox_args,true),"Firefox identity and exact manifest accepted");
        check(!ame_browser_launch_allowed(3,firefox_args,false),"Firefox moved manifest rejected");
        check(!ame_browser_launch_allowed(3,wrong_id,true),"Firefox unknown extension rejected");
        check(!ame_browser_launch_allowed(2,wrong_origin,true),"Chrome unknown origin rejected");
        check(!ame_browser_launch_allowed(2,firefox_args,true),"Firefox missing ID rejected");
        check(!ame_browser_launch_allowed(0,nullptr,true),"Missing native args rejected");
        const SystemSample high{16000 * MiB, 500 * MiB, 10000 * MiB, 24000 * MiB};
        const SystemSample normal{16000 * MiB, 4000 * MiB, 10000 * MiB, 24000 * MiB};
        PressurePolicy p;
        check(p.update(normal, 0) == Phase::normal, "normal");
        check(p.update(high, 2) == Phase::pending, "transient high");
        for (int t = 4; t <= 16; t += 2) check(p.update(high, t) == Phase::pending, "persistence");
        check(p.update(high, 18) == Phase::pressure, "persistent pressure");
        auto middle = high; middle.available = 1500 * MiB;
        check(p.update(middle, 20) == Phase::pressure, "hysteresis");
        check(p.update(normal, 22) == Phase::normal, "exit pressure");
        check(p.update(high, 24) == Phase::pending, "new interval");
        check(p.update(normal, 26) == Phase::normal, "reset transient");
        check(p.update(high, 28) == Phase::pending, "reset timer");
        check(p.update(high, 100) == Phase::unknown, "sampling gap invalidates persistence");
        check(p.update(high, 102) == Phase::pending, "sampling resume");
        check(p.update(high, 101) == Phase::unknown, "backward clock");
        check(p.update({}, 104) == Phase::unknown, "missing metrics");
        auto bad = high; bad.available = bad.total + 1;
        check(p.update(bad, 106) == Phase::unknown, "invalid available");
        auto commit = normal; commit.commit = 23000 * MiB;
        check(p.update(commit, 108) == Phase::pending, "commit pressure independent of physical RAM");
        PressurePolicy cache_policy;
        auto cached = normal; cached.cache = 9000 * MiB;
        check(cache_policy.update(cached, 0) == Phase::normal, "cache is not extra pressure");
        ActionGate gate; AgentStatus agent{10, 128 * MiB, 0, 1.0};
        check(!gate.allowed(Phase::pressure, false, agent, 0), "observe cannot mutate");
        check(!gate.allowed(Phase::pending, true, agent, 0), "transient cannot mutate");
        check(gate.allowed(Phase::pressure, true, agent, 0), "valid opt in");
        gate.action_started(0);
        check(!gate.allowed(Phase::pressure, true, agent, 59), "cooldown");
        check(gate.allowed(Phase::pressure, true, agent, 60), "cooldown expiry");
        auto busy = agent; busy.latency_ms = 21;
        check(!gate.allowed(Phase::pressure, true, busy, 61), "latency guard");
        busy.latency_ms = std::numeric_limits<double>::quiet_NaN();
        check(!gate.allowed(Phase::pressure, true, busy, 61), "invalid latency");
        busy = agent; busy.cache_bytes = 0;
        check(!gate.allowed(Phase::pressure, true, busy, 61), "empty cache");
        gate.disable();
        check(!gate.allowed(Phase::pressure, true, agent, 120), "disable further requests");
        check(!feedback_degraded(2, 4), "good feedback");
        check(feedback_degraded(2, 21), "absolute regression");
        check(feedback_degraded(15, 31), "relative regression");
        auto reply = parse_agent_reply("AME1 OK 12 134217728 67108864 1.25\n");
        check(reply.pid == 12 && reply.released_bytes == 64 * MiB, "protocol valid");
        for (const auto& invalid : {"AME1 OK -1 0 0 0", "AME1 OK 0 0 0 0", "AME1 OK 1 0 67108865 0", "AME1 OK 1 0 0 nan", "AME1 OK 1 0 0 1.2.3", "AME1 OK 1 0 0 0 extra", "AME2 OK 1 0 0 0", "AME1 ERR auth"}) {
            bool rejected = false;
            try { (void)parse_agent_reply(invalid); } catch (const std::exception&) { rejected = true; }
            check(rejected, "invalid protocol rejected");
        }
        NativePressure native;
        auto balanced = normal; balanced.available = balanced.total / 5;
        check(!native.update(balanced, 0), "native pressure needs persistence");
        for (int t = 2; t <= 14; t += 2) check(!native.update(balanced, t), "native transient pressure");
        check(native.update(balanced, 16), "native threshold 80 percent sustained");
        auto hysteresis = normal; hysteresis.available = hysteresis.total * 23 / 100;
        check(native.update(hysteresis, 18), "native pressure hysteresis 77 percent");
        auto recovered = normal; recovered.available = 4500 * MiB;
        check(!native.update(recovered, 20), "native recovery below 75 percent");
        check(!native.update(balanced, 22), "native new episode");
        check(!native.update(balanced, 100), "native sample gap fails closed");
        check(!native.update(balanced, 98), "native invalid sampling reset");
        check(!native.update({}, 102), "native missing telemetry");
        std::vector<Identity> family{
            {1, 0, 1, "explorer", false, true}, {2, 1, 2, "browser", false},
            {3, 2, 3, "renderer", true}, {4, 2, 4, "browser", false},
            {5, 4, 5, "helper", false}, {6, 1, 6, "other", false},
            {7, 0, 7, "browser", false}, {8, 2, 1, "old-parent-pid", false}};
        const auto protected_ids = foreground_family(family);
        for (unsigned id : {2U, 3U, 4U, 5U, 7U}) check(protected_ids.count(id) == 1, "foreground tree and siblings");
        for (unsigned id : {1U, 6U, 8U}) check(protected_ids.count(id) == 0, "launcher and stale parent excluded");
        // Reproduce the diagnostic chain: Chrome -> cmd/conhost, with the same
        // shell images also used by Claude and CoinPoker. Shared shell images
        // must not turn independent applications into one foreground family.
        const std::vector<Identity> shared_shells{
            {1, 0, 1, "explorer.exe", false, true},
            {2, 1, 2, "chrome.exe", true}, {3, 2, 3, "chrome.exe", false},
            {4, 2, 4, "cmd.exe", false, true}, {5, 4, 5, "conhost.exe", false, true},
            {6, 1, 6, "claude.exe", false}, {7, 6, 7, "claude.exe", false},
            {8, 6, 8, "cmd.exe", false, true}, {9, 8, 9, "conhost.exe", false, true},
            {10, 1, 10, "CoinPoker.exe", false}, {11, 10, 11, "CoinPoker Bridge.exe", false},
            {12, 11, 12, "conhost.exe", false, true}};
        const auto chrome_active=foreground_family(shared_shells);
        for(unsigned id:{2U,3U,4U,5U})check(chrome_active.count(id)==1,"active browser and its actual descendants stay protected");
        for(unsigned id:{1U,6U,7U,8U,9U,10U,11U,12U})check(chrome_active.count(id)==0,"cmd/conhost must not bridge unrelated applications");
        auto poker_rows=shared_shells;poker_rows[1].foreground=false;poker_rows[9].foreground=true;
        const auto poker_active=foreground_family(poker_rows);
        for(unsigned id:{10U,11U,12U})check(poker_active.count(id)==1,"active poker root and helpers stay protected");
        for(unsigned id:{2U,3U,4U,5U,6U,7U,8U,9U})check(poker_active.count(id)==0,"foreground protection does not cross console instances");
        for(const auto* shell:{"powershell.exe","pwsh.exe","cmd.exe","conhost.exe","windowsterminal.exe"}){
            const std::vector<Identity> shells{
                {20,0,20,shell,true,true}, {21,20,21,"active-child.exe",false},
                {22,0,22,shell,false,true}, {23,22,23,"independent.exe",false}};
            const auto shell_active=foreground_family(shells);
            for(unsigned id:{20U,21U})check(shell_active.count(id)==1,"foreground shell protects its own branch");
            for(unsigned id:{22U,23U})check(shell_active.count(id)==0,"same shell image does not protect independent branch");
        }
        auto stale_shells=shared_shells;stale_shells[4].creation=1;
        check(foreground_family(stale_shells).count(5)==0,"reused parent does not protect stale console child");
        check(native_candidate(true, true, false, true, true, false, 30, 128 * MiB), "native eligible");
        check(!native_candidate(false, true, false, true, true, false, 30, 128 * MiB), "native healthy memory unchanged");
        check(!native_candidate(true, false, false, true, true, false, 30, 128 * MiB), "native opt in image required");
        check(!native_candidate(true, true, true, true, true, false, 30, 128 * MiB), "native foreground excluded");
        check(!native_candidate(true, true, false, false, true, false, 30, 128 * MiB), "native unknown telemetry excluded");
        check(!native_candidate(true, true, false, true, false, false, 30, 128 * MiB), "native unknown critical status excluded");
        check(!native_candidate(true, true, false, true, true, true, 30, 128 * MiB), "native critical excluded");
        check(!native_candidate(true, true, false, true, true, false, 29, 128 * MiB), "native needs background stability");
        check(!native_candidate(true, true, false, true, true, false, 30, 127 * MiB), "native small processes excluded");
        check(!native_regression(0.2, 50, 10), "native benign feedback");
        check(native_regression(1, 0, 0), "native resumed activity");
        check(native_regression(0, 501, 10), "native page fault guard");
        check(!native_regression(0, 550, 200), "native relative fault baseline");
        check(native_regression(0, 601, 200), "native relative fault regression");
        std::cout << "PASS " << checks << " policy/protocol/native checks\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << "FAIL: " << e.what() << '\n'; return 1; }
}
