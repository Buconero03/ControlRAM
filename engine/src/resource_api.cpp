#include <windows.h>
#include <psapi.h>
#include "../sdk/ame_resource_api.h"
#include "resource_analysis.hpp"
#include <algorithm>
#include <cwchar>
#include <cstring>
#include <limits>
#include <malloc.h>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <set>
#include <string>
#include <string_view>
#include <vector>

static_assert(sizeof(void*) == 8 && sizeof(wchar_t) == 2, "Windows x64 ABI required");
static_assert(sizeof(AmeProcessIdentity) == 65552, "Identity ABI layout");
static_assert(sizeof(AmeGroupSnapshot) == 144, "Snapshot ABI layout");
static_assert(sizeof(AmeGroupEvent) == 48, "Event ABI layout");
static_assert(sizeof(AmeReclaimResult) == 64, "Reclaim result ABI layout");

namespace {
thread_local DWORD last_error = ERROR_SUCCESS;
AmeResult result(AmeResult code, DWORD error = ERROR_SUCCESS) { last_error = error; return code; }

typedef LONG NTSTATUS;
#ifndef NT_SUCCESS
#define NT_SUCCESS(Status) (((NTSTATUS)(Status)) >= 0)
#endif
#define STATUS_INFO_LENGTH_MISMATCH ((NTSTATUS)0xC0000004L)

typedef struct _AME_UNICODE_STRING {
    USHORT Length;
    USHORT MaximumLength;
    PWSTR Buffer;
} AME_UNICODE_STRING;

typedef struct _AME_SYSTEM_PROCESS_INFORMATION {
    ULONG NextEntryOffset;
    ULONG NumberOfThreads;
    LARGE_INTEGER WorkingSetPrivateSize;
    ULONG HardFaultCount;
    ULONG NumberOfThreadsHighWatermark;
    ULONGLONG CycleTime;
    LARGE_INTEGER CreateTime;
    LARGE_INTEGER UserTime;
    LARGE_INTEGER KernelTime;
    AME_UNICODE_STRING ImageName;
    LONG BasePriority;
    HANDLE UniqueProcessId;
    HANDLE InheritedFromUniqueProcessId;
    ULONG HandleCount;
    ULONG SessionId;
    ULONG_PTR UniqueProcessKey;
    SIZE_T PeakVirtualSize;
    SIZE_T VirtualSize;
    ULONG PageFaultCount;
    SIZE_T PeakWorkingSetSize;
    SIZE_T WorkingSetSize;
    SIZE_T QuotaPeakPagedPoolUsage;
    SIZE_T QuotaPagedPoolUsage;
    SIZE_T QuotaPeakNonPagedPoolUsage;
    SIZE_T QuotaNonPagedPoolUsage;
    SIZE_T PagefileUsage;
    SIZE_T PeakPagefileUsage;
    SIZE_T PrivatePageCount;
    LARGE_INTEGER ReadOperationCount;
    LARGE_INTEGER WriteOperationCount;
    LARGE_INTEGER OtherOperationCount;
    LARGE_INTEGER ReadTransferCount;
    LARGE_INTEGER WriteTransferCount;
    LARGE_INTEGER OtherTransferCount;
} AME_SYSTEM_PROCESS_INFORMATION;

typedef NTSTATUS (NTAPI *pfnNtQuerySystemInformation)(
    ULONG SystemInformationClass,
    PVOID SystemInformation,
    ULONG SystemInformationLength,
    PULONG ReturnLength
);
struct Handle {
    HANDLE value = nullptr;
    explicit Handle(HANDLE h = nullptr) : value(h) {}
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    Handle(Handle&& other) noexcept : value(other.value) { other.value = nullptr; }
    Handle& operator=(Handle&& other) noexcept {
        if (this != &other) {
            if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value);
            value = other.value; other.value = nullptr;
        }
        return *this;
    }
};
struct Group {
    Handle job, port;
    std::vector<Handle> members;
    uint64_t notice = 0, membership = 0, policy = 0;
    AmeGroupSnapshot previous{};
    bool has_previous = false;
};
// All calls are short/nonblocking and serialized. No worker thread or callback.
std::mutex registry_mutex;
std::map<AmeGroup, std::unique_ptr<Group>> groups;
std::set<std::pair<uint32_t, uint64_t>> attached_history;
std::map<std::pair<uint32_t, uint64_t>, std::wstring> modified_processes;
struct ClampedProcessInfo {
    uint32_t pid = 0;
    uint64_t creation = 0;
    std::wstring image_path;
    uint64_t max_bytes = 0;
    SIZE_T orig_min = 0;
    SIZE_T orig_max = 0;
    DWORD orig_flags = 0;
};
std::map<std::pair<uint32_t, uint64_t>, ClampedProcessInfo> clamped_processes;
AmeGroup next_id = 1;

