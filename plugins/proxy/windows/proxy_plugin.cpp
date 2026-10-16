#include "proxy_plugin.h"
#include "proxy_state.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <WinInet.h>
#include <Ras.h>
#include <RasError.h>
#include <vector>
#include <iostream>

#pragma comment(lib, "wininet")
#pragma comment(lib, "Rasapi32")

// For getPlatformVersion; remove unless needed for your plugin implementation.
#include <VersionHelpers.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <sstream>

namespace {
using ProxySnapshot = entoma_proxy::Snapshot;
std::optional<ProxySnapshot> original;
std::optional<ProxySnapshot> applied;
bool restorationPending = false;
bool recoveryRequired = false;
bool ownershipUncertain = false;

void releaseOwnership() {
  original.reset();
  applied.reset();
  restorationPending = false;
  recoveryRequired = false;
  ownershipUncertain = false;
}

bool readProxy(ProxySnapshot& value) {
  INTERNET_PER_CONN_OPTIONW options[4]{};
  const DWORD names[] = {INTERNET_PER_CONN_FLAGS_UI, INTERNET_PER_CONN_PROXY_SERVER,
    INTERNET_PER_CONN_PROXY_BYPASS, INTERNET_PER_CONN_AUTOCONFIG_URL};
  for (int i = 0; i < 4; ++i) options[i].dwOption = names[i];
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 4;
  list.pOptions = options;
  DWORD size = sizeof(list);
  bool ok = InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size) != FALSE;
  if (!ok) {
    // A failed query may still allocate string values. Release them before
    // retrying with the pre-IE8 flags option.
    for (int i = 1; i < 4; ++i) {
      if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
      options[i].Value.pszValue = nullptr;
    }
    options[0].dwOption = INTERNET_PER_CONN_FLAGS;
    size = sizeof(list);
    ok = InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                             &list, &size) != FALSE;
  }
  if (ok) {
    value.flags = options[0].Value.dwValue;
    value.server = options[1].Value.pszValue ? options[1].Value.pszValue : L"";
    value.bypass = options[2].Value.pszValue ? options[2].Value.pszValue : L"";
    value.pac = options[3].Value.pszValue ? options[3].Value.pszValue : L"";
  }
  for (int i = 1; i < 4; ++i) if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
  return ok;
}

enum class WriteResult { Failed, NeedsRefresh, Success };

WriteResult writeProxy(const ProxySnapshot& value) {
  INTERNET_PER_CONN_OPTIONW options[4]{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = value.flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = const_cast<LPWSTR>(value.server.c_str());
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = const_cast<LPWSTR>(value.bypass.c_str());
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue = const_cast<LPWSTR>(value.pac.c_str());
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 4;
  list.pOptions = options;
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof(list))) return WriteResult::Failed;
  return InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0) &&
      InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0) ? WriteResult::Success : WriteResult::NeedsRefresh;
}

std::wstring wide(const std::string& value) {
  if (value.empty()) return L"";
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) return L"";
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), length);
  return result;
}

struct ProxyRequest {
  int port;
  std::wstring bypass;
};

bool parseRequest(const flutter::EncodableValue* arguments,
                  ProxyRequest& request) {
  if (!arguments) return false;
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (!map || map->size() != 2) return false;
  const auto port = map->find(flutter::EncodableValue("port"));
  const auto bypass = map->find(flutter::EncodableValue("bypassDomain"));
  if (port == map->end() || bypass == map->end()) return false;
  std::int64_t number;
  if (const auto* value = std::get_if<std::int32_t>(&port->second)) {
    number = *value;
  } else if (const auto* value = std::get_if<std::int64_t>(&port->second)) {
    number = *value;
  } else {
    return false;
  }
  if (!entoma_proxy::ValidPort(number)) return false;
  const auto* entries = std::get_if<flutter::EncodableList>(&bypass->second);
  if (!entries || entries->size() > 256) return false;
  std::wstring joined;
  std::size_t bytes = 0;
  for (const auto& entry : *entries) {
    const auto* text = std::get_if<std::string>(&entry);
    if (!text || !entoma_proxy::ValidBypassEntry(*text)) return false;
    bytes += text->size();
    if (bytes > 16384) return false;
    const auto decoded = wide(*text);
    if (decoded.empty()) return false;  // Includes invalid UTF-8.
    if (!joined.empty()) joined += L";";
    joined += decoded;
  }
  request = {static_cast<int>(number), std::move(joined)};
  return true;
}
}

