#pragma once
#include <string>

namespace util {
std::string trim(const std::string& s);
bool read_file(const std::string& path, std::string& out);
std::string run_cmd(const std::string& cmd);

} // namespace util