template<class F> AmeResult boundary(F&& operation) noexcept {
    try { std::lock_guard<std::mutex> lock(registry_mutex); return operation(); }
    catch (const std::bad_alloc&) { return result(AME_WINDOWS_ERROR, ERROR_NOT_ENOUGH_MEMORY); }
    catch (...) { return result(AME_WINDOWS_ERROR, ERROR_GEN_FAILURE); }
}
uint64_t ticks(const FILETIME& f) {
    return (static_cast<uint64_t>(f.dwHighDateTime) << 32u) | f.dwLowDateTime;
}
AmeResult read_identity(HANDLE process, DWORD pid, AmeProcessIdentity& identity) {
    FILETIME creation{}, exit{}, kernel{}, user{};
    if (!GetProcessTimes(process, &creation, &exit, &kernel, &user))
        return result(AME_WINDOWS_ERROR, GetLastError());
    std::vector<wchar_t> path(AME_RESOURCE_PATH_CAPACITY);
    DWORD length = static_cast<DWORD>(path.size());
    if (!QueryFullProcessImageNameW(process, 0, path.data(), &length))
        return result(AME_WINDOWS_ERROR, GetLastError());
    if (!length || length >= AME_RESOURCE_PATH_CAPACITY) return result(AME_WINDOWS_ERROR, ERROR_BUFFER_OVERFLOW);
    identity = {};
    identity.size = sizeof(identity); identity.pid = pid; identity.creation_filetime = ticks(creation);
    std::copy_n(path.data(), length, identity.image_path);
    return result(AME_OK);
}
bool valid_identity(const AmeProcessIdentity* identity) {
    return identity && identity->size == sizeof(*identity) && identity->pid && identity->creation_filetime &&
        identity->image_path[0] && std::wmemchr(identity->image_path, L'\0', AME_RESOURCE_PATH_CAPACITY);
}
bool same_path(const wchar_t* a, const wchar_t* b) {
    return CompareStringOrdinal(a, -1, b, -1, TRUE) == CSTR_EQUAL;
}
AmeResult owner_and_session(HANDLE process, DWORD pid) {
    DWORD own_session = 0, target_session = 0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &own_session) || !ProcessIdToSessionId(pid, &target_session))
        return result(AME_WINDOWS_ERROR, GetLastError());
    if (own_session != target_session) return result(AME_PROCESS_EXCLUDED);
    HANDLE own_raw = nullptr, target_raw = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &own_raw)) return result(AME_WINDOWS_ERROR, GetLastError());
    Handle own(own_raw);
    if (!OpenProcessToken(process, TOKEN_QUERY, &target_raw)) return result(AME_WINDOWS_ERROR, GetLastError());
    Handle target(target_raw);
    DWORD own_size = 0, target_size = 0;
    GetTokenInformation(own.value, TokenUser, nullptr, 0, &own_size);
    GetTokenInformation(target.value, TokenUser, nullptr, 0, &target_size);
    if (!own_size || !target_size || own_size > 65536 || target_size > 65536)
        return result(AME_WINDOWS_ERROR, ERROR_INVALID_DATA);
    std::vector<unsigned char> own_data(own_size), target_data(target_size);
    if (!GetTokenInformation(own.value, TokenUser, own_data.data(), own_size, &own_size) ||
        !GetTokenInformation(target.value, TokenUser, target_data.data(), target_size, &target_size))
        return result(AME_WINDOWS_ERROR, GetLastError());
    if (!EqualSid(reinterpret_cast<TOKEN_USER*>(own_data.data())->User.Sid,
                  reinterpret_cast<TOKEN_USER*>(target_data.data())->User.Sid)) return result(AME_PROCESS_EXCLUDED);
    return result(AME_OK);
}
bool is_core_excluded_basename(const wchar_t* path) {
    if (!path) return true;
    const wchar_t* base = path;
    for (const wchar_t* p = path; *p; ++p) {
        if (*p == L'\\' || *p == L'/') base = p + 1;
    }
    static const wchar_t* const core_names[] = {
        L"csrss.exe", L"lsass.exe", L"smss.exe", L"services.exe",
        L"wininit.exe", L"winlogon.exe", L"dwm.exe", L"explorer.exe",
        L"svchost.exe", L"sihost.exe", L"taskhostw.exe", L"RuntimeBroker.exe",
        L"TextInputHost.exe", L"StartMenuExperienceHost.exe", L"ShellHost.exe",
        L"ShellExperienceHost.exe", L"ApplicationFrameHost.exe", L"dllhost.exe",
        L"fontdrvhost.exe", L"ctfmon.exe", L"conhost.exe"
    };
    for (const wchar_t* name : core_names) {
        if (CompareStringOrdinal(base, -1, name, -1, TRUE) == CSTR_EQUAL) return true;
    }
    return false;
}
AmeResult check_process(HANDLE process, const AmeProcessIdentity& identity, bool strict_windows_dir = true) {
    if (identity.pid <= 4 || identity.pid == GetCurrentProcessId()) return result(AME_PROCESS_EXCLUDED);
    const DWORD wait = WaitForSingleObject(process, 0);
    if (wait == WAIT_OBJECT_0) return result(AME_IDENTITY_CHANGED);
    if (wait != WAIT_TIMEOUT) return result(AME_WINDOWS_ERROR, GetLastError());
    const auto ownership = owner_and_session(process, identity.pid);
    if (ownership != AME_OK) return ownership;
    BOOL critical = FALSE;
    using CriticalFunction = BOOL(WINAPI*)(HANDLE, PBOOL);
    const auto symbol = GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "IsProcessCritical");
    CriticalFunction is_critical = nullptr;
    static_assert(sizeof(is_critical) == sizeof(symbol), "Windows function pointer size");
    std::memcpy(&is_critical, &symbol, sizeof(symbol));
    if (!is_critical) return result(AME_WINDOWS_ERROR, ERROR_PROC_NOT_FOUND);
    if (!is_critical(process, &critical)) return result(AME_WINDOWS_ERROR, GetLastError());
    if (critical) return result(AME_PROCESS_EXCLUDED);
    if (is_core_excluded_basename(identity.image_path)) return result(AME_PROCESS_EXCLUDED);
    if (strict_windows_dir) {
        wchar_t windows[MAX_PATH]{};
        const UINT length = GetWindowsDirectoryW(windows, MAX_PATH);
        if (!length || length >= MAX_PATH) return result(AME_WINDOWS_ERROR, ERROR_INVALID_DATA);
        const std::wstring prefix = std::wstring(windows) + L"\\";
        const std::size_t path_length = std::wcslen(identity.image_path);
        if (path_length >= prefix.size() &&
            CompareStringOrdinal(identity.image_path, static_cast<int>(prefix.size()), prefix.data(),
                                 static_cast<int>(prefix.size()), TRUE) == CSTR_EQUAL)
            return result(AME_PROCESS_EXCLUDED);
    }
    return result(AME_OK);
}
Group* find_group(AmeGroup id) {
    const auto found = groups.find(id);
    return found == groups.end() ? nullptr : found->second.get();
}
bool add(uint64_t& sum, uint64_t value) {
    if (value > std::numeric_limits<uint64_t>::max() - sum) return false;
    sum += value; return true;
}
AmeResult set_notice(Group& group, uint64_t bytes) {
    JOBOBJECT_NOTIFICATION_LIMIT_INFORMATION notice{};
    if (bytes) { notice.LimitFlags = JOB_OBJECT_LIMIT_JOB_MEMORY; notice.JobMemoryLimit = bytes; }
    if (!SetInformationJobObject(group.job.value, JobObjectNotificationLimitInformation, &notice, sizeof(notice)))
        return result(AME_WINDOWS_ERROR, GetLastError());
    group.notice = bytes; ++group.policy;
    return result(AME_OK);
}
AmeInternalReclaimCallback internal_handler = nullptr;
void* internal_context = nullptr;

