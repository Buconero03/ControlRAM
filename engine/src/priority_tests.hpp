#pragma once
// Integration tests mutate only this test process, and use a dedicated child.
DWORD direct_parent() {
    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
    if (snapshot.value == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
    if (!Process32FirstW(snapshot.value, &entry)) return 0;
    do { if (entry.th32ProcessID == GetCurrentProcessId()) return entry.th32ParentProcessID; }
    while (Process32NextW(snapshot.value, &entry));
    return 0;
}
int test_owner_exit(int argc, wchar_t** argv) {
    if (argc != 4) return 1;
    const DWORD pid = static_cast<DWORD>(std::stoul(argv[2]));
    if (!pid || pid != direct_parent()) return 1;
    Handle parent(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_INFORMATION | SYNCHRONIZE, FALSE, pid));
    FILETIME created{}, exited{}, kernel{}, user{};
    if (!parent.value || !same_user(parent.value) || process_image(parent.value) != process_image(GetCurrentProcess()) ||
        !GetProcessTimes(parent.value, &created, &exited, &kernel, &user) || ticks(created) != std::stoull(argv[3])) return 1;
    PriorityLease lease;
    if (!lease.begin(parent.value, 10)) return 1;
    // Intentionally bypass C++ cleanup in this dedicated test child only.
    ExitProcess(77);
    return 1;
}
int test_priority_lease() {
    const auto require = [](bool ok, const char* message) { if (!ok) throw std::runtime_error(message); };
    require(valid_selected_image(L"C:\\Program Files\\WindowsApps\\AME.Path.Fixture_1.0_x64\\app\\Claude.exe"),
        "Live image selection must not depend on filesystem access");
    require(!valid_selected_image(L"Claude.exe") && !valid_selected_image(L"C:\\apps\\data.txt"),
        "Image selection must reject relative and non-executable paths");
    require(memory_priority(GetCurrentProcess()) == MEMORY_PRIORITY_NORMAL, "Test process needs default memory priority");
    struct Restore { ~Restore() { set_memory_priority(GetCurrentProcess(), MEMORY_PRIORITY_NORMAL); } } restore;
    {
        PriorityLease lease;
        require(lease.begin(GetCurrentProcess(), 10), "Watchdog did not become ready");
        require(memory_priority(GetCurrentProcess()) == MEMORY_PRIORITY_BELOW_NORMAL, "Priority not applied");
        require(lease.finish() == 0 && memory_priority(GetCurrentProcess()) == MEMORY_PRIORITY_NORMAL, "Normal rollback failed");
    }
    {
        PriorityLease lease;
        require(lease.begin(GetCurrentProcess(), 1), "Expiry test could not start");
        const auto deadline = Clock::now() + std::chrono::seconds(5);
        while (!lease.finished() && Clock::now() < deadline) Sleep(20);
        require(lease.finished() && lease.finish() == 0 && memory_priority(GetCurrentProcess()) == MEMORY_PRIORITY_NORMAL, "Bounded lease rollback failed");
    }
    {
        PriorityLease lease;
        require(lease.begin(GetCurrentProcess(), 10), "Application override test could not start");
        require(set_memory_priority(GetCurrentProcess(), MEMORY_PRIORITY_MEDIUM), "Test override failed");
        require(lease.finish() == 2 && memory_priority(GetCurrentProcess()) == MEMORY_PRIORITY_MEDIUM, "Application override was overwritten");
        require(set_memory_priority(GetCurrentProcess(), MEMORY_PRIORITY_NORMAL), "Test override cleanup failed");
    }
    FILETIME created{}, exited{}, kernel{}, user{};
    require(GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user) != FALSE, "Test identity unavailable");
    std::wstring exe(32768, L'\0');
    const DWORD count = GetModuleFileNameW(nullptr, exe.data(), static_cast<DWORD>(exe.size()));
    require(count && count < exe.size(), "Test executable path unavailable"); exe.resize(count);
    std::wstring command = L"\"" + exe + L"\" --test-owner-exit " + std::to_wstring(GetCurrentProcessId()) + L" " + std::to_wstring(ticks(created));
    STARTUPINFOW startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION child{};
    require(CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child) != FALSE, "Crash fixture launch failed");
    Handle child_process(child.hProcess), child_thread(child.hThread);
    require(WaitForSingleObject(child_process.value, 10000) == WAIT_OBJECT_0, "Crash fixture timed out");
    DWORD result = 0; require(GetExitCodeProcess(child_process.value, &result) && result == 77, "Crash fixture did not apply lease");
    const auto deadline = Clock::now() + std::chrono::seconds(5);
    while (memory_priority(GetCurrentProcess()) != MEMORY_PRIORITY_NORMAL && Clock::now() < deadline) Sleep(20);
    require(memory_priority(GetCurrentProcess()) == MEMORY_PRIORITY_NORMAL, "Owner-death rollback failed");
    std::cout << "PASS Windows priority apply, rollback, expiry, app override and owner-death recovery\n";
    return 0;
}
