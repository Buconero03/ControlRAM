#pragma once
// Included after main.cpp's Win32 utilities. A separate process owns each change.
// Only duplicated, explicitly inherited handles cross the process boundary.

std::wstring lower_image(std::wstring image) {
    for (auto& c : image) c = static_cast<wchar_t>(std::towlower(c));
    return image;
}
bool valid_selected_image(const std::filesystem::path& image) {
    // Do not stat the executable: a live WindowsApps image can be visible through
    // QueryFullProcessImageName even when filesystem metadata is inaccessible.
    // The target must still match this exact path through its opened process handle.
    const auto text = image.wstring();
    return image.is_absolute() && lower_image(image.extension().wstring()) == L".exe" &&
        text.find(L'"') == std::wstring::npos && text.find(L'\0') == std::wstring::npos;
}
std::wstring process_image(HANDLE h) {
    std::wstring result(32768, L'\0'); DWORD size = static_cast<DWORD>(result.size());
    if (!QueryFullProcessImageNameW(h, 0, result.data(), &size)) return {};
    result.resize(size); return lower_image(result);
}
std::vector<unsigned char> process_user(HANDLE process) {
    HANDLE raw = nullptr;
    if (!OpenProcessToken(process, TOKEN_QUERY, &raw)) return {};
    Handle token(raw); DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    if (!size) return {};
    std::vector<unsigned char> buffer(size);
    if (!GetTokenInformation(token.value, TokenUser, buffer.data(), size, &size)) return {};
    return buffer;
}
bool same_user(HANDLE target) {
    static const auto self = process_user(GetCurrentProcess());
    const auto other = process_user(target);
    if (self.empty() || other.empty()) return false;
    return EqualSid(reinterpret_cast<const TOKEN_USER*>(self.data())->User.Sid,
        reinterpret_cast<const TOKEN_USER*>(other.data())->User.Sid) != FALSE;
}
unsigned memory_priority(HANDLE h) {
    MEMORY_PRIORITY_INFORMATION p{};
    if (!GetProcessInformation(h, ProcessMemoryPriority, &p, sizeof(p))) return 0;
    return p.MemoryPriority;
}
bool set_memory_priority(HANDLE h, unsigned value) {
    MEMORY_PRIORITY_INFORMATION p{value};
    return SetProcessInformation(h, ProcessMemoryPriority, &p, sizeof(p)) != FALSE;
}
int priority_watch(int argc, wchar_t** argv) {
    if (argc != 7) return 5;
    HANDLE handles[4]{};
    for (int i = 0; i < 4; ++i) {
        std::wstring value(argv[i + 2]);
        if (value.empty() || value.find_first_not_of(L"0123456789") != std::wstring::npos) return 5;
        handles[i] = reinterpret_cast<HANDLE>(static_cast<std::uintptr_t>(std::stoull(value)));
    }
    const unsigned seconds = static_cast<unsigned>(std::stoul(argv[6]));
    if (seconds < 1 || seconds > 120) return 5;
    Handle target(handles[0]), owner(handles[1]), ready(handles[2]), cancel(handles[3]);
    // Respect existing application policies; lower NORMAL only to BELOW_NORMAL.
    if (WaitForSingleObject(owner.value, 0) != WAIT_TIMEOUT ||
        WaitForSingleObject(target.value, 0) != WAIT_TIMEOUT ||
        memory_priority(target.value) != MEMORY_PRIORITY_NORMAL) return 5;
    if (!set_memory_priority(target.value, MEMORY_PRIORITY_BELOW_NORMAL)) return 3;
    const auto applied_priority = memory_priority(target.value);
    if (applied_priority != MEMORY_PRIORITY_BELOW_NORMAL) {
        if (!applied_priority) set_memory_priority(target.value, MEMORY_PRIORITY_NORMAL);
        return 3;
    }
    // If readiness cannot be reported, immediately roll back.
    const bool notified = SetEvent(ready.value) != FALSE;
    if (notified) {
        HANDLE waits[]{owner.value, cancel.value, target.value};
        WaitForMultipleObjects(3, waits, FALSE, seconds * 1000);
    }
    if (WaitForSingleObject(target.value, 0) == WAIT_OBJECT_0) return 4;
    // Preserve a different priority chosen subsequently by the application.
    // Windows exposes no atomic compare-and-set; a concurrent identical value is indistinguishable.
    const auto current = memory_priority(target.value);
    if (!current) return 3;
    if (current != MEMORY_PRIORITY_BELOW_NORMAL) return 2;
    return set_memory_priority(target.value, MEMORY_PRIORITY_NORMAL) &&
        memory_priority(target.value) == MEMORY_PRIORITY_NORMAL ? 0 : 3;
}
class PriorityLease {
    HANDLE child_ = nullptr, cancel_ = nullptr;
public:
    DWORD pid = 0; std::uint64_t creation = 0, ws_before = 0, available_before = 0;
    double began = 0, baseline_faults = 0;
    bool feedback_done = false;
    ~PriorityLease() {
        if (cancel_) SetEvent(cancel_);
        if (child_) { WaitForSingleObject(child_, 5000); CloseHandle(child_); }
        if (cancel_) CloseHandle(cancel_);
    }
    PriorityLease() = default;
    PriorityLease(const PriorityLease&) = delete;
    PriorityLease& operator=(const PriorityLease&) = delete;
    bool begin(HANDLE target, unsigned seconds = 120) {
        SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
        Handle ready(CreateEventW(&sa, TRUE, FALSE, nullptr));
        cancel_ = CreateEventW(&sa, TRUE, FALSE, nullptr);
        HANDLE target_copy = nullptr, owner_copy = nullptr;
        if (!ready.value || !cancel_ ||
            !DuplicateHandle(GetCurrentProcess(), target, GetCurrentProcess(), &target_copy, 0, TRUE, DUPLICATE_SAME_ACCESS)) return false;
        Handle inherited_target(target_copy);
        if (!DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(), GetCurrentProcess(), &owner_copy, SYNCHRONIZE, TRUE, 0)) return false;
        Handle inherited_owner(owner_copy);
        HANDLE inherited[]{inherited_target.value, inherited_owner.value, ready.value, cancel_};
        SIZE_T size = 0;
        InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
        if (!size) return false;
        std::vector<unsigned char> attributes(size);
        auto list = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
        if (!InitializeProcThreadAttributeList(list, 1, 0, &size)) return false;
        struct Cleanup { LPPROC_THREAD_ATTRIBUTE_LIST p; ~Cleanup() { DeleteProcThreadAttributeList(p); } } cleanup{list};
        if (!UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof(inherited), nullptr, nullptr)) return false;
        std::wstring exe(32768, L'\0');
        DWORD count = GetModuleFileNameW(nullptr, exe.data(), static_cast<DWORD>(exe.size()));
        if (!count || count >= exe.size()) return false;
        exe.resize(count);
        std::wstring command = L"\"" + exe + L"\" --priority-watch";
        for (const auto h : inherited) command += L" " + std::to_wstring(reinterpret_cast<std::uintptr_t>(h));
        command += L" " + std::to_wstring(seconds);
        STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup); startup.lpAttributeList = list;
        PROCESS_INFORMATION child{};
        if (!CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, TRUE,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, nullptr, nullptr, &startup.StartupInfo, &child)) return false;
        child_ = child.hProcess; CloseHandle(child.hThread);
        HANDLE waits[]{ready.value, child_};
        return WaitForMultipleObjects(2, waits, FALSE, 5000) == WAIT_OBJECT_0;
    }
    bool finished() const { return child_ && WaitForSingleObject(child_, 0) == WAIT_OBJECT_0; }
    DWORD finish() {
        if (!child_) return 5;
        SetEvent(cancel_);
        if (WaitForSingleObject(child_, 5000) != WAIT_OBJECT_0) return 6;
        DWORD code = 3; GetExitCodeProcess(child_, &code); return code;
    }
};
class NativeController {
    std::set<std::wstring> allowed_;
    std::map<DWORD, std::unique_ptr<PriorityLease>> leases_;
    std::map<std::pair<DWORD, std::uint64_t>, double> attempts_;
    ame::NativePressure pressure_;
    std::ofstream& report_;
    bool disabled_ = false;
    DWORD session_ = 0;
    Handle mutex_{nullptr};
    void event(const char* type, DWORD pid, double now, const char* reason, DWORD result = 0) {
        report_ << "{\"type\":" << quote(type) << ",\"pid\":" << pid << ",\"elapsed_seconds\":" << now
            << ",\"reason\":" << quote(reason) << ",\"result_code\":" << result << "}\n";
        std::cout << "    " << type << " PID " << pid << ": " << reason << " (" << result << ")\n";
    }
public:
    NativeController(const std::vector<std::wstring>& allowed, std::ofstream& report) : report_(report) {
        mutex_.value = CreateMutexW(nullptr, FALSE, L"Local\\AME-MemoryPriority-Controller");
        const DWORD mutex_error = GetLastError();
        if (!mutex_.value || mutex_error == ERROR_ALREADY_EXISTS) throw std::runtime_error("A memory-priority controller is already running in this desktop session");
        wchar_t windows[MAX_PATH]{};
        if (!GetWindowsDirectoryW(windows, MAX_PATH)) throw std::runtime_error("Windows directory unavailable");
        const auto system_path = lower_image(windows) + L"\\";
        for (const auto& image : allowed) {
            const auto normalized = lower_image(image);
            if (normalized.rfind(system_path, 0) == 0) throw std::runtime_error("Windows system images are excluded");
            allowed_.insert(normalized);
        }
        if (!ProcessIdToSessionId(GetCurrentProcessId(), &session_)) throw std::runtime_error("Own session unavailable");
    }
    ~NativeController() { shutdown(0); }
    void shutdown(double now) {
        for (auto& item : leases_) {
            DWORD code = item.second->finish();
            event("priority_finished", item.first, now, "controller_stop", code);
            if (code == 3 || code == 6) disabled_ = true;
        }
        leases_.clear();
    }
    bool disabled() const { return disabled_; }
    void update(const ame::SystemSample& system, const std::vector<Process>& rows, double now) {
        const bool pressure = pressure_.update(system, now);
        std::vector<ame::Identity> identities;
        bool foreground_known = false;
        for (const auto& p : rows) {
            const auto basename = lower_image(std::filesystem::path(p.image).filename().wstring());
            const bool launcher = basename == L"explorer.exe" || basename == L"windowsterminal.exe" ||
                basename == L"powershell.exe" || basename == L"pwsh.exe" || basename == L"cmd.exe" ||
                basename == L"conhost.exe" || !p.critical_known || p.critical;
            identities.push_back({p.pid, p.parent, p.creation, utf8(p.image.c_str()), p.foreground, launcher});
            if (p.foreground && !p.image.empty() && p.creation) foreground_known = true;
        }
        const auto protected_ids = ame::foreground_family(identities);
        for (auto it = leases_.begin(); it != leases_.end();) {
            auto& lease = *it->second;
            const Process* row = nullptr;
            for (const auto& p : rows) if (p.pid == lease.pid && p.creation == lease.creation) { row = &p; break; }
            const char* reason = nullptr;
            if (!row || !row->rate_known) reason = "identity_or_telemetry_lost";
            else if (!foreground_known || protected_ids.count(row->pid)) reason = "foreground_protected";
            else if (!pressure) reason = "pressure_recovered";
            else if (ame::native_regression(row->cpu_percent, row->faults_per_second, lease.baseline_faults)) reason = "activity_or_fault_guard";
            else if (lease.finished()) reason = "lease_expired";
            if (row && row->rate_known && !lease.feedback_done && now - lease.began >= 15) {
                report_ << "{\"type\":\"priority_feedback\",\"pid\":" << row->pid << ",\"elapsed_seconds\":" << now
                    << ",\"working_set_delta_bytes\":" << static_cast<std::int64_t>(row->ws) - static_cast<std::int64_t>(lease.ws_before)
                    << ",\"system_available_delta_bytes\":" << static_cast<std::int64_t>(system.available) - static_cast<std::int64_t>(lease.available_before)
                    << ",\"page_faults_per_second\":" << row->faults_per_second << ",\"causation_established\":false}\n";
                lease.feedback_done = true;
            }
            if (reason) {
                const auto code = lease.finish(); event("priority_finished", row ? row->pid : lease.pid, now, reason, code);
                if (code == 3 || code == 6) disabled_ = true;
                if (std::string(reason) == "activity_or_fault_guard") attempts_[{lease.pid, lease.creation}] = now + 86400;
                it = leases_.erase(it);
            } else ++it;
        }
        const auto write_state = [&]() {
            std::cout << "    Native: " << (pressure ? "PRESSURE" : "WAITING") << " | active leases " << leases_.size() << (disabled_ ? " | DISABLED" : "") << '\n';
            report_ << "{\"type\":\"native_state\",\"elapsed_seconds\":" << now << ",\"pressure\":" << (pressure ? "true" : "false")
                << ",\"active_leases\":" << leases_.size() << ",\"disabled\":" << (disabled_ ? "true" : "false") << "}\n";
        };
        if (disabled_ || !pressure || !foreground_known) { write_state(); return; }
        for (const auto& p : rows) {
            if (leases_.size() >= 3) break;
            if (leases_.count(p.pid) || !ame::native_candidate(pressure, allowed_.count(p.image) != 0,
                protected_ids.count(p.pid) != 0, p.rate_known && p.memory_known, p.critical_known, p.critical, p.low_activity_seconds, p.ws)) continue;
            const auto key = std::make_pair(p.pid, p.creation);
            const auto old = attempts_.find(key);
            if (old != attempts_.end() && now - old->second < 300) continue;
            attempts_[key] = now;
            Handle target(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_INFORMATION | SYNCHRONIZE, FALSE, p.pid));
            if (!target.value) { event("priority_skipped", p.pid, now, "access_denied", GetLastError()); continue; }
            FILETIME created{}, exited{}, kernel{}, user{}; DWORD target_session = 0; BOOL critical = TRUE;
            if (!GetProcessTimes(target.value, &created, &exited, &kernel, &user) || ticks(created) != p.creation ||
                process_image(target.value) != p.image || !same_user(target.value) ||
                !ProcessIdToSessionId(p.pid, &target_session) || target_session != session_ ||
                !process_critical(target.value, &critical) || critical || memory_priority(target.value) != MEMORY_PRIORITY_NORMAL) {
                event("priority_skipped", p.pid, now, "identity_owner_or_existing_policy"); continue;
            }
            // Recheck foreground immediately before launch, including same-image siblings.
            DWORD foreground = 0; GetWindowThreadProcessId(GetForegroundWindow(), &foreground);
            Handle foreground_handle(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, foreground));
            if (!foreground_handle.value || foreground == p.pid || process_image(foreground_handle.value) == p.image) continue;
            auto latest_identities = identities;
            bool latest_known = false;
            for (auto& identity : latest_identities) {
                identity.foreground = identity.pid == foreground;
                if (identity.foreground && identity.creation && !identity.image.empty()) latest_known = true;
            }
            if (!latest_known || ame::foreground_family(latest_identities).count(p.pid)) continue;
            auto lease = std::make_unique<PriorityLease>();
            lease->pid = p.pid; lease->creation = p.creation; lease->began = now;
            lease->baseline_faults = p.faults_per_second; lease->ws_before = p.ws; lease->available_before = system.available;
            if (!lease->begin(target.value)) {
                const auto code = lease->finish(); event("priority_skipped", p.pid, now, "watchdog_not_ready", code);
                if (code == 3 || code == 6) disabled_ = true;
                continue;
            }
            event("priority_applied", p.pid, now, "memory_priority_5_to_4_lease_120s");
            leases_.emplace(p.pid, std::move(lease));
        }
        write_state();
    }
};