DWORD current_foreground_pid() {
    using GetFgFn = HWND(WINAPI*)(void);
    using GetTidFn = DWORD(WINAPI*)(HWND, LPDWORD);
    HMODULE u32 = GetModuleHandleW(L"user32.dll");
    if (!u32) u32 = LoadLibraryW(L"user32.dll");
    if (!u32) return 0;
    const auto fg_sym = GetProcAddress(u32, "GetForegroundWindow");
    const auto tid_sym = GetProcAddress(u32, "GetWindowThreadProcessId");
    GetFgFn get_fg = nullptr; GetTidFn get_tid = nullptr;
    static_assert(sizeof(get_fg) == sizeof(fg_sym) && sizeof(get_tid) == sizeof(tid_sym), "Function pointer size");
    std::memcpy(&get_fg, &fg_sym, sizeof(get_fg));
    std::memcpy(&get_tid, &tid_sym, sizeof(get_tid));
    if (!get_fg || !get_tid) return 0;
    const HWND hwnd = get_fg();
    if (!hwnd) return 0;
    DWORD pid = 0;
    get_tid(hwnd, &pid);
    return pid;
}

uint64_t compact_current_process_internal(uint64_t requested) {
    uint64_t callback_freed = 0;
    if (internal_handler) {
        try { callback_freed = internal_handler(requested, internal_context); } catch (...) {}
    }
    PROCESS_MEMORY_COUNTERS_EX before{}, after{};
    before.cb = sizeof(before); after.cb = sizeof(after);
    const bool had_before = GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&before), sizeof(before)) != FALSE;
    HANDLE heaps[64]{};
    const DWORD count = GetProcessHeaps(64, heaps);
    for (DWORD i = 0; i < std::min<DWORD>(count, 64u); ++i) {
        if (heaps[i]) HeapCompact(heaps[i], 0);
    }
    _heapmin();
    EmptyWorkingSet(GetCurrentProcess());
    const bool had_after = GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&after), sizeof(after)) != FALSE;
    uint64_t ws_drop = 0;
    if (had_before && had_after && before.WorkingSetSize > after.WorkingSetSize) {
        ws_drop = static_cast<uint64_t>(before.WorkingSetSize - after.WorkingSetSize);
    }
    uint64_t total = callback_freed;
    if (!add(total, ws_drop)) total = std::numeric_limits<uint64_t>::max();
    return total;
}

bool restore_process_handle(HANDLE process) {
    MEMORY_PRIORITY_INFORMATION prio{};
    prio.MemoryPriority = MEMORY_PRIORITY_NORMAL; // 5 = Normal Windows Priority
    const BOOL mem_ok = SetProcessInformation(process, ProcessMemoryPriority, &prio, sizeof(prio));
    PROCESS_POWER_THROTTLING_STATE qos{};
    qos.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
    qos.ControlMask = 0;
    qos.StateMask = 0;
    const BOOL qos_ok = SetProcessInformation(process, ProcessPowerThrottling, &qos, sizeof(qos));
    const BOOL prio_ok = SetPriorityClass(process, NORMAL_PRIORITY_CLASS);
    return (mem_ok != FALSE) || (qos_ok != FALSE) || (prio_ok != FALSE);
}

AmeResult apply_stages_to_handle(HANDLE process, uint32_t stage_flags, AmeReclaimResult& out) {
    out = {}; out.size = sizeof(out); out.monotonic_ms = GetTickCount64();
    PROCESS_MEMORY_COUNTERS_EX before{}; before.cb = sizeof(before);
    if (!GetProcessMemoryInfo(process, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&before), sizeof(before)))
        return result(AME_WINDOWS_ERROR, GetLastError());
    out.working_set_before_bytes = before.WorkingSetSize;
    out.private_commit_before_bytes = before.PrivateUsage;
    DWORD last_win_err = ERROR_SUCCESS;
    if (stage_flags & AME_STAGE_COOPERATIVE_CACHE) {
        if (GetProcessId(process) == GetCurrentProcessId()) {
            out.cooperative_released_bytes = compact_current_process_internal(0);
            out.applied_stages |= AME_STAGE_COOPERATIVE_CACHE;
        }
    }
    if (stage_flags & AME_STAGE_MEMORY_PRIORITY) {
        MEMORY_PRIORITY_INFORMATION prio{};
        prio.MemoryPriority = MEMORY_PRIORITY_BELOW_NORMAL;
        if (SetProcessInformation(process, ProcessMemoryPriority, &prio, sizeof(prio)))
            out.applied_stages |= AME_STAGE_MEMORY_PRIORITY;
        else last_win_err = GetLastError();
    }
    if (stage_flags & AME_STAGE_ECO_QOS) {
        PROCESS_POWER_THROTTLING_STATE qos{};
        qos.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
        qos.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
        qos.StateMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
        if (SetProcessInformation(process, ProcessPowerThrottling, &qos, sizeof(qos)))
            out.applied_stages |= AME_STAGE_ECO_QOS;
        else last_win_err = GetLastError();
        SetPriorityClass(process, BELOW_NORMAL_PRIORITY_CLASS);
    }
    if (stage_flags & AME_STAGE_WORKING_SET_TRIM) {
        const BOOL emptied = EmptyWorkingSet(process);
        const BOOL trimmed = SetProcessWorkingSetSizeEx(process, static_cast<SIZE_T>(-1), static_cast<SIZE_T>(-1), 0);
        if (emptied || trimmed)
            out.applied_stages |= AME_STAGE_WORKING_SET_TRIM;
        else last_win_err = GetLastError();
    }
    if (out.applied_stages & (AME_STAGE_MEMORY_PRIORITY | AME_STAGE_ECO_QOS)) {
        AmeProcessIdentity tracked{};
        const DWORD pid = GetProcessId(process);
        if (pid && read_identity(process, pid, tracked) == AME_OK) {
            modified_processes[{tracked.pid, tracked.creation_filetime}] = std::wstring(tracked.image_path);
        }
    }
    PROCESS_MEMORY_COUNTERS_EX after{}; after.cb = sizeof(after);
    if (!GetProcessMemoryInfo(process, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&after), sizeof(after)))
        return result(AME_WINDOWS_ERROR, GetLastError());
    out.working_set_after_bytes = after.WorkingSetSize;
    out.private_commit_after_bytes = after.PrivateUsage;
    out.working_set_delta_bytes = static_cast<int64_t>(out.working_set_after_bytes) - static_cast<int64_t>(out.working_set_before_bytes);
    if (!out.applied_stages) return result(AME_WINDOWS_ERROR, last_win_err ? last_win_err : ERROR_GEN_FAILURE);
    return result(AME_OK);
}
}

