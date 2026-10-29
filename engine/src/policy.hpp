#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <string>

namespace ame {
constexpr std::uint64_t MiB = 1024ULL * 1024;
struct SystemSample {
    std::uint64_t total = 0, available = 0, commit = 0, commit_limit = 0;
    std::uint64_t cache = 0, kernel_paged = 0, kernel_nonpaged = 0;
    double used_percent() const { return total ? 100.0 * static_cast<double>(total - available) / static_cast<double>(total) : 0; }
    double commit_percent() const { return commit_limit ? 100.0 * static_cast<double>(commit) / static_cast<double>(commit_limit) : 0; }
    bool valid() const { return total > 0 && available <= total && commit_limit > 0; }
};
enum class Phase { unknown, normal, pending, pressure };
inline const char* phase_name(Phase p) {
    switch (p) { case Phase::normal:return "NORMAL"; case Phase::pending:return "PENDING"; case Phase::pressure:return "PRESSURE"; default:return "UNKNOWN"; }
}
class PressurePolicy {
    std::optional<double> since_, previous_;
    Phase phase_ = Phase::unknown;
public:
    Phase update(const SystemSample& s, double now) {
        if (!s.valid() || !std::isfinite(now) || (previous_ && (now < *previous_ || now - *previous_ > 6.0))) {
            since_.reset(); phase_ = Phase::unknown; previous_.reset();
            return phase_;
        }
        previous_ = now;
        const auto low_floor = std::min<std::uint64_t>(512 * MiB, s.total * 3 / 100);
        const bool high = s.used_percent() >= 95.0 || s.available < low_floor || s.commit_percent() >= 90.0;
        const bool recovered = s.used_percent() < 88.0 && s.available >= s.total * 6 / 100 && s.commit_percent() < 85.0;
        if (phase_ == Phase::pressure) {
            if (recovered) { phase_ = Phase::normal; since_.reset(); }
            return phase_;
        }
        if (!high) { since_.reset(); return phase_ = Phase::normal; }
        if (!since_) since_ = now;
        return phase_ = now - *since_ >= 15.0 ? Phase::pressure : Phase::pending;
    }
};
struct AgentStatus {
    std::uint32_t pid = 0;
    std::uint64_t cache_bytes = 0, released_bytes = 0;
    double latency_ms = 0;
};
inline bool feedback_degraded(double before, double after) {
    return !std::isfinite(before) || !std::isfinite(after) || before < 0 || after < 0 || after > std::max(20.0, before * 2.0);
}
class ActionGate {
    std::optional<double> last_action_;
    bool disabled_ = false;
public:
    bool allowed(Phase phase, bool opted_in, const AgentStatus& s, double now) const {
        return !disabled_ && opted_in && phase == Phase::pressure && s.pid > 0 && s.cache_bytes > 0 &&
            std::isfinite(now) && std::isfinite(s.latency_ms) && s.latency_ms >= 0 && s.latency_ms <= 20.0 &&
            (!last_action_ || now - *last_action_ >= 60.0);
    }
    void action_started(double now) { last_action_ = now; }
    void disable() { disabled_ = true; }
    bool disabled() const { return disabled_; }
};
}