bool startProxy(const ProxyRequest& request) {
  if (restorationPending || recoveryRequired || (original && !applied)) return false;
  ProxySnapshot current;
  if (!readProxy(current)) return false;
  if (applied && !(current == *applied)) return false;
  const bool firstOwnership = !original.has_value();
  if (firstOwnership) original = current;
  ProxySnapshot next = current;
  next.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
  next.server = L"127.0.0.1:" + std::to_wstring(request.port);
  next.bypass = request.bypass;
  const auto result = writeProxy(next);
  if (result != WriteResult::Success) {
    ProxySnapshot actual;
    if (!readProxy(actual)) {
      applied = next;
      recoveryRequired = true;
      ownershipUncertain = true;
      return false;
    }
    if (actual == current) {
      if (firstOwnership) releaseOwnership();
      return false;
    }
    // Do not roll back a different program's concurrent change or claim that
    // arbitrary readback as our applied snapshot.
    if (!(actual == next)) {
      applied = next;
      recoveryRequired = true;
      ownershipUncertain = true;
      return false;
    }
    const auto rollback = writeProxy(current);
    if (rollback == WriteResult::Success && readProxy(actual) && actual == current) {
      if (firstOwnership) releaseOwnership();
      else applied = current;
      recoveryRequired = false;
    } else {
      // Only these two snapshots can be attributed to this transaction. A
      // subsequent stop still performs the full snapshot compare-and-restore.
      const bool read = readProxy(actual);
      applied = read && actual == current ? current : next;
      ownershipUncertain = !read || (!(actual == current) && !(actual == next));
      recoveryRequired = true;
    }
    return false;
  }
  applied = next;
  recoveryRequired = false;
  return true;
}

bool stopProxy() {
  if (!original) return true;
  ProxySnapshot current;
  if (!readProxy(current)) { recoveryRequired = true; return false; }
  switch (entoma_proxy::DecideRestore(current, original, applied,
                                     restorationPending, ownershipUncertain)) {
    case entoma_proxy::RestoreDecision::NoOwnership:
      return true;
    case entoma_proxy::RestoreDecision::ExternalChange:
      releaseOwnership();
      return true;
    case entoma_proxy::RestoreDecision::Unknown:
      return false;
    case entoma_proxy::RestoreDecision::Restore:
      break;
  }
  ownershipUncertain = false;
  const auto restored = writeProxy(*original);
  if (restored == WriteResult::Failed) {
    ProxySnapshot actual;
    const bool read = readProxy(actual);
    if (read && actual == *original) restorationPending = true;
    ownershipUncertain = !read ||
        (!(actual == *original) && (!applied || !(actual == *applied)));
    recoveryRequired = true;
    return false;
  }
  restorationPending = restored == WriteResult::NeedsRefresh;
  recoveryRequired = restorationPending;
  if (restorationPending) return false;
  ProxySnapshot actual;
  if (!readProxy(actual)) {
    restorationPending = true;
    recoveryRequired = true;
    ownershipUncertain = true;
    return false;
  }
  if (entoma_proxy::CheckRestoreReadback(actual, *original, applied) ==
      entoma_proxy::RestoreReadback::StillApplied) {
    // A policy may acknowledge the call without changing our values. Keep
    // ownership and the caller's live listener so a retry remains possible.
    restorationPending = false;
    recoveryRequired = true;
    return false;
  }
  // A concurrent external update is preserved; it is no longer ours to undo.
  releaseOwnership();
  return true;
}

namespace proxy
{

  // static
  void ProxyPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarWindows *registrar)
  {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "proxy",
            &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<ProxyPlugin>();

    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto &call, auto result)
        {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  ProxyPlugin::ProxyPlugin() {}

  ProxyPlugin::~ProxyPlugin() { stopProxy(); }

  void ProxyPlugin::HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    if (method_call.method_name().compare("StopProxy") == 0)
    {
      result->Success(stopProxy());
    }
    else if (method_call.method_name() == "StartProxy" ||
             method_call.method_name() == "GetProxyStatus")
    {
      ProxyRequest request{};
      if (!parseRequest(method_call.arguments(), request)) {
        result->Error("INVALID_ARGUMENT", "Expected a valid local proxy port and bypass list.");
        return;
      }
      if (method_call.method_name() == "StartProxy") {
        result->Success(startProxy(request));
        return;
      }
      ProxySnapshot current;
      if (!readProxy(current)) {
        recoveryRequired = original.has_value();
        result->Error("PROXY_READ_FAILED", "Unable to read current-user system proxy settings.");
        return;
      }
      const bool matches = entoma_proxy::MatchesRequest(
          current, original, applied, recoveryRequired || restorationPending,
          PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY, request.port, request.bypass);
      result->Success(flutter::EncodableMap{
          {flutter::EncodableValue("available"), flutter::EncodableValue(true)},
          {flutter::EncodableValue("matches"), flutter::EncodableValue(matches)},
          {flutter::EncodableValue("owned"), flutter::EncodableValue(original.has_value())},
          {flutter::EncodableValue("usesListener"),
           flutter::EncodableValue(entoma_proxy::UsesListener(current, request.port))},
          {flutter::EncodableValue("restorationPending"),
           flutter::EncodableValue(recoveryRequired || restorationPending)},
      });
    }
    else
    {
      result->NotImplemented();
    }
  }
} // namespace proxy
