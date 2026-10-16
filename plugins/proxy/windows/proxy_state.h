#ifndef ENTOMA_WINDOWS_PROXY_STATE_H_
#define ENTOMA_WINDOWS_PROXY_STATE_H_

#include <cstdint>
#include <optional>
#include <string>
#include <cwctype>

namespace entoma_proxy {

struct Snapshot {
  std::uint32_t flags = 0;
  std::wstring server;
  std::wstring bypass;
  std::wstring pac;

  bool operator==(const Snapshot& other) const {
    return flags == other.flags && server == other.server &&
        bypass == other.bypass && pac == other.pac;
  }
};

inline bool ValidPort(std::int64_t port) {
  return port >= 1024 && port <= 65535;
}

inline bool UsesListener(const Snapshot& current, int port) {
  if (!ValidPort(port) || (current.flags & 2U) == 0) return false;
  std::wstring server = current.server;
  for (auto& value : server) value = static_cast<wchar_t>(std::towlower(value));
  const auto suffix = L":" + std::to_wstring(port);
  std::size_t start = 0;
  while (start < server.size()) {
    const auto end = server.find_first_of(L"; \t", start);
    auto endpoint = server.substr(start, end == std::wstring::npos ? end : end-start);
    const auto equal = endpoint.find(L'=');
    if (equal != std::wstring::npos) endpoint = endpoint.substr(equal+1);
    for (const auto* host : {L"127.0.0.1", L"localhost", L"[::1]", L"::1"}) {
      if (endpoint == host + suffix) return true;
    }
    if (end == std::wstring::npos) break;
    start = end+1;
  }
  return false;
}

inline bool ValidBypassEntry(const std::string& entry) {
  if (entry.empty() || entry.size() > 1024) return false;
  for (const unsigned char value : entry) {
    // Semicolons delimit entries in WinINet; accepting one would change the
    // requested list rather than preserving one validated entry.
    if (value < 0x20 || value == 0x7f || value == ';') return false;
  }
  return true;
}

enum class RestoreDecision { NoOwnership, Restore, ExternalChange, Unknown };

enum class RestoreReadback { Restored, StillApplied, ExternalChange };

inline RestoreReadback CheckRestoreReadback(
    const Snapshot& current, const Snapshot& original,
    const std::optional<Snapshot>& applied) {
  if (current == original) return RestoreReadback::Restored;
  return applied && current == *applied ? RestoreReadback::StillApplied
                                       : RestoreReadback::ExternalChange;
}

inline RestoreDecision DecideRestore(
    const Snapshot& current, const std::optional<Snapshot>& original,
    const std::optional<Snapshot>& applied, bool needs_refresh,
    bool ownership_uncertain = false) {
  if (!original) return RestoreDecision::NoOwnership;
  if (needs_refresh || ownership_uncertain) {
    // After an unconfirmed write/refresh, either known transaction snapshot
    // may still be present. Never claim an unknown partial write as external
    // and let the caller stop its listener while it may remain referenced.
    if (current == *original || (applied && current == *applied)) {
      return RestoreDecision::Restore;
    }
    return ownership_uncertain ? RestoreDecision::Unknown
                               : RestoreDecision::ExternalChange;
  }
  if (!applied) return RestoreDecision::Unknown;
  return current == *applied ? RestoreDecision::Restore
                             : RestoreDecision::ExternalChange;
}

inline bool MatchesRequest(
    const Snapshot& current, const std::optional<Snapshot>& original,
    const std::optional<Snapshot>& applied, bool recovery_required,
    std::uint32_t manual_flags, int port, const std::wstring& bypass) {
  return ValidPort(port) && original && applied && !recovery_required &&
      current == *applied && applied->flags == manual_flags &&
      applied->server == L"127.0.0.1:" + std::to_wstring(port) &&
      applied->bypass == bypass;
}

}  // namespace entoma_proxy

#endif  // ENTOMA_WINDOWS_PROXY_STATE_H_
