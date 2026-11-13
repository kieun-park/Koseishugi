#include "traffic.h"
#include <fstream>
#include <sstream>
#include <string>

namespace traffic {
static bool parse_netdev_line(const std::string& line,
                              const std::string& target_iface,
                              std::uint64_t& out_rx_bytes) {
    auto colon = line.find(':');
    if (colon == std::string::npos) return false;

    std::string iface = line.substr(0, colon);
    size_t b = iface.find_first_not_of(" \t");
    size_t e = iface.find_last_not_of(" \t");
    if (b == std::string::npos) return false;
    iface = iface.substr(b, e - b + 1);

    if (iface != target_iface) return false;

    std::string rest = line.substr(colon + 1);
    std::istringstream iss(rest);
    std::uint64_t rx_bytes = 0;
    if (!(iss >> rx_bytes)) return false;

    out_rx_bytes = rx_bytes;
    return true;
}

bool read_rx_bytes(const std::string& iface, std::uint64_t& out_rx_bytes) {
    std::ifstream in("/proc/net/dev");
    if (!in.is_open()) return false;

    std::string line;
    std::getline(in, line);
    std::getline(in, line);

    while (std::getline(in, line)) {
        if (parse_netdev_line(line, iface, out_rx_bytes)) {
            return true;
        }
    }
    return false;
}

bool read_snapshot(const std::string& iface, TrafficSnapshot& out) {
    out.iface = iface;
    return read_rx_bytes(iface, out.rx_bytes);
}

} // namespace traffic