uint32_t AME_CALL AmeGetApiVersion(void) { return AME_RESOURCE_ABI_VERSION; }
uint32_t AME_CALL AmeGetLastWindowsError(void) { return last_error; }

AmeResult AME_CALL AmeReadProcessIdentity(uint32_t pid, AmeProcessIdentity* identity) {
    return boundary([&] {
        if (!pid || !identity || identity->size != sizeof(*identity)) return result(AME_INVALID_ARGUMENT);
        *identity = {}; identity->size = sizeof(*identity);
        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid));
        if (!process.value) return result(AME_WINDOWS_ERROR, GetLastError());
        const DWORD wait = WaitForSingleObject(process.value, 0);
        if (wait == WAIT_OBJECT_0) return result(AME_IDENTITY_CHANGED);
        if (wait != WAIT_TIMEOUT) return result(AME_WINDOWS_ERROR, GetLastError());
        return read_identity(process.value, pid, *identity);
    });
}
AmeResult AME_CALL AmeCreateGroup(AmeGroup* output) {
    return boundary([&] {
        if (!output) return result(AME_INVALID_ARGUMENT);
        *output = 0;
        if (groups.size() >= AME_RESOURCE_MAX_GROUPS || next_id == std::numeric_limits<AmeGroup>::max())
            return result(AME_CAPACITY_REACHED);
        auto group = std::make_unique<Group>();
        group->members.reserve(AME_RESOURCE_MAX_MEMBERS);
        group->job = Handle(CreateJobObjectW(nullptr, nullptr));
        if (!group->job.value) return result(AME_WINDOWS_ERROR, GetLastError());
        // Only explicitly attached identities belong to this first API version.
        // Do not inherit membership into newly created descendants.
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        if (!SetInformationJobObject(group->job.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits)))
            return result(AME_WINDOWS_ERROR, GetLastError());
        // CPU Rate Capping: limite hardware del 10% di default per il gruppo in background
        JOBOBJECT_CPU_RATE_CONTROL_INFORMATION rate{};
        rate.ControlFlags = JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP;
        rate.CpuRate = 1000;
        SetInformationJobObject(group->job.value, JobObjectCpuRateControlInformation, &rate, sizeof(rate));
        group->port = Handle(CreateIoCompletionPort(INVALID_HANDLE_VALUE, nullptr, 0, 1));
        if (!group->port.value) return result(AME_WINDOWS_ERROR, GetLastError());
        JOBOBJECT_ASSOCIATE_COMPLETION_PORT port{};
        port.CompletionPort = group->port.value;
        if (!SetInformationJobObject(group->job.value, JobObjectAssociateCompletionPortInformation, &port, sizeof(port)))
            return result(AME_WINDOWS_ERROR, GetLastError());
        const auto id = next_id++;
        groups.emplace(id, std::move(group));
        *output = id; return result(AME_OK);
    });
}
AmeResult set_cpu_rate(Group& group, uint32_t percent) {
    JOBOBJECT_CPU_RATE_CONTROL_INFORMATION rate{};
    if (percent > 0 && percent <= 100) {
        rate.ControlFlags = JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP;
        rate.CpuRate = percent * 100;
    } else {
        rate.ControlFlags = 0;
    }
    if (!SetInformationJobObject(group.job.value, JobObjectCpuRateControlInformation, &rate, sizeof(rate))) {
        const DWORD err = GetLastError();
        if (err != ERROR_NOT_SUPPORTED) return result(AME_WINDOWS_ERROR, err);
    }
    return result(AME_OK);
}
AmeResult AME_CALL AmeSetGroupCpuRate(AmeGroup id, uint32_t max_percent) {
    return boundary([&] {
        if (max_percent > 100) return result(AME_INVALID_ARGUMENT);
        auto* group = find_group(id);
        if (!group) return result(AME_INVALID_GROUP);
        return set_cpu_rate(*group, max_percent);
    });
}
AmeResult AME_CALL AmeAttachProcess(AmeGroup id, const AmeProcessIdentity* identity) {
    return boundary([&] {
        if (!valid_identity(identity)) return result(AME_INVALID_ARGUMENT);
        auto* group = find_group(id);
        if (!group) return result(AME_INVALID_GROUP);
        if (group->members.size() >= AME_RESOURCE_MAX_MEMBERS) return result(AME_CAPACITY_REACHED);
        // AssignProcessToJobObject requires SET_QUOTA and TERMINATE access.
        // TERMINATE is never invoked by this library.
        Handle process(OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE | PROCESS_QUERY_INFORMATION |
                                   PROCESS_VM_READ | SYNCHRONIZE, FALSE, identity->pid));
        if (!process.value) return result(AME_WINDOWS_ERROR, GetLastError());
        AmeProcessIdentity actual{};
        auto status = read_identity(process.value, identity->pid, actual);
        if (status != AME_OK) return status;
        if (actual.creation_filetime != identity->creation_filetime || !same_path(actual.image_path, identity->image_path))
            return result(AME_IDENTITY_CHANGED);
        status = check_process(process.value, actual);
        if (status != AME_OK) return status;
        if (attached_history.count({actual.pid, actual.creation_filetime})) return result(AME_ALREADY_MANAGED);
        BOOL self_in_job = FALSE, managed = FALSE;
        if (!IsProcessInJob(GetCurrentProcess(), nullptr, &self_in_job) ||
            !IsProcessInJob(process.value, nullptr, &managed)) return result(AME_WINDOWS_ERROR, GetLastError());
        if (!self_in_job && managed) return result(AME_ALREADY_MANAGED);
        if (!AssignProcessToJobObject(group->job.value, process.value)) return result(AME_WINDOWS_ERROR, GetLastError());
        attached_history.insert({actual.pid, actual.creation_filetime});
        // Capacity reserved before assigning: no throwing allocation after attachment.
        group->members.push_back(std::move(process));
        ++group->membership; group->has_previous = false;
        return result(AME_OK);
    });
}
AmeResult AME_CALL AmeSetCommitNotice(AmeGroup id, uint64_t bytes) {
    return boundary([&] {
        if (bytes && (bytes < 1048576 || bytes > (uint64_t{1} << 40u))) return result(AME_INVALID_ARGUMENT);
        auto* group = find_group(id);
        if (!group) return result(AME_INVALID_GROUP);
        return set_notice(*group, bytes);
    });
}
AmeResult AME_CALL AmeReadGroupSnapshot(AmeGroup id, AmeGroupSnapshot* output) {
    return boundary([&] {
        if (!output || output->size != sizeof(*output)) return result(AME_INVALID_ARGUMENT);
        *output = {}; output->size = sizeof(*output);
        auto* group = find_group(id);
        if (!group) return result(AME_INVALID_GROUP);
        JOBOBJECT_BASIC_AND_IO_ACCOUNTING_INFORMATION counters{};
        if (!QueryInformationJobObject(group->job.value, JobObjectBasicAndIoAccountingInformation,
                                       &counters, sizeof(counters), nullptr)) return result(AME_WINDOWS_ERROR, GetLastError());
        AmeGroupSnapshot sample{}; sample.size = sizeof(sample);
        sample.monotonic_ms = GetTickCount64();
        sample.attached_total = static_cast<uint32_t>(group->members.size());
        sample.active_processes = counters.BasicInfo.ActiveProcesses;
        sample.commit_notice_bytes = group->notice; sample.membership_revision = group->membership;
        sample.cpu_time_100ns = static_cast<uint64_t>(counters.BasicInfo.TotalKernelTime.QuadPart) +
                              static_cast<uint64_t>(counters.BasicInfo.TotalUserTime.QuadPart);
        sample.page_faults_total = counters.BasicInfo.TotalPageFaultCount;
        sample.io_read_bytes = counters.IoInfo.ReadTransferCount;
        sample.io_write_bytes = counters.IoInfo.WriteTransferCount;
        for (const auto& process : group->members) {
            const DWORD wait = WaitForSingleObject(process.value, 0);
            if (wait == WAIT_OBJECT_0) continue;
            if (wait != WAIT_TIMEOUT) { ++sample.missing_processes; continue; }
            PROCESS_MEMORY_COUNTERS_EX memory{}; memory.cb = sizeof(memory);
            if (!GetProcessMemoryInfo(process.value, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory), sizeof(memory))) {
                ++sample.missing_processes; continue;
            }
            if (!add(sample.working_set_sum_bytes, memory.WorkingSetSize) ||
                !add(sample.private_commit_sum_bytes, memory.PrivateUsage)) return result(AME_WINDOWS_ERROR, ERROR_ARITHMETIC_OVERFLOW);
            ++sample.measured_processes;
        }
        // Processes may exit during capture: never assert an exact complete sample in that case.
        if (!sample.missing_processes && sample.measured_processes == sample.active_processes)
            sample.flags |= AME_MEMORY_COMPLETE;
        if ((sample.flags & AME_MEMORY_COMPLETE) && group->notice && sample.private_commit_sum_bytes > group->notice)
            sample.flags |= AME_COMMIT_NOTICE_EXCEEDED;
        const DWORD processors = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
        ame::resource::calculate_rates(group->has_previous ? &group->previous : nullptr, sample, processors);
        // Keep the baseline when clients read faster than once per second.
        if (!group->has_previous || sample.monotonic_ms - group->previous.monotonic_ms >= 1000 ||
            !(sample.flags & AME_MEMORY_COMPLETE) || !(group->previous.flags & AME_MEMORY_COMPLETE)) {
            group->previous = sample; group->has_previous = true;
        }
        *output = sample; return result(AME_OK);
    });
}
AmeResult AME_CALL AmePollGroupEvent(AmeGroup id, AmeGroupEvent* output) {
    return boundary([&] {
        if (!output || output->size != sizeof(*output)) return result(AME_INVALID_ARGUMENT);
        *output = {}; output->size = sizeof(*output);
        auto* group = find_group(id);
        if (!group) return result(AME_INVALID_GROUP);
        DWORD message = 0; ULONG_PTR key = 0; LPOVERLAPPED data = nullptr;
        if (!GetQueuedCompletionStatus(group->port.value, &message, &key, &data, 0)) {
            const DWORD error = GetLastError();
            return result(error == WAIT_TIMEOUT ? AME_NO_EVENT : AME_WINDOWS_ERROR,
                          error == WAIT_TIMEOUT ? ERROR_SUCCESS : error);
        }
        output->windows_message = message; output->monotonic_ms = GetTickCount64();
        output->policy_revision = group->policy; output->kind = AME_EVENT_OTHER;
        if (message == JOB_OBJECT_MSG_NEW_PROCESS) output->kind = AME_EVENT_PROCESS_STARTED;
        if (message == JOB_OBJECT_MSG_EXIT_PROCESS || message == JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS)
            output->kind = AME_EVENT_PROCESS_EXITED;
        if (message == JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO) output->kind = AME_EVENT_GROUP_EMPTY;
        if (output->kind == AME_EVENT_PROCESS_STARTED || output->kind == AME_EVENT_PROCESS_EXITED)
            output->pid = static_cast<uint32_t>(reinterpret_cast<ULONG_PTR>(data));
        if (message == JOB_OBJECT_MSG_NOTIFICATION_LIMIT) {
            JOBOBJECT_LIMIT_VIOLATION_INFORMATION violation{};
            // Query acknowledges notification and permits the next notification.
            if (!QueryInformationJobObject(group->job.value, JobObjectLimitViolationInformation,
                                           &violation, sizeof(violation), nullptr)) {
                *output = {}; output->size = sizeof(*output);
                return result(AME_WINDOWS_ERROR, GetLastError());
            }
            if (group->notice && (violation.ViolationLimitFlags & JOB_OBJECT_LIMIT_JOB_MEMORY)) {
                output->kind = AME_EVENT_COMMIT_NOTICE;
                output->job_commit_bytes = violation.JobMemory;
                output->commit_notice_bytes = violation.JobMemoryLimit;
            }
        }
        return result(AME_OK);
    });
}
AmeResult AME_CALL AmeCloseGroup(AmeGroup id) {
    return boundary([&] {
        auto* group = find_group(id);
        if (!group) return result(AME_INVALID_GROUP);
        const auto status = set_notice(*group, 0);
        if (status != AME_OK) return status;
        groups.erase(id); return result(AME_OK);
    });
}
AmeResult AME_CALL AmeRegisterInternalProcessHandler(AmeInternalReclaimCallback callback, void* context) {
    return boundary([&] {
        internal_handler = callback;
        internal_context = callback ? context : nullptr;
        return result(AME_OK);
    });
}
AmeResult AME_CALL AmeCompactCurrentProcess(uint64_t requested_bytes, uint64_t* released_bytes) {
    return boundary([&] {
        if (!released_bytes) return result(AME_INVALID_ARGUMENT);
        *released_bytes = compact_current_process_internal(requested_bytes);
        return result(AME_OK);
    });
}
AmeResult AME_CALL AmeExecuteProcessReclaim(const AmeProcessIdentity* identity, uint32_t stage_flags, AmeReclaimResult* output) {
    return boundary([&] {
        const uint32_t valid_mask = AME_STAGE_COOPERATIVE_CACHE | AME_STAGE_MEMORY_PRIORITY | AME_STAGE_ECO_QOS | AME_STAGE_WORKING_SET_TRIM;
        if (!valid_identity(identity) || !output || output->size != sizeof(*output) || !stage_flags || (stage_flags & ~valid_mask)) {
            if (output && output->size == sizeof(*output)) { *output = {}; output->size = sizeof(*output); }
            return result(AME_INVALID_ARGUMENT);
        }
        *output = {}; output->size = sizeof(*output);
        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_INFORMATION |
                                   PROCESS_SET_QUOTA | PROCESS_VM_READ | SYNCHRONIZE, FALSE, identity->pid));
        if (!process.value) return result(AME_WINDOWS_ERROR, GetLastError());
        AmeProcessIdentity actual{};
        auto status = read_identity(process.value, identity->pid, actual);
        if (status != AME_OK) return status;
        if (actual.creation_filetime != identity->creation_filetime || !same_path(actual.image_path, identity->image_path))
            return result(AME_IDENTITY_CHANGED);
        status = check_process(process.value, actual, false);
        if (status != AME_OK) return status;
        const DWORD fg_pid = current_foreground_pid();
        if (fg_pid && fg_pid == identity->pid) return result(AME_PROCESS_EXCLUDED);
        return apply_stages_to_handle(process.value, stage_flags, *output);
    });
}
AmeResult AME_CALL AmeReclaimGroupBudget(AmeGroup id, uint64_t target_reclaim_bytes, uint32_t stage_flags, uint64_t* total_reclaimed_bytes, uint32_t* affected_processes) {
    return boundary([&] {
        const uint32_t valid_mask = AME_STAGE_COOPERATIVE_CACHE | AME_STAGE_MEMORY_PRIORITY | AME_STAGE_ECO_QOS | AME_STAGE_WORKING_SET_TRIM;
        if (!total_reclaimed_bytes || !affected_processes || !stage_flags || (stage_flags & ~valid_mask)) {
            if (total_reclaimed_bytes) *total_reclaimed_bytes = 0;
            if (affected_processes) *affected_processes = 0;
            return result(AME_INVALID_ARGUMENT);
        }
        *total_reclaimed_bytes = 0; *affected_processes = 0;
        auto* group = find_group(id);
        if (!group) return result(AME_INVALID_GROUP);
        const DWORD fg_pid = current_foreground_pid();
        struct Candidate { HANDLE handle; uint64_t ws; };
        std::vector<Candidate> candidates;
        candidates.reserve(group->members.size());
        for (const auto& member : group->members) {
            if (WaitForSingleObject(member.value, 0) != WAIT_TIMEOUT) continue;
            const DWORD pid = GetProcessId(member.value);
            if (!pid || (fg_pid && pid == fg_pid)) continue;
            PROCESS_MEMORY_COUNTERS_EX mem{}; mem.cb = sizeof(mem);
            if (!GetProcessMemoryInfo(member.value, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&mem), sizeof(mem))) continue;
            candidates.push_back({member.value, static_cast<uint64_t>(mem.WorkingSetSize)});
        }
        std::sort(candidates.begin(), candidates.end(), [](const Candidate& a, const Candidate& b) { return a.ws > b.ws; });
        uint64_t reclaimed = 0;
        uint32_t affected = 0;
        for (const auto& c : candidates) {
            if (target_reclaim_bytes && reclaimed >= target_reclaim_bytes) break;
            AmeReclaimResult item{}; item.size = sizeof(item);
            if (apply_stages_to_handle(c.handle, stage_flags, item) == AME_OK) {
                if (affected > 0) {
                    Sleep(60);
                }
                ++affected;
                if (item.working_set_before_bytes > item.working_set_after_bytes) {
                    const uint64_t drop = item.working_set_before_bytes - item.working_set_after_bytes;
                    if (!add(reclaimed, drop)) reclaimed = std::numeric_limits<uint64_t>::max();
                }
            }
        }
        ++group->policy;
        *total_reclaimed_bytes = reclaimed;
        *affected_processes = affected;
        return result(AME_OK);
    });
}
AmeResult AME_CALL AmeRestoreProcess(const AmeProcessIdentity* identity) {
    return boundary([&] {
        if (!valid_identity(identity)) return result(AME_INVALID_ARGUMENT);
        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_INFORMATION | SYNCHRONIZE, FALSE, identity->pid));
        if (!process.value) {
            modified_processes.erase({identity->pid, identity->creation_filetime});
            return result(AME_WINDOWS_ERROR, GetLastError());
        }
        AmeProcessIdentity actual{};
        auto status = read_identity(process.value, identity->pid, actual);
        if (status != AME_OK) return status;
        if (actual.creation_filetime != identity->creation_filetime || !same_path(actual.image_path, identity->image_path)) {
            modified_processes.erase({identity->pid, identity->creation_filetime});
            return result(AME_IDENTITY_CHANGED);
        }
        status = check_process(process.value, actual, false);
        if (status != AME_OK) return status;
        const bool ok = restore_process_handle(process.value);
        modified_processes.erase({actual.pid, actual.creation_filetime});
        return ok ? result(AME_OK) : result(AME_WINDOWS_ERROR, GetLastError());
    });
}
AmeResult AME_CALL AmeRestoreAllProcesses(uint32_t* restored_count) {
    return boundary([&] {
        if (!restored_count) return result(AME_INVALID_ARGUMENT);
        *restored_count = 0;
        uint32_t count = 0;
        for (auto it = modified_processes.begin(); it != modified_processes.end(); ) {
            const uint32_t pid = it->first.first;
            const uint64_t creation = it->first.second;
            const std::wstring& path = it->second;
            Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_INFORMATION | SYNCHRONIZE, FALSE, pid));
            if (process.value) {
                AmeProcessIdentity actual{};
                if (read_identity(process.value, pid, actual) == AME_OK &&
                    actual.creation_filetime == creation &&
                    same_path(actual.image_path, path.c_str())) {
                    if (restore_process_handle(process.value)) ++count;
                }
            }
            it = modified_processes.erase(it);
        }
        for (auto it = clamped_processes.begin(); it != clamped_processes.end(); ) {
            const uint32_t pid = it->first.first;
            const uint64_t creation = it->first.second;
            const std::wstring& path = it->second.image_path;
            Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_QUOTA | PROCESS_SET_INFORMATION | SYNCHRONIZE, FALSE, pid));
            if (process.value) {
                AmeProcessIdentity actual{};
                if (read_identity(process.value, pid, actual) == AME_OK &&
                    actual.creation_filetime == creation &&
                    same_path(actual.image_path, path.c_str())) {
                    MEMORY_PRIORITY_INFORMATION prio{};
                    prio.MemoryPriority = MEMORY_PRIORITY_NORMAL;
                    SetProcessInformation(process.value, ProcessMemoryPriority, &prio, sizeof(prio));
                    SetProcessWorkingSetSizeEx(process.value, static_cast<SIZE_T>(-1), static_cast<SIZE_T>(-1), 0x00000008 /* QUOTA_LIMITS_HARDWS_MAX_DISABLE */);
                    ++count;
                }
            }
            it = clamped_processes.erase(it);
        }
        *restored_count = count;
        return result(AME_OK);
    });
}

