#pragma once
#include "../sdk/ame_resource_api.h"
#include <limits>

namespace ame::resource {
// Used by the actual DLL. No rates across missing samples or membership changes.
inline void calculate_rates(const AmeGroupSnapshot* previous, AmeGroupSnapshot& now,
                            uint32_t processors) {
    now.flags &= ~static_cast<uint32_t>(AME_RATES_VALID);
    now.rate_interval_ms = 0;
    now.cpu_percent_machine = 0;
    now.io_read_bytes_per_second = 0;
    now.io_write_bytes_per_second = 0;
    now.page_faults_per_second = 0;
    now.private_commit_change_bytes = 0;
    if (!previous || !processors || !(previous->flags & AME_MEMORY_COMPLETE) ||
        !(now.flags & AME_MEMORY_COMPLETE) || now.membership_revision != previous->membership_revision ||
        now.active_processes != previous->active_processes || now.monotonic_ms <= previous->monotonic_ms)
        return;
    const auto dt = now.monotonic_ms - previous->monotonic_ms;
    if (dt < 1000 || dt > 6000 || now.cpu_time_100ns < previous->cpu_time_100ns ||
        now.io_read_bytes < previous->io_read_bytes || now.io_write_bytes < previous->io_write_bytes ||
        now.page_faults_total < previous->page_faults_total)
        return;
    const auto change = now.private_commit_sum_bytes >= previous->private_commit_sum_bytes
        ? now.private_commit_sum_bytes - previous->private_commit_sum_bytes
        : previous->private_commit_sum_bytes - now.private_commit_sum_bytes;
    if (change > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) return;
    const double seconds = static_cast<double>(dt) / 1000.0;
    const double cpu = static_cast<double>(now.cpu_time_100ns - previous->cpu_time_100ns) /
                       1e7 / seconds / processors * 100.0;
    if (cpu > 100.0) return;
    now.cpu_percent_machine = cpu;
    now.io_read_bytes_per_second = static_cast<double>(now.io_read_bytes - previous->io_read_bytes) / seconds;
    now.io_write_bytes_per_second = static_cast<double>(now.io_write_bytes - previous->io_write_bytes) / seconds;
    now.page_faults_per_second = static_cast<double>(now.page_faults_total - previous->page_faults_total) / seconds;
    now.private_commit_change_bytes = now.private_commit_sum_bytes >= previous->private_commit_sum_bytes
        ? static_cast<int64_t>(change) : -static_cast<int64_t>(change);
    now.rate_interval_ms = dt;
    now.flags |= AME_RATES_VALID;
}
}
