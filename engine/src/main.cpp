// Windows 10/11 x64. The observer never requests PROCESS_TERMINATE or VM_WRITE.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include "policy.hpp"
#include "protocol.hpp"
#include "native_policy.hpp"
#include "recover_policy.hpp"
#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <thread>
#include <vector>
#include <cstdlib>
#include <cwctype>
#include <set>
#include <memory>
#include <cstring>

static_assert(sizeof(void*) == 8, "Build the x64 target: use vcvars64 or MinGW-w64 x86_64.");

namespace {
using Clock = std::chrono::steady_clock;
std::atomic<bool> stop{false};
BOOL WINAPI control(DWORD event) {
    if (event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT) { stop.store(true); return TRUE; }
    return FALSE;
}
struct Handle {
    HANDLE value = nullptr;
    explicit Handle(HANDLE h) : value(h) {}
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle(const Handle&) = delete; Handle& operator=(const Handle&) = delete;
};
std::uint64_t ticks(const FILETIME& t) {
    return (static_cast<std::uint64_t>(t.dwHighDateTime) << 32U) | t.dwLowDateTime;
}
std::string utf8(const wchar_t* str) {
    const int n = WideCharToMultiByte(CP_UTF8, 0, str, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return {};
    std::string s(static_cast<std::size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, str, -1, s.data(), n, nullptr, nullptr);
    s.pop_back(); return s;
}
std::string quote(const std::string& value) {
    std::ostringstream o; o << '"';
    for (unsigned char c : value) {
        if (c == '\\' || c == '"') o << '\\' << static_cast<char>(c);
        else if (c < 32) o << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<unsigned>(c) << std::dec;
        else o << static_cast<char>(c);
    }
    o << '"'; return o.str();
}
ame::SystemSample sample_system() {
    PERFORMANCE_INFORMATION p{}; p.cb = sizeof(p);
    if (!GetPerformanceInfo(&p, sizeof(p))) throw std::runtime_error("GetPerformanceInfo failed: " + std::to_string(GetLastError()));
    const auto bytes = [page = static_cast<std::uint64_t>(p.PageSize)](SIZE_T n) { return static_cast<std::uint64_t>(n) * page; };
    return {bytes(p.PhysicalTotal), bytes(p.PhysicalAvailable), bytes(p.CommitTotal), bytes(p.CommitLimit),
        bytes(p.SystemCache), bytes(p.KernelPaged), bytes(p.KernelNonpaged)};
}
struct CountersEx2 { PROCESS_MEMORY_COUNTERS_EX base; SIZE_T private_ws; ULONG64 shared_commit; };
bool same_user(HANDLE target);
struct Process {
    DWORD pid = 0, parent = 0, session = 0;
    bool own_user = false;
    std::string name;
    std::wstring image;
    std::uint64_t creation = 0, cpu_ticks = 0, ws = 0, private_ws = 0, commit = 0;
    DWORD faults = 0;
    bool memory_known = false, private_ws_known = false, cpu_known = false, rate_known = false;
    bool foreground = false, critical_known = false, critical = false;
    double cpu_percent = 0, faults_per_second = 0, low_activity_seconds = 0;
};
struct History { std::uint64_t creation, cpu; DWORD faults; bool cpu_known, memory_known; double time, low_activity; };
bool process_critical(HANDLE process, PBOOL critical) {
    using CriticalFn = BOOL(WINAPI*)(HANDLE, PBOOL);
    static CriticalFn fn = []() {
        const auto symbol = GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "IsProcessCritical");
        CriticalFn result = nullptr;
        static_assert(sizeof(result) == sizeof(symbol), "Windows function pointer size");
        std::memcpy(&result, &symbol, sizeof(result));
        return result;
    }();
    return fn && fn(process, critical) != FALSE;
}
class Collector {
    std::map<DWORD, History> previous_;
    unsigned processors_ = 1;
    bool strict_ = false;
public:
    explicit Collector(bool strict = false) : strict_(strict) { SYSTEM_INFO s{}; GetSystemInfo(&s); processors_ = std::max(1UL, s.dwNumberOfProcessors); }
    std::vector<Process> capture(double now) {
        Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
        if (snapshot.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Process snapshot failed");
        DWORD foreground = 0; GetWindowThreadProcessId(GetForegroundWindow(), &foreground);
        std::map<DWORD, History> next;
        std::vector<Process> out;
        PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
        if (!Process32FirstW(snapshot.value, &entry)) return out;
        do {
            Process p; p.pid = entry.th32ProcessID; p.parent = entry.th32ParentProcessID;
            p.name = utf8(entry.szExeFile); p.foreground = foreground != 0 && p.pid == foreground;
            Handle h(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, p.pid));
            if (h.value) {
                p.own_user = same_user(h.value);
                ProcessIdToSessionId(p.pid, &p.session);
                std::wstring image(32768, L'\0'); DWORD image_size = static_cast<DWORD>(image.size());
                if (QueryFullProcessImageNameW(h.value, 0, image.data(), &image_size)) {
                    image.resize(image_size);
                    for (auto& c : image) c = static_cast<wchar_t>(std::towlower(c));
                    p.image = std::move(image);
                }
                FILETIME created{}, exited{}, kernel{}, user{};
                if (GetProcessTimes(h.value, &created, &exited, &kernel, &user)) {
                    p.creation = ticks(created); p.cpu_ticks = ticks(kernel) + ticks(user); p.cpu_known = true;
                }
                BOOL critical = FALSE;
                if (process_critical(h.value, &critical)) { p.critical_known = true; p.critical = critical != FALSE; }
                CountersEx2 m{}; m.base.cb = sizeof(m);
                if (GetProcessMemoryInfo(h.value, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&m), sizeof(m))) {
                    p.private_ws_known = m.private_ws <= m.base.WorkingSetSize;
                    p.private_ws = p.private_ws_known ? m.private_ws : 0;
                    p.memory_known = true;
                } else {
                    m = {}; m.base.cb = sizeof(m.base);
                    p.memory_known = GetProcessMemoryInfo(h.value, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&m.base), sizeof(m.base)) != FALSE;
                }
                if (p.memory_known) { p.ws = m.base.WorkingSetSize; p.commit = m.base.PrivateUsage; p.faults = m.base.PageFaultCount; }
            }
            auto old = previous_.find(p.pid);
            if (old != previous_.end() && p.creation && old->second.creation == p.creation) {
                const double dt = now - old->second.time;
                if (dt > 0 && dt <= 6 && p.cpu_known && old->second.cpu_known && p.memory_known && old->second.memory_known && p.cpu_ticks >= old->second.cpu) {
                    p.rate_known = true;
                    p.cpu_percent = static_cast<double>(p.cpu_ticks - old->second.cpu) / 1e7 / dt / processors_ * 100.0;
                    p.faults_per_second = static_cast<double>(static_cast<DWORD>(p.faults - old->second.faults)) / dt;
                    if (!p.foreground && p.cpu_percent < (strict_ ? 0.1 : 0.5) && p.faults_per_second < (strict_ ? 10.0 : 100.0))
                        p.low_activity_seconds = old->second.low_activity + dt;
                }
            }
            next.emplace(p.pid, History{p.creation, p.cpu_ticks, p.faults, p.cpu_known, p.memory_known, now, p.low_activity_seconds});
            out.push_back(std::move(p));
        } while (Process32NextW(snapshot.value, &entry));
        previous_ = std::move(next);
        std::sort(out.begin(), out.end(), [](const Process& a, const Process& b) { return a.ws > b.ws; });
        return out;
    }
};
#include "priority_lease.hpp"
#include "priority_tests.hpp"
#include "recover_controller.hpp"
#include "recover_tests.hpp"
std::string read_token(const std::filesystem::path& path) {
    std::ifstream in(path); std::string s;
    if (!in || !std::getline(in, s)) throw std::runtime_error("Token file not readable");
    if (!s.empty() && s.back() == '\r') s.pop_back();
    if (s.size() != 64 || s.find_first_not_of("0123456789abcdef") != std::string::npos)
        throw std::runtime_error("Invalid token file (expected 64 lowercase hex digits)");
    return s;
}
class AgentClient {
    unsigned short port_;
    std::string token_;
public:
    AgentClient(unsigned short port, std::string token) : port_(port), token_(std::move(token)) {}
    ame::AgentStatus request(bool release) const {
        SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) throw std::runtime_error("Agent socket failed");
        struct Cleanup { SOCKET s; ~Cleanup() { closesocket(s); } } cleanup{s};
        u_long nonblocking = 1;
        if (ioctlsocket(s, FIONBIO, &nonblocking) != 0) throw std::runtime_error("Agent nonblocking setup failed");
        sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_port = htons(port_); addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == SOCKET_ERROR) {
            if (WSAGetLastError() != WSAEWOULDBLOCK) throw std::runtime_error("Agent not reachable");
            fd_set writable, errors; FD_ZERO(&writable); FD_ZERO(&errors); FD_SET(s, &writable); FD_SET(s, &errors);
            timeval timeout{1, 0};
            if (select(0, nullptr, &writable, &errors, &timeout) <= 0 || FD_ISSET(s, &errors)) throw std::runtime_error("Agent connect timeout");
            int error = 0, size = sizeof(error);
            if (getsockopt(s, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &size) != 0 || error) throw std::runtime_error("Agent connect failed");
        }
        nonblocking = 0;
        if (ioctlsocket(s, FIONBIO, &nonblocking) != 0) throw std::runtime_error("Agent blocking setup failed");
        DWORD timeout = 1500;
        if (setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout)) != 0 ||
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout)) != 0)
            throw std::runtime_error("Agent timeout setup failed");
        const std::string message = "AME1 " + token_ + (release ? " RECLAIM 67108864\n" : " STATUS 0\n");
        std::size_t sent = 0;
        while (sent < message.size()) {
            const int n = send(s, message.data() + sent, static_cast<int>(message.size() - sent), 0);
            if (n <= 0) throw std::runtime_error("Agent send failed");
            sent += static_cast<std::size_t>(n);
        }
        std::string reply;
        const auto deadline = Clock::now() + std::chrono::seconds(2);
        while (reply.size() < 512 && Clock::now() < deadline) {
            char buffer[512]; int n = recv(s, buffer, static_cast<int>(sizeof(buffer)), 0);
            if (n <= 0) throw std::runtime_error("Agent reply timeout or disconnect");
            reply.append(buffer, static_cast<std::size_t>(n));
            const auto newline = reply.find('\n');
            if (newline != std::string::npos) {
                if (newline != reply.size() - 1) throw std::runtime_error("Unexpected extra reply");
                return ame::parse_agent_reply(reply, release ? 64 * ame::MiB : 0);
            }
        }
        throw std::runtime_error("Agent oversized/incomplete reply");
    }
};
struct Options { bool cooperative = false, optimize = false, recover = false, single_test = false, inventory = false; std::vector<std::wstring> allowed; std::vector<std::pair<std::uint32_t,std::uint64_t>> instances; unsigned seconds = 120; unsigned short port = 0; std::filesystem::path token, stop_file, report = L"ame-report.jsonl"; };
unsigned integer(const std::string& value, unsigned max) {
    if (value.empty() || value.find_first_not_of("0123456789") != std::string::npos) throw std::runtime_error("Invalid integer option");
    const auto n = std::stoul(value); if (!n || n > max) throw std::runtime_error("Option outside range"); return static_cast<unsigned>(n);
}
Options parse(int argc, wchar_t** argv) {
    Options o; bool observe = false;
    for (int i = 1; i < argc; ++i) {
        const auto arg = utf8(argv[i]);
        if (arg == "--help") {
            std::cout << "AdvancedMemoryEngine 0.5.0\n"
                "ame.exe [--observe | --cooperative | --optimize | --recover | --recover-test] [--seconds 120] [--report path.jsonl]\n"
                "        [--agent-port PORT --token-file PATH] [--allow-exe FULL_PATH (repeatable)]\n"
                "Default: read-only. Optimize: leased memory priorities for selected background apps.\n"
                "Recover: selected PID:creation identities, single-process resident trim, no allocation release.\n"
                "Recover-test: exactly one selected identity, one attempt, no pressure requirement, other guards unchanged.\n"
                "        --allow-process PID:creation_filetime (repeatable); --inventory for 10-second process snapshots.\n"
                "Cooperative: releases only agent-registered cache. Optional --stop-file PATH.\n";
            std::exit(0);
        } else if (arg == "--observe") observe = true;
        else if (arg == "--cooperative") o.cooperative = true;
        else if (arg == "--optimize") o.optimize = true;
        else if (arg == "--recover") { if(o.single_test)throw std::runtime_error("Choose one recovery mode"); o.recover = true; }
        else if (arg == "--recover-test") { if(o.recover)throw std::runtime_error("Choose one recovery mode"); o.recover = true; o.single_test = true; }
        else if (arg == "--inventory") o.inventory = true;
        else if (i + 1 < argc && arg == "--allow-exe") {
            std::filesystem::path image(argv[++i]);
            if (!valid_selected_image(image)) throw std::runtime_error("allow-exe must be an absolute .exe path: " + image.u8string());
            o.allowed.push_back(lower_image(image.wstring()));
        }
        else if (i + 1 < argc && arg == "--allow-process") o.instances.push_back(ame::selected_identity(utf8(argv[++i])));
        else if (i + 1 < argc && arg == "--seconds") o.seconds = integer(utf8(argv[++i]), 86400);
        else if (i + 1 < argc && arg == "--agent-port") o.port = static_cast<unsigned short>(integer(utf8(argv[++i]), 65535));
        else if (i + 1 < argc && arg == "--token-file") o.token = argv[++i];
        else if (i + 1 < argc && arg == "--stop-file") o.stop_file = argv[++i];
        else if (i + 1 < argc && arg == "--report") o.report = argv[++i];
        else throw std::runtime_error("Unknown or incomplete option: " + arg);
    }
    if (static_cast<int>(observe) + static_cast<int>(o.cooperative) + static_cast<int>(o.optimize) + static_cast<int>(o.recover) > 1) throw std::runtime_error("Choose one mode");
    if ((o.port != 0) != !o.token.empty()) throw std::runtime_error("Agent requires both port and token file");
    if (o.cooperative && !o.port) throw std::runtime_error("Cooperative mode requires a configured agent");
    if ((o.optimize || o.recover) && o.allowed.empty()) throw std::runtime_error("Mutation mode requires at least one --allow-exe");
    if (!o.optimize && !o.recover && !o.allowed.empty()) throw std::runtime_error("allow-exe requires optimize or recover mode");
    if (o.recover && o.instances.empty()) throw std::runtime_error("Recover requires explicit --allow-process PID:creation_filetime identities");
    if (!o.recover && !o.instances.empty()) throw std::runtime_error("allow-process requires recover mode");
    if (o.single_test && (o.instances.size()!=1 || o.allowed.size()!=1 || o.seconds>180)) throw std::runtime_error("Recover-test requires one identity, one image and at most 180 seconds");
    return o;
}
}
int wmain(int argc, wchar_t** argv) {
    try {
        if (argc >= 2 && std::wstring(argv[1]) == L"--priority-watch") return priority_watch(argc, argv);
        if (argc == 2 && std::wstring(argv[1]) == L"--test-priority-lease") return test_priority_lease();
        if (argc >= 2 && std::wstring(argv[1]) == L"--test-owner-exit") return test_owner_exit(argc, argv);
        if (argc == 2 && std::wstring(argv[1]) == L"--test-recovery") return test_recovery();
        const auto options = parse(argc, argv);
        WSADATA wsa{};
        if (WSAStartup(MAKEWORD(2, 2), &wsa)) throw std::runtime_error("WSAStartup failed");
        struct WsaCleanup { ~WsaCleanup() { WSACleanup(); } } wsa_cleanup;
        SetConsoleCtrlHandler(control, TRUE);
        std::ofstream report(options.report, std::ios::out | std::ios::trunc);
        if (!report) throw std::runtime_error("Report not writable");
        std::optional<AgentClient> agent;
        if (options.port) agent.emplace(options.port, read_token(options.token));
        Collector collector(options.recover); ame::PressurePolicy policy; ame::ActionGate gate;
        std::unique_ptr<NativeController> native;
        if (options.optimize) native = std::make_unique<NativeController>(options.allowed, report);
        std::unique_ptr<RecoverController> recovery;
        if (options.recover) recovery = std::make_unique<RecoverController>(options.allowed, options.instances, report, options.single_test);
        struct Pending { double time, latency; ame::SystemSample before; std::uint64_t released; };
        std::optional<Pending> feedback;
        std::optional<std::uint32_t> expected_pid;
        const auto start = Clock::now();
        auto next = start;
        unsigned iteration = 0;
        SetConsoleOutputCP(CP_UTF8);
        std::cout << "AdvancedMemoryEngine 0.5.0 - " << (options.single_test ? "ONE SELECTED PROCESS / ONE ATTEMPT / MEASURED TEST" : options.recover ? "WINDOWS CONTROLLED RESIDENT MEMORY RECOVERY" : options.optimize ? "WINDOWS MEMORY PRIORITY CONTROLLER" : options.cooperative ? "COOPERATIVE CACHE ONLY" : "OBSERVE / NO MEMORY CHANGES") << "\nCtrl+C: stop. Report: " << options.report.u8string() << '\n';
        while (!stop.load()) {
            const double now = std::chrono::duration<double>(Clock::now() - start).count();
            if (!ame::recover_observation_allowed(now,options.seconds,recovery&&recovery->feedback_pending()) ||
                (!options.stop_file.empty() && std::filesystem::exists(options.stop_file))) break;
            const auto system = sample_system(); const auto phase = policy.update(system, now);
            auto processes = collector.capture(now);
            report << std::fixed << std::setprecision(3) << "{\"type\":\"sample\",\"elapsed_seconds\":" << now << ",\"phase\":" << quote(ame::phase_name(phase))
                << ",\"physical_total_bytes\":" << system.total << ",\"physical_available_bytes\":" << system.available
                << ",\"commit_bytes\":" << system.commit << ",\"commit_limit_bytes\":" << system.commit_limit
                << ",\"system_cache_bytes\":" << system.cache << ",\"kernel_paged_bytes\":" << system.kernel_paged
                << ",\"kernel_nonpaged_bytes\":" << system.kernel_nonpaged << ",\"processes\":[";
            const bool complete_snapshot = options.inventory || options.recover ? iteration % 5 == 0 : !options.optimize || iteration % 30 == 0;
            bool first = true;
            for (const auto& p : processes) {
                if (!complete_snapshot) break;
                if (!first) report << ',';
                first = false;
                report << "{\"pid\":" << p.pid << ",\"parent_pid\":" << p.parent << ",\"name\":" << quote(p.name)
                    << ",\"image_path\":" << quote(utf8(p.image.c_str())) << ",\"same_user\":" << (p.own_user ? "true" : "false") << ",\"session_id\":" << p.session
                    << ",\"creation_filetime\":\"" << p.creation << "\",\"memory_available\":" << (p.memory_known ? "true" : "false")
                    << ",\"working_set_bytes\":" << p.ws << ",\"private_working_set_bytes\":";
                if (p.private_ws_known) report << p.private_ws; else report << "null";
                report << ",\"private_commit_bytes\":" << p.commit << ",\"foreground_window_owner\":" << (p.foreground ? "true" : "false")
                    << ",\"cpu_percent\":";
                if (p.rate_known) report << p.cpu_percent; else report << "null";
                report << ",\"page_faults_per_second\":";
                if (p.rate_known) report << p.faults_per_second; else report << "null";
                report << ",\"low_activity_seconds\":" << p.low_activity_seconds << ",\"critical\":";
                if (p.critical_known) report << (p.critical ? "true" : "false"); else report << "null";
                report << '}';
            }
            report << "],\"process_snapshot_complete\":" << (complete_snapshot ? "true" : "false") << "}\n";
            std::cout << std::fixed << std::setprecision(1) << '[' << std::setw(6) << now << "s] RAM " << system.used_percent()
                << "% | available " << system.available / ame::MiB << " MB | commit " << system.commit_percent()
                << "% | " << ame::phase_name(phase) << '\n';
            if (iteration++ % 5 == 0) {
                std::cout << "    PID        WS_MB   private_commit_MB  CPU%  process (no reclaim estimate)\n";
                unsigned count = 0;
                for (const auto& p : processes) {
                    if (!p.memory_known) continue;
                    std::cout << "    " << std::setw(7) << p.pid << std::setw(10) << p.ws / ame::MiB << std::setw(20) << p.commit / ame::MiB << "  ";
                    if (p.rate_known) std::cout << std::setw(5) << p.cpu_percent; else std::cout << "  N/D";
                    std::cout << "  " << p.name << (p.foreground ? " [foreground]" : "") << '\n';
                    if (++count == 8) break;
                }
            }
            if (native) native->update(system, processes, now);
            if (recovery) recovery->update(system, processes, now,now<options.seconds);
            if (agent && !gate.disabled()) {
                try {
                    const auto status = agent->request(false);
                    if (expected_pid && *expected_pid != status.pid) throw std::runtime_error("Agent identity changed; restart controller");
                    expected_pid = status.pid;
                    if (feedback && now - feedback->time >= 15.0) {
                        const bool degraded = ame::feedback_degraded(feedback->latency, status.latency_ms);
                        if (degraded) gate.disable();
                        const auto available_delta = static_cast<std::int64_t>(system.available) - static_cast<std::int64_t>(feedback->before.available);
                        const auto commit_delta = static_cast<std::int64_t>(system.commit) - static_cast<std::int64_t>(feedback->before.commit);
                        report << "{\"type\":\"feedback\",\"elapsed_seconds\":" << now << ",\"pid\":" << status.pid
                            << ",\"agent_released_bytes\":" << feedback->released << ",\"system_available_delta_bytes\":" << available_delta
                            << ",\"system_commit_delta_bytes\":" << commit_delta << ",\"latency_ms\":" << status.latency_ms
                            << ",\"further_actions_disabled\":" << (degraded ? "true" : "false") << "}\n";
                        std::cout << "    Feedback: released cache " << feedback->released / ame::MiB << " MB; system available delta " << available_delta / static_cast<std::int64_t>(ame::MiB)
                            << " MB (not proof of causation). Latency " << status.latency_ms << " ms" << (degraded ? " - further requests disabled" : "") << '\n';
                        feedback.reset();
                    }
                    if (gate.allowed(phase, options.cooperative, status, now) && !feedback) {
                        gate.action_started(now);
                        const auto result = agent->request(true);
                        if (result.pid != status.pid) throw std::runtime_error("Agent identity changed during request");
                        feedback = Pending{now, status.latency_ms, system, result.released_bytes};
                        report << "{\"type\":\"cooperative_release\",\"elapsed_seconds\":" << now << ",\"pid\":" << result.pid << ",\"released_bytes\":" << result.released_bytes << "}\n";
                        std::cout << "    Cooperative agent released " << result.released_bytes / ame::MiB << " MB of registered cache.\n";
                    }
                } catch (const std::exception& e) {
                    // If a reply is lost, the agent may have applied the request.
                    // Disable instead of retrying an ambiguous mutation.
                    gate.disable();
                    report << "{\"type\":\"agent_error\",\"elapsed_seconds\":" << now << ",\"message\":" << quote(e.what()) << ",\"further_actions_disabled\":true}\n";
                    std::cout << "    Agent disabled: " << e.what() << '\n';
                }
            }
            report.flush(); if (!report) throw std::runtime_error("Report write failed");
            if (recovery && recovery->finished()) break;
            next += std::chrono::seconds(2);
            if (next < Clock::now()) next = Clock::now();
            while (!stop.load() && Clock::now() < next) std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (native) native->shutdown(std::chrono::duration<double>(Clock::now() - start).count());
        if (recovery) recovery->shutdown(std::chrono::duration<double>(Clock::now() - start).count());
        report << "{\"type\":\"end\",\"feedback_pending\":" << (feedback ? "true" : "false") << "}\n";
        report.flush(); if (!report) throw std::runtime_error("Final report write failed");
        return 0;
    } catch (const std::exception& e) { std::cerr << "ERROR: " << e.what() << '\n'; return 1; }
}
