#pragma once
#include "policy.hpp"
#include <sstream>
#include <stdexcept>

namespace ame {
inline AgentStatus parse_agent_reply(const std::string& line, std::uint64_t budget = 64 * MiB) {
    if (line.size() > 512) throw std::runtime_error("Agent reply too large");
    // One exact versioned line: AME1 OK pid cache_bytes released_bytes latency_ms.
    // Numeric fields allow neither sign nor exponent. No JSON dependency.
    std::istringstream input(line);
    std::string version, result, pid, cache, released, latency, extra;
    if (!(input >> version >> result >> pid >> cache >> released >> latency) || input >> extra || version != "AME1" || result != "OK")
        throw std::runtime_error("Invalid agent reply");
    auto number = [](const std::string& value) -> std::uint64_t {
        if (value.empty() || value.find_first_not_of("0123456789") != std::string::npos) throw std::runtime_error("Invalid integer");
        std::size_t used = 0; auto n = std::stoull(value, &used);
        if (used != value.size()) throw std::runtime_error("Invalid integer");
        return n;
    };
    auto id = number(pid);
    if (id == 0 || id > 0xffffffffULL) throw std::runtime_error("Invalid PID");
    if (latency.empty() || latency.find_first_not_of("0123456789.") != std::string::npos) throw std::runtime_error("Invalid latency");
    std::size_t used = 0; const auto ms = std::stod(latency, &used);
    if (used != latency.size() || !std::isfinite(ms) || ms < 0) throw std::runtime_error("Invalid latency");
    AgentStatus s{static_cast<std::uint32_t>(id), number(cache), number(released), ms};
    if (s.cache_bytes > 1024ULL * 1024 * MiB || s.released_bytes > budget) throw std::runtime_error("Invalid agent counters");
    return s;
}
}
