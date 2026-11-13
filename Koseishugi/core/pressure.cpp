#include "core/pressure.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace core {
namespace {

std::vector<std::string> split_ws(const std::string& line) {
    std::istringstream iss(line);
    std::vector<std::string> out;
    std::string tok;
    while (iss >> tok) out.push_back(tok);
    return out;
}

std::string trim(const std::string& s) {
    size_t b = 0;
    while (b < s.size() && std::isspace(static_cast<unsigned char>(s[b]))) ++b;
    size_t e = s.size();
    while (e > b && std::isspace(static_cast<unsigned char>(s[e - 1]))) --e;
    return s.substr(b, e - b);
}

bool unsigned_number(const std::string& s, std::uint64_t& value) {
    if (s.empty() || !std::all_of(s.begin(), s.end(), [](unsigned char c) {
            return std::isdigit(c) != 0;
        })) return false;
    try {
        size_t used = 0;
        value = std::stoull(s, &used);
        return used == s.size();
    } catch (...) {
        return false;
    }
}
int port_of(const std::string& endpoint) {
    const auto colon = endpoint.rfind(':');
    if (colon == std::string::npos) return -1;
    std::uint64_t port = 0;
    if (!unsigned_number(endpoint.substr(colon + 1), port) || port > 65535)
        return -1;
    return static_cast<int>(port);
}

void add_note(std::string& note, const std::string& text) {
    if (!note.empty()) note += "; ";
    note += text;
}

} // namespace

ServicePressure Pressure::ParseSocketSnapshot(const std::string& service,
                                              const std::string& ss_output) {
    ServicePressure result;
    result.service = service;
    struct Socket {
        std::string state;
        std::uint64_t recv_bytes;
        int local_port;
    };
    std::vector<Socket> sockets;
    std::set<int> listen_ports;
    std::map<std::string, std::uint64_t> states;
    std::istringstream input(ss_output);
    std::string row;
    while (std::getline(input, row)) {
        const auto parts = split_ws(row);
        if (parts.size() < 5) continue;
        std::uint64_t recv = 0;
        if (!unsigned_number(parts[1], recv)) continue;
        const int port = port_of(parts[3]);
        if (port < 0) continue;
        if (parts[0] == "LISTEN") listen_ports.insert(port);
        sockets.push_back({parts[0], recv, port});
    }
    for (const auto& socket : sockets) {
        ++states[socket.state];
        if (socket.state == "LISTEN") continue;
        result.recv_sum_kib += static_cast<double>(socket.recv_bytes) / 1024.0;
        result.max_recv_kib = std::max(result.max_recv_kib,
                                      static_cast<double>(socket.recv_bytes) / 1024.0);
        ++result.conn_count;
        if (socket.state == "ESTAB") {
            if (listen_ports.count(socket.local_port)) ++result.in_conn;
            else ++result.out_conn;
        }
    }
    std::ostringstream summary;
    bool first = true;
    for (const auto& item : states) {
        if (!first) summary << ',';
        first = false;
        summary << item.first << ':' << item.second;
    }
    result.states = summary.str();
    return result;
}

bool Pressure::HigherPriority(const ServicePressure& a, const ServicePressure& b) {
    if (a.recv_sum_kib != b.recv_sum_kib) return a.recv_sum_kib > b.recv_sum_kib;
    if (a.out_conn != b.out_conn) return a.out_conn < b.out_conn;
    if (a.in_conn != b.in_conn) return a.in_conn > b.in_conn;
    return a.service < b.service;
}

void Pressure::SetServiceBlacklist(std::vector<std::string> patterns) {
    blacklist_.clear();
    for (auto& p : patterns) {
        std::string t = trim(p);
        if (t.empty()) continue;
        for (auto& c : t) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        blacklist_.push_back(t);
    }
}

void Pressure::Start() {
    active_ = true;
    snapshot_pending_ = true;
}

void Pressure::Stop() {
    active_ = false;
    snapshot_pending_ = false;
}

