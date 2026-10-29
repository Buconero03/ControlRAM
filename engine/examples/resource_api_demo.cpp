#include <windows.h>
#include "../sdk/ame_resource_api.h"
#include "../src/resource_trace.hpp"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr uint64_t MiB = 1048576;
unsigned checks = 0;
ame::resource::Trace* trace = nullptr;
AmeResult traced(const char* expression, AmeResult status) {
    const auto windows_error = AmeGetLastWindowsError();
    if (trace) { try { trace->call(expression, status, windows_error); } catch (...) { trace->mark_failed(); } }
    return status;
}
#define AME_TRACE(expression) traced(#expression, (expression))
void check(bool condition, const char* text) {
    ++checks;
    if (trace) trace->check(text, condition);
    if (!condition) throw std::runtime_error(text);
}
void ok(AmeResult r, const char* operation) {
    if (r != AME_OK) throw std::runtime_error(std::string(operation) + ": AME=" +
        std::to_string(r) + ", Windows=" + std::to_string(AmeGetLastWindowsError()));
    ++checks;
}
std::wstring executable() {
    std::wstring path(32768, L'\0');
    const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (!length || length >= path.size()) throw std::runtime_error("GetModuleFileNameW");
    path.resize(length); return path;
}
struct OwnedFixture {
    PROCESS_INFORMATION process{};
    HANDLE input = nullptr, output = nullptr;
    ~OwnedFixture() {
        // Cleanup targets only process handles returned by this fixture's CreateProcessW.
        if (input) { const char command = 'Q'; DWORD sent = 0; WriteFile(input, &command, 1, &sent, nullptr); CloseHandle(input); }
        if (process.hProcess) {
            if (WaitForSingleObject(process.hProcess, 3000) == WAIT_TIMEOUT) {
                TerminateProcess(process.hProcess, 1); WaitForSingleObject(process.hProcess, 1000);
            }
            CloseHandle(process.hProcess);
        }
        if (process.hThread) CloseHandle(process.hThread);
        if (output) CloseHandle(output);
    }
    void read(void* data, DWORD count) {
        const auto deadline = GetTickCount64() + 3000;
        DWORD available = 0;
        while (GetTickCount64() < deadline) {
            if (!PeekNamedPipe(output, nullptr, 0, nullptr, &available, nullptr)) throw std::runtime_error("Fixture pipe closed");
            if (available >= count) {
                DWORD received = 0;
                if (ReadFile(output, data, count, &received, nullptr) && received == count) return;
                throw std::runtime_error("Fixture read failed");
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        throw std::runtime_error("Fixture response timed out");
    }
    void send(char command) {
        DWORD sent = 0;
        if (!WriteFile(input, &command, 1, &sent, nullptr) || sent != 1) throw std::runtime_error("Fixture write failed");
    }
    void ready() { char value = 0; read(&value, 1); check(value == 'R', "fixture allocation succeeded"); }
    void start() {
        SECURITY_ATTRIBUTES attributes{sizeof(attributes), nullptr, TRUE};
        HANDLE child_input = nullptr, child_output = nullptr;
        if (!CreatePipe(&child_input, &input, &attributes, 0)) throw std::runtime_error("CreatePipe stdin");
        if (!CreatePipe(&output, &child_output, &attributes, 0)) { CloseHandle(child_input); throw std::runtime_error("CreatePipe stdout"); }
        if (!SetHandleInformation(input, HANDLE_FLAG_INHERIT, 0) || !SetHandleInformation(output, HANDLE_FLAG_INHERIT, 0)) {
            CloseHandle(child_input); CloseHandle(child_output); throw std::runtime_error("SetHandleInformation");
        }
        STARTUPINFOW startup{}; startup.cb = sizeof(startup); startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = child_input; startup.hStdOutput = child_output; startup.hStdError = child_output;
        std::wstring command = L"\"" + executable() + L"\" --fixture";
        BOOL parent_in_job = FALSE;
        if (!IsProcessInJob(GetCurrentProcess(), nullptr, &parent_in_job)) {
            CloseHandle(child_input); CloseHandle(child_output); throw std::runtime_error("IsProcessInJob parent");
        }
        const DWORD flags = CREATE_NO_WINDOW | (parent_in_job ? CREATE_BREAKAWAY_FROM_JOB : 0);
        BOOL created = CreateProcessW(nullptr, command.data(), nullptr, nullptr, TRUE, flags, nullptr, nullptr, &startup, &process);
        if (!created && parent_in_job && GetLastError() == ERROR_ACCESS_DENIED) {
            std::wstring retry_cmd = L"\"" + executable() + L"\" --fixture";
            created = CreateProcessW(nullptr, retry_cmd.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
        }
        const DWORD error = GetLastError();
        CloseHandle(child_input); CloseHandle(child_output);
        if (!created) throw std::runtime_error("Fixture creation failed (host job may forbid breakaway): " + std::to_string(error));
        ready();
    }
    void exit() { send('Q'); check(WaitForSingleObject(process.hProcess, 3000) == WAIT_OBJECT_0, "fixture exits cooperatively"); }
};
int fixture() {
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE), output = GetStdHandle(STD_OUTPUT_HANDLE);
    std::vector<void*> allocations;
    PROCESS_INFORMATION leaf{};
    struct Cleanup {
        std::vector<void*>& blocks; PROCESS_INFORMATION& child;
        ~Cleanup() {
            for (void* block : blocks) VirtualFree(block, 0, MEM_RELEASE);
            if (child.hProcess) { TerminateProcess(child.hProcess, 0); WaitForSingleObject(child.hProcess, 1000); CloseHandle(child.hProcess); }
            if (child.hThread) CloseHandle(child.hThread);
        }
    } cleanup{allocations, leaf};
    const auto allocate = [&](SIZE_T bytes) {
        void* block = VirtualAlloc(nullptr, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (!block) return false;
        allocations.push_back(block);
        std::memset(block, 0x5a, bytes);
        char ready = 'R'; DWORD written = 0;
        return WriteFile(output, &ready, 1, &written, nullptr) && written == 1;
    };
    if (!allocate(8 * MiB)) return 2;
    char command = 0; DWORD received = 0;
    while (ReadFile(input, &command, 1, &received, nullptr) && received == 1) {
        if (command == 'Q') return 0;
        if (command == 'G' && !allocate(64 * MiB)) return 3;
        if (command == 'C') {
            STARTUPINFOW startup{}; startup.cb = sizeof(startup);
            std::wstring line = L"\"" + executable() + L"\" --leaf";
            if (!CreateProcessW(nullptr, line.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &leaf)) return 4;
            DWORD written = 0;
            if (!WriteFile(output, &leaf.dwProcessId, sizeof(leaf.dwProcessId), &written, nullptr) || written != sizeof(leaf.dwProcessId)) return 5;
        }
    }
    return 0;
}
std::unique_ptr<AmeProcessIdentity> identity(DWORD pid) {
    auto value = std::make_unique<AmeProcessIdentity>(); value->size = sizeof(*value);
    ok(AME_TRACE(AmeReadProcessIdentity(pid, value.get())), "AmeReadProcessIdentity");
    if (trace) trace->process(value->pid, value->creation_filetime);
    return value;
}
AmeGroupSnapshot snapshot(AmeGroup group) {
    AmeGroupSnapshot s{}; s.size = sizeof(s);
    ok(AME_TRACE(AmeReadGroupSnapshot(group, &s)), "AmeReadGroupSnapshot");
    if (trace) trace->snapshot("sample", group, s);
    return s;
}
void run(bool quiet) {
    if (trace) trace->phase("contract");
    check(AmeGetApiVersion() == AME_RESOURCE_ABI_VERSION, "DLL ABI version");
    check(AME_TRACE(AmeCreateGroup(nullptr)) == AME_INVALID_ARGUMENT, "null group output rejected");
    auto value = std::make_unique<AmeProcessIdentity>();
    check(AME_TRACE(AmeReadProcessIdentity(0, value.get())) == AME_INVALID_ARGUMENT, "invalid identity rejected");
    value->size = sizeof(*value);
    check(AME_TRACE(AmeReadProcessIdentity(0xffffffffu, value.get())) == AME_WINDOWS_ERROR && AmeGetLastWindowsError() != 0,
          "Win32 errors are available through the public API");
    check(AME_TRACE(AmeCreateGroup(nullptr)) == AME_INVALID_ARGUMENT && AmeGetLastWindowsError() == 0,
          "new argument failure clears stale Windows error");
    AmeGroup group = 0; ok(AME_TRACE(AmeCreateGroup(&group)), "AmeCreateGroup");
    struct Close { AmeGroup& id; ~Close() { if (id) AME_TRACE(AmeCloseGroup(id)); } } close{group};
    check(AME_TRACE(AmeAttachProcess(group, nullptr)) == AME_INVALID_ARGUMENT, "null attachment rejected");
    auto own = identity(GetCurrentProcessId());
    check(AME_TRACE(AmeAttachProcess(group, own.get())) == AME_PROCESS_EXCLUDED, "controller cannot attach itself");
    check(AME_TRACE(AmeSetCommitNotice(group, 1)) == AME_INVALID_ARGUMENT, "tiny threshold rejected");
    check(AME_TRACE(AmeSetCommitNotice(group, (uint64_t{1} << 40u) + 1)) == AME_INVALID_ARGUMENT, "oversized threshold rejected");
    AmeGroupSnapshot wrong{};
    check(AME_TRACE(AmeReadGroupSnapshot(group, &wrong)) == AME_INVALID_ARGUMENT, "ABI size mismatch rejected");
    AmeGroupEvent event{}; event.size = sizeof(event);
    check(AME_TRACE(AmePollGroupEvent(group, &event)) == AME_NO_EVENT, "empty completion port is nonblocking");
    auto empty = snapshot(group);
    check(empty.active_processes == 0 && (empty.flags & AME_MEMORY_COMPLETE), "new group is empty");

    if (trace) trace->phase("identity");
    OwnedFixture first; first.start(); value = identity(first.process.dwProcessId);
    auto changed = std::make_unique<AmeProcessIdentity>(*value); ++changed->creation_filetime;
    check(AME_TRACE(AmeAttachProcess(group, changed.get())) == AME_IDENTITY_CHANGED, "wrong creation time refused");
    *changed = *value; changed->image_path[0] = changed->image_path[0] == L'X' ? L'Y' : L'X';
    check(AME_TRACE(AmeAttachProcess(group, changed.get())) == AME_IDENTITY_CHANGED, "wrong executable path refused");
    *changed = *value; std::fill_n(changed->image_path, AME_RESOURCE_PATH_CAPACITY, L'X');
    check(AME_TRACE(AmeAttachProcess(group, changed.get())) == AME_INVALID_ARGUMENT, "unterminated path refused");
    check(snapshot(group).active_processes == 0, "rejected identities have no attachment side effect");
    ok(AME_TRACE(AmeAttachProcess(group, value.get())), "AmeAttachProcess");
    check(AME_TRACE(AmeAttachProcess(group, value.get())) == AME_ALREADY_MANAGED, "duplicate attachment refused");
    auto before = snapshot(group);
    if (trace) trace->snapshot("before_growth", group, before);
    check(before.active_processes == 1 && before.measured_processes == 1 &&
          (before.flags & AME_MEMORY_COMPLETE) && before.private_commit_sum_bytes >= 8 * MiB,
          "actual child private commit measured");
    check(!(before.flags & AME_RATES_VALID), "first measurement has no invented rates");
    if (trace) trace->phase("memory_notice");
    ok(AME_TRACE(AmeSetCommitNotice(group, 32 * MiB)), "AmeSetCommitNotice");
    first.send('G'); first.ready();
    const auto deadline = GetTickCount64() + 3000;
    bool noticed = false;
    while (GetTickCount64() < deadline && !noticed) {
        event = {}; event.size = sizeof(event);
        const auto status = AME_TRACE(AmePollGroupEvent(group, &event));
        if (trace && status == AME_OK) trace->event(group, event);
        check(status == AME_OK || status == AME_NO_EVENT, "kernel event polling succeeds");
        if (status == AME_OK && event.kind == AME_EVENT_COMMIT_NOTICE) {
            check(event.job_commit_bytes > event.commit_notice_bytes && event.commit_notice_bytes == 32 * MiB,
                  "real Windows commit notification includes exceeded threshold");
            noticed = true;
        }
        if (!noticed) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    check(noticed, "kernel memory notification delivered");
    auto after = snapshot(group);
    if (trace) trace->snapshot("after_growth", group, after);
    check(after.private_commit_sum_bytes >= before.private_commit_sum_bytes + 60 * MiB &&
          (after.flags & AME_COMMIT_NOTICE_EXCEEDED), "allocation beyond notice remains permitted");
    check(WaitForSingleObject(first.process.hProcess, 0) == WAIT_TIMEOUT, "notification does not terminate application");
    bool saw_rates = false;
    for (unsigned i = 0; i < 6; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        const auto measured = snapshot(group);
        saw_rates |= (measured.flags & AME_RATES_VALID) && measured.rate_interval_ms >= 1000;
    }
    check(saw_rates, "frequent reads preserve a baseline long enough to produce real rates");
    if (!quiet) {
        std::cout << "API AME nativa + Job Object Windows\n"
                  << "Processo demo: " << first.process.dwProcessId << "\n"
                  << "Memoria privata assegnata: " << before.private_commit_sum_bytes / MiB << " -> "
                  << after.private_commit_sum_bytes / MiB << " MiB\n"
                  << "Avviso Windows ricevuto oltre 32 MiB. Processo ancora attivo.\n"
                  << "Questa demo verifica gestione e misure; non esegue una riduzione RAM.\n";
    }
    if (trace) trace->phase("lifecycle");
    // Test existing-job compatibility without adding a nested job or overriding it.
    AmeGroup other = 0; ok(AME_TRACE(AmeCreateGroup(&other)), "second group");
    check(AME_TRACE(AmeAttachProcess(other, value.get())) == AME_ALREADY_MANAGED, "existing job is preserved");
    ok(AME_TRACE(AmeCloseGroup(other)), "close second group");
    first.send('C'); DWORD leaf_pid = 0; first.read(&leaf_pid, sizeof(leaf_pid));
    auto leaf = identity(leaf_pid);
    ok(AME_TRACE(AmeAttachProcess(group, leaf.get())), "child is outside group until explicitly attached");
    auto two = snapshot(group);
    check(two.active_processes == 2 && two.measured_processes == 2 && !(two.flags & AME_RATES_VALID),
          "new explicit member invalidates previous rates");
    uint64_t self_released = 0;
    check(AME_TRACE(AmeCompactCurrentProcess(4 * MiB, nullptr)) == AME_INVALID_ARGUMENT, "null compact output rejected");
    ok(AME_TRACE(AmeCompactCurrentProcess(4 * MiB, &self_released)), "AmeCompactCurrentProcess");
    AmeReclaimResult reclaim_res{}; reclaim_res.size = sizeof(reclaim_res);
    check(AME_TRACE(AmeExecuteProcessReclaim(value.get(), 0, &reclaim_res)) == AME_INVALID_ARGUMENT, "zero stage flags rejected");
    ok(AME_TRACE(AmeExecuteProcessReclaim(value.get(), AME_STAGE_MEMORY_PRIORITY | AME_STAGE_WORKING_SET_TRIM, &reclaim_res)), "AmeExecuteProcessReclaim");
    check((reclaim_res.applied_stages & AME_STAGE_WORKING_SET_TRIM) != 0 && reclaim_res.working_set_before_bytes > 0, "staged process reclaim applied");
    uint64_t group_reclaimed = 0; uint32_t group_affected = 0;
    ok(AME_TRACE(AmeReclaimGroupBudget(group, 16 * MiB, AME_STAGE_MEMORY_PRIORITY | AME_STAGE_WORKING_SET_TRIM, &group_reclaimed, &group_affected)), "AmeReclaimGroupBudget");
    check(group_affected >= 1, "distributed group budget reclaim affected members");
    ok(AME_TRACE(AmeRestoreProcess(value.get())), "AmeRestoreProcess");
    uint32_t restored_all = 0;
    ok(AME_TRACE(AmeRestoreAllProcesses(&restored_all)), "AmeRestoreAllProcesses");
    uint64_t comp_bytes = 0;
    ok(AME_TRACE(AmeGetMemoryCompressionBytes(&comp_bytes)), "AmeGetMemoryCompressionBytes");
    uint64_t pulse_freed = 0;
    ok(AME_TRACE(AmePulseFlushMemory(64 * MiB, &pulse_freed)), "AmePulseFlushMemory");
    ok(AME_TRACE(AmeSetCommitNotice(group, 0)), "disable notification");
    check(snapshot(group).commit_notice_bytes == 0, "notification removed");
    const auto old_id = group;
    ok(AME_TRACE(AmeCloseGroup(group)), "AmeCloseGroup"); group = 0;
    check(WaitForSingleObject(first.process.hProcess, 0) == WAIT_TIMEOUT, "closing group leaves application alive");
    BOOL still_managed = FALSE;
    check(IsProcessInJob(first.process.hProcess, nullptr, &still_managed) && still_managed,
          "closing monitoring does not claim to detach a live process");
    wrong = {}; wrong.size = sizeof(wrong);
    check(AME_TRACE(AmeReadGroupSnapshot(old_id, &wrong)) == AME_INVALID_GROUP && wrong.active_processes == 0,
          "closed handle refused with cleared output");
    check(AME_TRACE(AmeCloseGroup(old_id)) == AME_INVALID_GROUP, "double close refused");
    first.exit();
    // Exited identity remains distinguishable; no operation can hit a reused PID.
    AmeGroup fresh = 0; ok(AME_TRACE(AmeCreateGroup(&fresh)), "new group");
    check(fresh != old_id, "group IDs are never reused");
    const auto dead_status = AME_TRACE(AmeAttachProcess(fresh, value.get()));
    check(dead_status == AME_IDENTITY_CHANGED || dead_status == AME_WINDOWS_ERROR, "exited process refused");
    ok(AME_TRACE(AmeCloseGroup(fresh)), "close new group");
    if (trace) trace->phase("capacity");
    std::vector<AmeGroup> capacity;
    for (uint32_t i = 0; i < AME_RESOURCE_MAX_GROUPS; ++i) {
        AmeGroup id = 0; ok(AME_TRACE(AmeCreateGroup(&id)), "bounded group creation"); capacity.push_back(id);
    }
    AmeGroup excess = 123;
    check(AME_TRACE(AmeCreateGroup(&excess)) == AME_CAPACITY_REACHED && excess == 0, "group capacity bound");
    for (const auto id : capacity) ok(AME_TRACE(AmeCloseGroup(id)), "bounded group cleanup");
    std::cout << "PASS " << checks << " native API / real Windows job checks\n";
}
}
int wmain(int argc, wchar_t** argv) {
    if (argc == 2 && std::wstring(argv[1]) == L"--fixture") return fixture();
    if (argc == 2 && std::wstring(argv[1]) == L"--leaf") { Sleep(30000); return 0; }
    bool quiet = false;
    std::filesystem::path journal_path;
    for (int i = 1; i < argc; ++i) {
        const std::wstring option = argv[i];
        if (option == L"--self-test" && !quiet) quiet = true;
        else if (option == L"--trace-json" && journal_path.empty() && i + 1 < argc) journal_path = argv[++i];
        else { std::cerr << "Usage: ame-resource-demo.exe [--self-test] [--trace-json FILE]\n"; return 2; }
    }
    ame::resource::Trace journal;
    try {
        if (!journal_path.empty()) {
            journal.open(journal_path); trace = &journal;
            if (!journal.healthy()) throw std::runtime_error("Cannot start API execution journal");
        }
        run(quiet);
        if (trace) trace->finish(true, checks);
        if (trace && !trace->healthy()) throw std::runtime_error("API operations completed but execution journal could not be saved");
        trace = nullptr;
        return 0;
    } catch (const std::exception& e) {
        if (trace) { try { trace->finish(false, checks, e.what()); } catch (...) {} }
        trace = nullptr;
        std::cerr << "FAIL " << e.what() << '\n'; return 1;
    }
}
