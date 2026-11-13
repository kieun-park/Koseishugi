#include "core/policy.h"

#include <cerrno>
#include <cstring>
#include <fstream>
#include <unistd.h>
#include <sys/syscall.h>
#if !defined(__linux__) || !defined(__x86_64__) || defined(__ILP32__)
#error "The private Koseishugi ABI requires native x86-64 Linux"
#endif
static_assert(sizeof(unsigned long) == 8, "64-bit PFN ABI required");

namespace core {
static std::string syscall_error(const char* operation) {
    const int error = errno;
    return std::string(operation) + " failed: " + std::strerror(error) +
           " (errno=" + std::to_string(error) + ")";
}
Policy::Policy(PolicyConfig cfg) : cfg_(std::move(cfg)) {}
PolicyResult Policy::Process(const Histogram& hist, const std::string& log_path) {
    PolicyResult result;
    if (hist.empty()) {
        result.ok = true;
        result.note = "empty histogram; previous working set and gate unchanged";
        return result;
    }
    KernelAbi abi;
    if (!ReadKernelAbi(cfg_.proc_hist_path, abi, result.note)) return result;
    if (cfg_.pfn_hist_max <= 0 || static_cast<std::size_t>(cfg_.pfn_hist_max) >= abi.capacity) {
        result.note = "page limit must be positive and smaller than kernel buffer capacity";
        return result;
    }
    std::vector<std::pair<std::uint64_t, std::uint64_t>> selected;
    try { selected = SelectWorkingSet(hist, cfg_.pfn_percentile, cfg_.pfn_hist_max); }
    catch (const std::exception& e) { result.note = e.what(); return result; }
    std::vector<unsigned long> pfns;
    pfns.reserve(selected.size());
    for (const auto& item : selected) pfns.push_back(static_cast<unsigned long>(item.first));
    if (!pfns.empty() && ::syscall(kSubmitSyscall, pfns.data(), static_cast<int>(pfns.size())) < 0) {
        result.note = syscall_error("pebs_submit");
        return result;
    }
    result.ok = true;
    result.pages_submitted = static_cast<int>(pfns.size());
    result.note = "ok";
    if (cfg_.histogram_logging && !log_path.empty()) {
        std::ofstream log(log_path, std::ios::app);
        log << "---- submitted pages (coverage " << cfg_.pfn_percentile << "%) ----\n"
            << "# pages=" << selected.size() << "/" << hist.size() << "\n";
        for (auto it = selected.rbegin(); it != selected.rend(); ++it)
            log << it->first << " " << it->second << "\n";
        if (!log) result.note = "submission succeeded; histogram log write failed";
    }
    return result;
}
PolicyResult Policy::Clear() {
    PolicyResult result;
    KernelAbi abi;
    if (!ReadKernelAbi(cfg_.proc_hist_path, abi, result.note)) return result;
    result.ok = ::syscall(kClearSyscall) >= 0;
    result.note = result.ok ? "ok" : syscall_error("pebs_clear");
    return result;
}
PolicyResult Policy::TrimCold(int pct) {
    PolicyResult result;
    if (pct < 1 || pct > 100) { result.note = "trim percentage must be 1-100"; return result; }
    KernelAbi abi;
    if (!ReadKernelAbi(cfg_.proc_hist_path, abi, result.note)) return result;
    result.ok = ::syscall(kTrimSyscall, pct) >= 0;
    result.note = result.ok ? "ok" : syscall_error("pebs_trim_cold");
    return result;
}
} // namespace core