AmeResult AME_CALL AmeGetMemoryCompressionBytes(uint64_t* working_set_bytes) {
    return boundary([&] {
        if (!working_set_bytes) return result(AME_INVALID_ARGUMENT);
        *working_set_bytes = 0;
        HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
        if (!ntdll) return result(AME_WINDOWS_ERROR, ERROR_MOD_NOT_FOUND);
        auto query_info = reinterpret_cast<pfnNtQuerySystemInformation>(GetProcAddress(ntdll, "NtQuerySystemInformation"));
        if (!query_info) return result(AME_WINDOWS_ERROR, ERROR_PROC_NOT_FOUND);

        ULONG buf_size = 512 * 1024;
        std::vector<BYTE> buffer;
        NTSTATUS status = STATUS_INFO_LENGTH_MISMATCH;
        ULONG return_len = 0;

        for (int attempt = 0; attempt < 6; ++attempt) {
            buffer.resize(buf_size);
            status = query_info(5 /* SystemProcessInformation */, buffer.data(), buf_size, &return_len);
            if (status == STATUS_INFO_LENGTH_MISMATCH) {
                buf_size = (return_len > buf_size) ? (return_len + 65536) : (buf_size * 2);
            } else {
                break;
            }
        }

        if (!NT_SUCCESS(status)) return result(AME_WINDOWS_ERROR, static_cast<DWORD>(status));

        BYTE* p = buffer.data();
        while (p) {
            auto* spi = reinterpret_cast<AME_SYSTEM_PROCESS_INFORMATION*>(p);
            if (spi->ImageName.Buffer && spi->ImageName.Length > 0) {
                const std::wstring_view name(spi->ImageName.Buffer, spi->ImageName.Length / sizeof(wchar_t));
                if (name == L"Memory Compression") {
                    *working_set_bytes = static_cast<uint64_t>(spi->WorkingSetSize);
                    return result(AME_OK);
                }
            }
            if (spi->NextEntryOffset == 0) break;
            p += spi->NextEntryOffset;
        }

        return result(AME_OK);
    });
}

