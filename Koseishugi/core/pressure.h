#pragma once

#include <cstdint>
#include <atomic>
#include <string>
#include <vector>

namespace core {
struct ServicePressure {
    std::string service;        // docker container name (best-effort)
    double recv_sum_kib = 0.0;  // sum of non-listening socket Recv-Q bytes (KiB)
    double max_recv_kib = 0.0;  // max Recv-Q among sockets (KiB)
    std::uint64_t conn_count = 0; // non-listening TCP sockets
    std::uint64_t in_conn = 0;  // ESTAB on a listening port  (this service is the callee)
    std::uint64_t out_conn = 0; // ESTAB on an ephemeral port (this service is the caller)
    std::string states;         // compact histogram, e.g., "ESTAB:10,LISTEN:1"
};

struct PressureReport {
    bool active = false;                  // true when the detector is running (P1)
    bool ok = false;                      // snapshot succeeded (including an empty result)
    std::vector<ServicePressure> topk;    // aggregated by service (sorted by recv_sum)
    std::string note;                     // informational note (optional)
};
class Pressure {
public:
    Pressure() = default;
    void SetServiceBlacklist(std::vector<std::string> patterns);
    static ServicePressure ParseSocketSnapshot(const std::string& service,
                                               const std::string& ss_output);
    static bool HigherPriority(const ServicePressure& a, const ServicePressure& b);

    void Start();
    void Stop();

    bool active() const { return active_; }
    PressureReport Tick(std::int64_t t_ms, const std::string& iface,
                        const std::atomic<bool>* stop = nullptr);

private:
    bool active_ = false;
    bool snapshot_pending_ = false;
    std::vector<std::string> blacklist_;
};

} // namespace core