PressureReport Pressure::Tick(std::int64_t /*t_ms*/, const std::string& /*iface*/,
                              const std::atomic<bool>* stop) {
    PressureReport r;
    r.active = active_;
    if (!active_) {
        r.note = "inactive";
        return r;
    }
    if (!snapshot_pending_) return r;
    snapshot_pending_ = false;

    auto run_cmd = [stop](const std::string& cmd, int* status = nullptr) -> std::string {
        std::string out;
        if (stop && stop->load(std::memory_order_relaxed)) {
            if (status) *status = -1;
            return out;
        }
        const std::string bounded = "timeout --signal=TERM --kill-after=1s 5s " + cmd;
        FILE* pipe = popen(bounded.c_str(), "r");
        if (!pipe) {
            if (status) *status = -1;
            return out;
        }
        char buf[4096];
        while (fgets(buf, sizeof(buf), pipe)) out += buf;
        const int rc = pclose(pipe);
        if (status) *status = rc;
        return out;
    };

    int ps_status = -1;
    const std::string ps = run_cmd("docker ps --format '{{.ID}}|{{.Names}}'", &ps_status);
    if (ps_status != 0) {
        r.note = "docker ps failed (Docker availability or permission)";
        return r;
    }
    struct ContainerInfo {
        std::string id;
        std::string name;
        int pid = -1;
        std::string netns;
    };
    std::vector<ContainerInfo> containers;
    std::istringstream input(ps);
    std::string line;
    while (std::getline(input, line)) {
        const auto bar = line.find('|');
        if (bar == std::string::npos) continue;
        ContainerInfo c;
        c.id = trim(line.substr(0, bar));
        c.name = trim(line.substr(bar + 1));
        if (!c.id.empty() && !c.name.empty()) containers.push_back(std::move(c));
    }
    if (containers.empty()) {
        r.ok = true;
        r.note = "no running containers";
        return r;
    }
    const std::string host_netns = trim(run_cmd("readlink /proc/self/ns/net 2>/dev/null"));
    std::unordered_map<std::string, size_t> namespace_users;
    bool namespace_inventory_ok = !host_netns.empty();
    for (auto& c : containers) {
        const std::string pid_text = trim(run_cmd(
            "docker inspect -f '{{.State.Pid}}' " + c.id + " 2>/dev/null"));
        std::uint64_t pid = 0;
        if (!unsigned_number(pid_text, pid) || pid == 0 || pid > 2147483647) {
            namespace_inventory_ok = false;
            continue;
        }
        c.pid = static_cast<int>(pid);
        c.netns = trim(run_cmd("readlink /proc/" + std::to_string(c.pid) +
                              "/ns/net 2>/dev/null"));
        if (c.netns.empty()) namespace_inventory_ok = false;
        else ++namespace_users[c.netns];
    }
    if (!namespace_inventory_ok) {
        r.note = "namespace inventory incomplete; socket ownership cannot be verified";
        return r;
    }

    auto is_blacklisted = [&](const std::string& name) {
        std::string lower = name;
        for (auto& c : lower) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        return std::any_of(blacklist_.begin(), blacklist_.end(), [&](const std::string& pattern) {
            return lower.find(pattern) != std::string::npos;
        });
    };

    size_t eligible = 0;
    size_t failed = 0;
    for (const auto& c : containers) {
        if (is_blacklisted(c.name)) continue;
        ++eligible;
        if (c.netns == host_netns || namespace_users[c.netns] > 1) {
            add_note(r.note, "service=" + c.name + " skipped: shared/host network namespace");
            ++failed;
            continue;
        }
        int status = -1;
        const std::string ss = run_cmd("nsenter -t " + std::to_string(c.pid) +
                                      " -n ss -ntaH 2>/dev/null", &status);
        if (status != 0) {
            add_note(r.note, "service=" + c.name + " socket snapshot failed");
            ++failed;
            continue;
        }
        r.topk.push_back(ParseSocketSnapshot(c.name, ss));
    }
    r.ok = failed == 0;
    if (eligible == 0) add_note(r.note, "all containers excluded by denylist");
    std::sort(r.topk.begin(), r.topk.end(), HigherPriority);
    constexpr size_t kTopServices = 10;
    if (r.topk.size() > kTopServices) r.topk.resize(kTopServices);
    return r;
}

} // namespace core