AmeResult AME_CALL AmePulseFlushMemory(uint64_t target_pulse_bytes, uint64_t* freed_bytes) {
    return boundary([&] {
        if (freed_bytes) *freed_bytes = 0;
        uint64_t comp_before = 0;
        AmeGetMemoryCompressionBytes(&comp_before);

        MEMORYSTATUSEX mem_before{}; mem_before.dwLength = sizeof(mem_before);
        GlobalMemoryStatusEx(&mem_before);

        uint64_t safe_alloc = 0;
        if (mem_before.ullAvailPhys > (512ULL * 1024 * 1024)) {
            safe_alloc = mem_before.ullAvailPhys - (512ULL * 1024 * 1024);
        }
        uint64_t to_pulse = (target_pulse_bytes > 0) ? target_pulse_bytes : (1536ULL * 1024 * 1024);
        if (to_pulse > safe_alloc) to_pulse = safe_alloc;
        if (to_pulse < (64ULL * 1024 * 1024)) to_pulse = (64ULL * 1024 * 1024);

        const size_t chunk_size = 64 * 1024 * 1024;
        size_t num_chunks = static_cast<size_t>(to_pulse / chunk_size);
        if (num_chunks == 0) num_chunks = 1;
        std::vector<void*> chunks;
        chunks.reserve(num_chunks);

        for (size_t i = 0; i < num_chunks; ++i) {
            void* ptr = VirtualAlloc(nullptr, chunk_size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (ptr) {
                chunks.push_back(ptr);
                volatile char* cp = static_cast<volatile char*>(ptr);
                for (size_t offset = 0; offset < chunk_size; offset += 4096) {
                    cp[offset] = 1;
                }
            } else {
                break;
            }
        }

        Sleep(250);

        for (void* ptr : chunks) {
            VirtualFree(ptr, 0, MEM_RELEASE);
        }
        chunks.clear();

        EmptyWorkingSet(GetCurrentProcess());

        uint64_t comp_after = 0;
        AmeGetMemoryCompressionBytes(&comp_after);

        if (freed_bytes) {
            if (comp_before > comp_after) {
                *freed_bytes = comp_before - comp_after;
            } else {
                *freed_bytes = 0;
            }
        }
        return result(AME_OK);
    });
}

AmeResult AME_CALL AmeClampProcessWorkingSet(const AmeProcessIdentity* identity, uint64_t max_bytes, AmeReclaimResult* output) {
    return boundary([&] {
        if (!valid_identity(identity) || !output || output->size != sizeof(*output) || max_bytes < (16ULL * 1024 * 1024))
            return result(AME_INVALID_ARGUMENT);
        *output = {}; output->size = sizeof(*output); output->monotonic_ms = GetTickCount64();

        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_QUOTA | PROCESS_SET_INFORMATION | PROCESS_VM_READ | SYNCHRONIZE, FALSE, identity->pid));
        if (!process.value) return result(AME_WINDOWS_ERROR, GetLastError());

        AmeProcessIdentity actual{};
        auto status = read_identity(process.value, identity->pid, actual);
        if (status != AME_OK) return status;
        if (actual.creation_filetime != identity->creation_filetime || !same_path(actual.image_path, identity->image_path))
            return result(AME_IDENTITY_CHANGED);
        status = check_process(process.value, actual, false);
        if (status != AME_OK) return status;

        PROCESS_MEMORY_COUNTERS_EX before{}; before.cb = sizeof(before);
        if (!GetProcessMemoryInfo(process.value, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&before), sizeof(before)))
            return result(AME_WINDOWS_ERROR, GetLastError());
        output->working_set_before_bytes = before.WorkingSetSize;
        output->private_commit_before_bytes = before.PrivateUsage;

        // Technique B: In-Memory Compression Priority (MEMORY_PRIORITY_LOW)
        MEMORY_PRIORITY_INFORMATION prio{};
        prio.MemoryPriority = MEMORY_PRIORITY_LOW;
        SetProcessInformation(process.value, ProcessMemoryPriority, &prio, sizeof(prio));

        // Technique A: Hard Working Set Quota
        SIZE_T minWs = 0, maxWs = 0;
        DWORD flags = 0;
        GetProcessWorkingSetSizeEx(process.value, &minWs, &maxWs, &flags);

        SIZE_T newMin = (minWs > 0 && minWs < max_bytes) ? minWs : static_cast<SIZE_T>(16 * 1024 * 1024);
        SIZE_T newMax = static_cast<SIZE_T>(max_bytes);
        if (!SetProcessWorkingSetSizeEx(process.value, newMin, newMax, 0x00000004 /* QUOTA_LIMITS_HARDWS_MAX_ENABLE */)) {
            if (!SetProcessWorkingSetSizeEx(process.value, static_cast<SIZE_T>(-1), newMax, 0x00000004)) {
                return result(AME_WINDOWS_ERROR, GetLastError());
            }
        }

        clamped_processes[{identity->pid, identity->creation_filetime}] = {
            identity->pid, identity->creation_filetime, std::wstring(identity->image_path),
            max_bytes, minWs, maxWs, flags
        };

        PROCESS_MEMORY_COUNTERS_EX after{}; after.cb = sizeof(after);
        if (GetProcessMemoryInfo(process.value, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&after), sizeof(after))) {
            output->working_set_after_bytes = after.WorkingSetSize;
            output->private_commit_after_bytes = after.PrivateUsage;
            output->working_set_delta_bytes = static_cast<int64_t>(output->working_set_after_bytes) - static_cast<int64_t>(output->working_set_before_bytes);
        }
        output->applied_stages = AME_STAGE_MEMORY_PRIORITY | AME_STAGE_WORKING_SET_TRIM;
        return result(AME_OK);
    });
}

