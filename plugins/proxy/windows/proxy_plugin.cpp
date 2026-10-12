#include "proxy_plugin.h"

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
struct ProxySnapshot {
  DWORD flags = 0;
  std::wstring server;
  std::wstring bypass;
  std::wstring pac;
  bool operator==(const ProxySnapshot& other) const {
    return flags == other.flags && server == other.server && bypass == other.bypass && pac == other.pac;
  }
};
std::optional<ProxySnapshot> original;
std::optional<ProxySnapshot> applied;
bool restorationPending = false;

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
  if (!ok) { options[0].dwOption = INTERNET_PER_CONN_FLAGS; ok = InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size) != FALSE; }
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
}

bool startProxy(const int port, const flutter::EncodableList& bypassDomain) {
  if (restorationPending || (original && !applied) || port < 1024 || port > 65535) return false;
  ProxySnapshot current;
  if (!readProxy(current)) return false;
  if (applied && !(current == *applied)) return false;
  const bool firstOwnership = !original.has_value();
  if (firstOwnership) original = current;
  ProxySnapshot next = current;
  next.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
  next.server = L"127.0.0.1:" + std::to_wstring(port);
  next.bypass.clear();
  for (const auto& domain : bypassDomain) {
    const auto* text = std::get_if<std::string>(&domain);
    if (!text) return false;
    if (!next.bypass.empty()) next.bypass += L";";
    next.bypass += wide(*text);
  }
  const auto result = writeProxy(next);
  if (result != WriteResult::Success) {
    const auto rollback = writeProxy(current);
    if (rollback == WriteResult::Success) {
      if (firstOwnership) { original.reset(); applied.reset(); }
      else applied = current;
      restorationPending = false;
    } else {
      ProxySnapshot actual;
      if (readProxy(actual)) applied = actual;
      restorationPending = false;
    }
    return false;
  }
  applied = next;
  return true;
}

bool stopProxy() {
  if (!original) return true;
  ProxySnapshot current;
  if (!readProxy(current)) return false;
  const auto& expected = restorationPending ? original : applied;
  if (expected && !(current == *expected)) {
    original.reset(); applied.reset(); restorationPending = false; return true;
  }
  if (!applied && !restorationPending) return false;
  const auto restored = writeProxy(*original);
  if (restored == WriteResult::Failed) return false;
  restorationPending = restored == WriteResult::NeedsRefresh;
  if (restorationPending) return false;
  original.reset(); applied.reset(); restorationPending = false; return true;
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
    else if (method_call.method_name().compare("StartProxy") == 0)
    {
      auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      auto port = std::get<int>(arguments->at(flutter::EncodableValue("port")));
      auto bypassDomain = std::get<flutter::EncodableList>(arguments->at(flutter::EncodableValue("bypassDomain")));
      result->Success(startProxy(port, bypassDomain));
    }
    else
    {
      result->NotImplemented();
    }
  }
} // namespace proxy
