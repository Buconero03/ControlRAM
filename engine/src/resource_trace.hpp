#pragma once
#include "../sdk/ame_resource_api.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>

namespace ame::resource {
// Optional journal of the demo client. No changes to the DLL's C ABI or policy.
class Trace {
    std::ofstream output_;
    std::chrono::steady_clock::time_point began_ = std::chrono::steady_clock::now();
    std::string phase_ = "setup";
    uint64_t sequence_ = 0;
    bool failed_ = false;
    static std::string quoted(const std::string& text) {
        std::ostringstream out; out << '"';
        for (const unsigned char c : text) {
            if (c == '"' || c == '\\') out << '\\' << static_cast<char>(c);
            else if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<unsigned>(c) << std::dec;
            else out << static_cast<char>(c);
        }
        out << '"'; return out.str();
    }
    void entry(const char* type, const std::string& fields) {
        if (!output_.is_open() || failed_) return;
        if (sequence_ >= 8192) { failed_ = true; return; }
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - began_).count();
        output_ << "{\"seq\":" << ++sequence_ << ",\"type\":" << quoted(type)
                << ",\"elapsed_ms\":" << elapsed << ",\"phase\":" << quoted(phase_)
                << fields << "}\n";
        output_.flush();
        if (!output_) failed_ = true;
    }
public:
    void open(const std::filesystem::path& path, const char* origin = "windows_demo") {
        output_.open(path, std::ios::binary | std::ios::trunc);
        if (!output_) throw std::runtime_error("Cannot create API execution journal");
        entry("session_start", ",\"trace_version\":1,\"api_abi\":1,\"data_origin\":" + quoted(origin));
    }
    bool healthy() const { return !failed_; }
    void mark_failed() noexcept { failed_ = true; }
    void phase(const char* value) {
        phase_ = value;
        entry("phase", "");
    }
    void call(const char* expression, AmeResult status, uint32_t windows_error) {
        entry("call", ",\"expression\":" + quoted(expression) + ",\"result\":" +
            std::to_string(status) + ",\"windows_error\":" + std::to_string(windows_error));
    }
    void check(const char* message, bool passed) {
        entry("check", ",\"message\":" + quoted(message) + ",\"passed\":" + (passed ? "true" : "false"));
    }
    void process(uint32_t pid, uint64_t creation) {
        entry("process", ",\"pid\":" + std::to_string(pid) + ",\"creation_filetime\":" + std::to_string(creation));
    }
    void snapshot(const char* label, AmeGroup group, const AmeGroupSnapshot& s) {
        std::ostringstream out;
        out << ",\"label\":" << quoted(label) << ",\"group\":" << group << ",\"flags\":" << s.flags
            << ",\"active_processes\":" << s.active_processes << ",\"measured_processes\":" << s.measured_processes
            << ",\"missing_processes\":" << s.missing_processes << ",\"working_set_sum_bytes\":" << s.working_set_sum_bytes
            << ",\"private_commit_sum_bytes\":" << s.private_commit_sum_bytes
            << ",\"commit_notice_bytes\":" << s.commit_notice_bytes << ",\"rate_interval_ms\":" << s.rate_interval_ms
            << ",\"cpu_percent_machine\":" << std::setprecision(17) << s.cpu_percent_machine
            << ",\"io_read_bytes_per_second\":" << s.io_read_bytes_per_second
            << ",\"io_write_bytes_per_second\":" << s.io_write_bytes_per_second
            << ",\"page_faults_per_second\":" << s.page_faults_per_second
            << ",\"private_commit_change_bytes\":" << s.private_commit_change_bytes;
        entry("snapshot", out.str());
    }
    void event(AmeGroup group, const AmeGroupEvent& e) {
        entry("event", ",\"group\":" + std::to_string(group) + ",\"kind\":" + std::to_string(e.kind) +
            ",\"pid\":" + std::to_string(e.pid) + ",\"windows_message\":" + std::to_string(e.windows_message) +
            ",\"job_commit_bytes\":" + std::to_string(e.job_commit_bytes) +
            ",\"commit_notice_bytes\":" + std::to_string(e.commit_notice_bytes));
    }
    void finish(bool passed, unsigned checks, const std::string& error = "") {
        entry("session_end", ",\"passed\":" + std::string(passed ? "true" : "false") +
            ",\"checks\":" + std::to_string(checks) + ",\"error\":" + quoted(error));
    }
};
}
