#include "../../plugins/proxy/windows/proxy_state.h"

#include <cassert>
#include <iostream>

using entoma_proxy::DecideRestore;
using entoma_proxy::MatchesRequest;
using entoma_proxy::RestoreDecision;
using entoma_proxy::Snapshot;

int main() {
  constexpr std::uint32_t manual = 3;
  const Snapshot before{13, L"old:7890", L"<local>;*.owner.test",
                        L"https://owner.test/proxy.pac"};
  const Snapshot enabled{manual, L"127.0.0.1:17890", L"<local>;*.test",
                         before.pac};
  std::optional<Snapshot> original = before;
  std::optional<Snapshot> applied = enabled;
  assert(entoma_proxy::UsesListener(enabled,17890));
  auto externalListener = enabled;
  externalListener.bypass = L"external";
  externalListener.server = L"http=LOCALHOST:17890;https=[::1]:17890";
  assert(entoma_proxy::UsesListener(externalListener,17890));
  assert(!entoma_proxy::UsesListener(externalListener,7890));
  externalListener.flags = 1;
  assert(!entoma_proxy::UsesListener(externalListener,17890));

  assert(MatchesRequest(enabled, original, applied, false, manual, 17890,
                        L"<local>;*.test"));
  assert(!MatchesRequest(enabled, original, applied, false, manual, 7890,
                         L"<local>;*.test"));
  assert(!MatchesRequest(enabled, original, applied, false, manual, 17890,
                         L"<local>"));
  assert(!MatchesRequest(enabled, original, applied, true, manual, 17890,
                         L"<local>;*.test"));
  assert(!MatchesRequest(enabled, std::nullopt, applied, false, manual, 17890,
                         L"<local>;*.test"));
  assert(!MatchesRequest(enabled, original, std::nullopt, false, manual, 17890,
                         L"<local>;*.test"));

  // Every field in the native snapshot participates in the CAS. In particular,
  // a PAC-only or bypass-only external update must never be overwritten.
  for (int field = 0; field < 4; ++field) {
    auto external = enabled;
    if (field == 0) external.flags ^= 4;
    if (field == 1) external.server = L"external:8888";
    if (field == 2) external.bypass += L";external.test";
    if (field == 3) external.pac = L"https://external.test/proxy.pac";
    assert(!MatchesRequest(external, original, applied, false, manual, 17890,
                           L"<local>;*.test"));
    assert(DecideRestore(external, original, applied, false) ==
           RestoreDecision::ExternalChange);
  }
  assert(DecideRestore(enabled, original, applied, false) ==
         RestoreDecision::Restore);
  assert(DecideRestore(before, original, applied, true) ==
         RestoreDecision::Restore);
  assert(DecideRestore(enabled, original, applied, true) ==
         RestoreDecision::Restore);
  assert(DecideRestore(before, std::nullopt, std::nullopt, false) ==
         RestoreDecision::NoOwnership);
  assert(DecideRestore(enabled, original, std::nullopt, false) ==
         RestoreDecision::Unknown);
  assert(entoma_proxy::CheckRestoreReadback(before, before, applied) ==
         entoma_proxy::RestoreReadback::Restored);
  assert(entoma_proxy::CheckRestoreReadback(enabled, before, applied) ==
         entoma_proxy::RestoreReadback::StillApplied);
  auto external = enabled;
  external.pac += L"?changed";
  assert(entoma_proxy::CheckRestoreReadback(external, before, applied) ==
         entoma_proxy::RestoreReadback::ExternalChange);
  assert(DecideRestore(external, original, applied, false, true) ==
         RestoreDecision::Unknown);
  assert(DecideRestore(before, original, applied, false, true) ==
         RestoreDecision::Restore);
  assert(DecideRestore(enabled, original, applied, false, true) ==
         RestoreDecision::Restore);

  assert(entoma_proxy::ValidPort(1024));
  assert(entoma_proxy::ValidPort(65535));
  for (const auto port : {std::int64_t{-1}, std::int64_t{0},
                          std::int64_t{1023}, std::int64_t{65536},
                          std::int64_t{0x100000001}}) {
    assert(!entoma_proxy::ValidPort(port));
  }
  for (const auto* entry : {"<local>", "*.example.test", "127.0.0.1", "::1"}) {
    assert(entoma_proxy::ValidBypassEntry(entry));
  }
  for (const auto& entry : {std::string{}, std::string("bad;extra"),
                            std::string("bad\n"), std::string("bad\r"),
                            std::string("bad\t"), std::string("bad\x7f"),
                            std::string("bad\0extra", 9),
                            std::string(1025, 'a')}) {
    assert(!entoma_proxy::ValidBypassEntry(entry));
  }
  std::cout << "Windows proxy readback, full-snapshot CAS and input policy PASS\n";
}
