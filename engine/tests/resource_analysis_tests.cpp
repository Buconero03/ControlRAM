#include "../src/resource_analysis.hpp"
#include <cmath>
#include <iostream>
#include <stdexcept>

namespace {
unsigned checks = 0;
void check(bool condition, const char* text) {
    ++checks;
    if (!condition) throw std::runtime_error(text);
}
bool near(double a, double b) { return std::abs(a - b) < 0.00001; }
AmeGroupSnapshot baseline() {
    AmeGroupSnapshot s{}; s.size = sizeof(s); s.flags = AME_MEMORY_COMPLETE;
    s.monotonic_ms = 10000; s.membership_revision = 2; s.active_processes = 2;
    s.measured_processes = 2; s.private_commit_sum_bytes = 100000;
    s.cpu_time_100ns = 50000000; s.io_read_bytes = 2000; s.io_write_bytes = 3000;
    s.page_faults_total = 100;
    return s;
}
AmeGroupSnapshot next() {
    auto s = baseline(); s.monotonic_ms += 2000;
    s.private_commit_sum_bytes += 30000; s.cpu_time_100ns += 10000000;
    s.io_read_bytes += 4000; s.io_write_bytes += 6000; s.page_faults_total += 200;
    return s;
}
void invalid(const AmeGroupSnapshot* before, AmeGroupSnapshot current, uint32_t processors = 4) {
    current.flags |= AME_RATES_VALID; current.cpu_percent_machine = 99;
    current.private_commit_change_bytes = 999; current.rate_interval_ms = 999;
    current.io_read_bytes_per_second = current.io_write_bytes_per_second = current.page_faults_per_second = 999;
    ame::resource::calculate_rates(before, current, processors);
    check(!(current.flags & AME_RATES_VALID), "invalid sample cannot report valid rates");
    check(current.cpu_percent_machine == 0 && current.private_commit_change_bytes == 0 &&
          current.rate_interval_ms == 0 && current.io_read_bytes_per_second == 0 &&
          current.io_write_bytes_per_second == 0 && current.page_faults_per_second == 0,
          "invalid sample must clear stale calculated outputs");
}
}
int main() {
    try {
        const auto before = baseline(); auto current = next();
        ame::resource::calculate_rates(&before, current, 4);
        check((current.flags & AME_RATES_VALID) != 0, "complete two-second sample");
        check(current.rate_interval_ms == 2000 && near(current.cpu_percent_machine, 12.5), "whole-machine CPU normalization");
        check(near(current.io_read_bytes_per_second, 2000) && near(current.io_write_bytes_per_second, 3000), "I/O rates");
        check(near(current.page_faults_per_second, 100), "all page faults, not disk faults");
        check(current.private_commit_change_bytes == 30000, "allocation growth");
        current = next(); current.private_commit_sum_bytes = 50000;
        ame::resource::calculate_rates(&before, current, 4);
        check(current.private_commit_change_bytes == -50000, "allocation decrease keeps sign");
        invalid(nullptr, next()); invalid(&before, next(), 0);
        current = next(); current.flags = 0; invalid(&before, current);
        auto missing = before; missing.flags = 0; invalid(&missing, next());
        current = next(); ++current.membership_revision; invalid(&before, current);
        current = next(); --current.active_processes; invalid(&before, current);
        for (const uint64_t interval : {uint64_t{0}, uint64_t{999}, uint64_t{6001}}) {
            current = next(); current.monotonic_ms = before.monotonic_ms + interval; invalid(&before, current);
        }
        current = next(); current.monotonic_ms = 1; invalid(&before, current);
        current = next(); current.cpu_time_100ns = 1; invalid(&before, current);
        current = next(); current.io_read_bytes = 1; invalid(&before, current);
        current = next(); current.io_write_bytes = 1; invalid(&before, current);
        current = next(); current.page_faults_total = 1; invalid(&before, current);
        current = next(); current.private_commit_sum_bytes = std::numeric_limits<uint64_t>::max(); invalid(&before, current);
        current = next(); current.cpu_time_100ns += 1000000000; invalid(&before, current);
        for (const uint64_t interval : {uint64_t{1000}, uint64_t{6000}}) {
            current = next(); current.monotonic_ms = before.monotonic_ms + interval;
            current.flags |= AME_COMMIT_NOTICE_EXCEEDED;
            ame::resource::calculate_rates(&before, current, 4);
            check((current.flags & AME_RATES_VALID) && (current.flags & AME_COMMIT_NOTICE_EXCEEDED), "valid interval endpoints keep notice flag");
        }
        current = next(); current.private_commit_sum_bytes = before.private_commit_sum_bytes;
        ame::resource::calculate_rates(&before, current, 4);
        check(current.private_commit_change_bytes == 0 && (current.flags & AME_RATES_VALID), "unchanged allocation is a real measured zero");
        std::cout << "PASS " << checks << " resource analysis checks\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << "FAIL " << e.what() << '\n'; return 1; }
}
