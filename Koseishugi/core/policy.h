#pragma once

#include <cstddef>
#include <fstream>
#include <sstream>
#include <string>

namespace core {
constexpr long kSubmitSyscall = 463;
constexpr long kClearSyscall = 464;
constexpr long kTrimSyscall = 465;
struct KernelAbi { std::size_t capacity = 0; };
inline bool ParseKernelAbi(const std::string& line, KernelAbi& info) {
    std::istringstream in(line);
    std::string token;
    int seen = 0;
    KernelAbi parsed;
    if (!(in >> token) || token != "#") return false;
    while (in >> token) {
        const auto pos = token.find('=');
        if (pos == std::string::npos) continue;
        const auto key = token.substr(0, pos), val = token.substr(pos + 1);
        if (key == "Koseishugi_abi") { if (val != "1" || (seen & 1)) return false; seen |= 1; }
        else if (key == "submit") { if (val != "463" || (seen & 2)) return false; seen |= 2; }
        else if (key == "clear") { if (val != "464" || (seen & 4)) return false; seen |= 4; }
        else if (key == "trim") { if (val != "465" || (seen & 8)) return false; seen |= 8; }
        else if (key == "capacity") {
            if ((seen & 16) || val.empty() || val.find_first_not_of("0123456789") != std::string::npos) return false;
            try {
                std::size_t n = 0;
                const auto capacity = std::stoull(val, &n);
                if (n != val.size() || capacity < 2 || capacity > 262144) return false;
                parsed.capacity = static_cast<std::size_t>(capacity);
                seen |= 16;
            } catch (...) { return false; }
        }
    }
    if (seen != 31) return false;
    info = parsed;
    return true;
}
inline bool ReadKernelAbi(const std::string& path, KernelAbi& info, std::string& note) {
    std::ifstream in(path);
    std::string line;
    if (!std::getline(in, line) || !ParseKernelAbi(line, info)) {
        note = "missing or incompatible Koseishugi kernel ABI at " + path;
        return false;
    }
    return true;
}
} // namespace core


#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <unordered_map>
#include <utility>
#include <vector>

namespace core {
using Histogram = std::unordered_map<std::uint64_t, std::uint64_t>;
inline std::vector<std::pair<std::uint64_t, std::uint64_t>>
SelectWorkingSet(const Histogram& hist, int coverage, std::size_t limit) {
    if (coverage < 1 || coverage > 100 || limit == 0)
        throw std::invalid_argument("coverage must be 1-100 and page limit positive");
    std::vector<std::pair<std::uint64_t, std::uint64_t>> pages;
    std::uint64_t total = 0;
    for (const auto& item : hist) {
        if (item.second == 0) continue;
        if (item.second > std::numeric_limits<std::uint64_t>::max() - total)
            throw std::overflow_error("histogram count overflow");
        total += item.second;
        pages.push_back(item);
    }
    std::sort(pages.begin(), pages.end(), [](const auto& a, const auto& b) {
        return a.second != b.second ? a.second > b.second : a.first < b.first;
    });
    const auto goal = (total / 100) * coverage + ((total % 100) * coverage + 99) / 100;
    std::uint64_t cumulative = 0;
    std::size_t keep = 0;
    while (keep < pages.size() && keep < limit && cumulative < goal)
        cumulative += pages[keep++].second;
    pages.resize(keep);
    std::reverse(pages.begin(), pages.end());
    return pages;
}
} // namespace core



#include <string>
namespace core {
struct PolicyConfig {
    int pfn_percentile = 80;
    int pfn_hist_max = 65536;
    std::string proc_hist_path = "/proc/pebs_page_hist";
    bool histogram_logging = false;
};
struct PolicyResult {
    bool ok = false;
    int pages_submitted = 0;
    std::string note;
};
class Policy {
public:
    using Histogram = core::Histogram;
    explicit Policy(PolicyConfig cfg);
    PolicyResult Process(const Histogram& hist, const std::string& log_path);
    PolicyResult Clear();
    PolicyResult TrimCold(int pct);
private:
    PolicyConfig cfg_;
};
} // namespace core
