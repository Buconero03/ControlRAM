#pragma once
#include "policy.hpp"
#include <set>
#include <vector>

namespace ame {
struct Identity {
    std::uint32_t pid = 0, parent = 0;
    std::uint64_t creation = 0;
    std::string image;
    bool foreground = false;
    bool launcher = false;
};
// Parent PIDs are trusted only when the parent's creation precedes the child.
// Protect same-image app siblings as well: browser descendants may be reparented.
// Shared shells may belong to the actual branch, but their image must never
// join separate console instances and hence unrelated applications.
inline std::set<std::uint32_t> foreground_family(const std::vector<Identity>& rows) {
    std::set<std::uint32_t> protected_ids;
    std::set<std::string> images;
    for (const auto& p : rows) if (p.foreground) {
        protected_ids.insert(p.pid);
        if (!p.launcher && !p.image.empty()) images.insert(p.image);
    }
    bool changed = true;
    while (changed) {
        changed = false;
        for (const auto& p : rows) {
            if (protected_ids.count(p.pid) || (!p.launcher && images.count(p.image) && !p.image.empty())) {
                changed |= protected_ids.insert(p.pid).second;
                if (!p.launcher && !p.image.empty()) changed |= images.insert(p.image).second;
                for (const auto& parent : rows) {
                    if (p.parent == parent.pid && p.creation && parent.creation && parent.creation <= p.creation) {
                        // Stop at shared desktop/shell launchers, otherwise include helpers
                        // whose image differs from their application's root executable.
                        if (!parent.launcher)
                            changed |= protected_ids.insert(parent.pid).second;
                    }
                }
            }
            for (const auto& parent : rows) {
                if (p.parent == parent.pid && protected_ids.count(parent.pid) && p.creation && parent.creation && parent.creation <= p.creation)
                    changed |= protected_ids.insert(p.pid).second;
            }
        }
    }
    return protected_ids;
}
class NativePressure {
    std::optional<double> since_, previous_;
    bool active_ = false;
public:
    bool update(const SystemSample& s, double now) {
        if (!s.valid() || !std::isfinite(now) || (previous_ && (now < *previous_ || now - *previous_ > 6))) {
            since_.reset(); previous_.reset(); return active_ = false;
        }
        previous_ = now;
        if (active_) {
            if (s.used_percent() < 75.0) { active_ = false; since_.reset(); }
            return active_;
        }
        if (s.used_percent() < 80.0) { since_.reset(); return false; }
        if (!since_) since_ = now;
        return active_ = now - *since_ >= 15;
    }
};
inline bool native_candidate(bool active, bool allowed_image, bool protected_family,
    bool known, bool critical_known, bool critical, double idle, std::uint64_t ws) {
    return active && allowed_image && !protected_family && known && critical_known && !critical &&
        std::isfinite(idle) && idle >= 30 && ws >= 128 * MiB;
}
inline bool native_regression(double cpu, double faults, double baseline_faults) {
    return !std::isfinite(cpu) || !std::isfinite(faults) || !std::isfinite(baseline_faults) ||
        cpu >= 1.0 || faults > std::max(500.0, 3.0 * baseline_faults);
}
}