AmeResult AME_CALL AmeUnclampProcessWorkingSet(const AmeProcessIdentity* identity) {
    return boundary([&] {
        if (!valid_identity(identity)) return result(AME_INVALID_ARGUMENT);
        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_QUOTA | PROCESS_SET_INFORMATION | SYNCHRONIZE, FALSE, identity->pid));
        if (!process.value) {
            clamped_processes.erase({identity->pid, identity->creation_filetime});
            return result(AME_WINDOWS_ERROR, GetLastError());
        }
        AmeProcessIdentity actual{};
        if (read_identity(process.value, identity->pid, actual) == AME_OK &&
            actual.creation_filetime == identity->creation_filetime &&
            same_path(actual.image_path, identity->image_path)) {
            MEMORY_PRIORITY_INFORMATION prio{};
            prio.MemoryPriority = MEMORY_PRIORITY_NORMAL;
            SetProcessInformation(process.value, ProcessMemoryPriority, &prio, sizeof(prio));
            SetProcessWorkingSetSizeEx(process.value, static_cast<SIZE_T>(-1), static_cast<SIZE_T>(-1), 0x00000008 /* QUOTA_LIMITS_HARDWS_MAX_DISABLE */);
        }
        clamped_processes.erase({identity->pid, identity->creation_filetime});
        return result(AME_OK);
    });
}

