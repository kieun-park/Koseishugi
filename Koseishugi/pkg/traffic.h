#pragma once
#include <cstdint>
#include <string>

namespace traffic {
struct TrafficSnapshot {
    std::string iface;
    std::uint64_t rx_bytes = 0;
};
bool read_rx_bytes(const std::string& iface, std::uint64_t& out_rx_bytes);
bool read_snapshot(const std::string& iface, TrafficSnapshot& out);

} // namespace traffic