#pragma once

#include <hyprlang.hpp>
#include <hyprland/src/SharedDefs.hpp>

struct lua_State;
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>
#include <hyprland/src/config/values/types/StringValue.hpp>

#define NS(a) "plugin:omacursorshake:" a
#define CONFIG(a) g_pConfigHandler->c_##a->value()

using namespace Config::Values;

class CConfigHandler {
  public:
    SP<CBoolValue>   c_enabled;
    SP<CIntValue>    c_threshold;

    SP<CBoolValue>  c_shakeEnabled;
    SP<CBoolValue>  c_shakeIPC;
    SP<CFloatValue> c_shakeThreshold;
    SP<CFloatValue> c_shakeBase;
    SP<CFloatValue> c_shakeSpeed;
    SP<CFloatValue> c_shakeInfluence;
    SP<CFloatValue> c_shakeLimit;
    SP<CIntValue>   c_shakeTimeout;

    SP<CBoolValue>   c_highresEnabled;
    SP<CIntValue>    c_highresNearest;
    SP<CStringValue> c_highresFallback;
    SP<CIntValue>    c_highresSize;

    SP<CBoolValue> c_hwDebug;
    SP<CBoolValue> c_ignoreWarps;

    CConfigHandler();

    bool isEnabled();
    void showError(const std::string& err);

  private:
    SP<CBoolValue>   conf(const char* name, bool def, const char* desc);
    SP<CIntValue>    conf(const char* name, int def, const char* desc);
    SP<CStringValue> conf(const char* name, const char* def, const char* desc);
    SP<CFloatValue>  conf(const char* name, float def, const char* desc);
};

inline UP<CConfigHandler> g_pConfigHandler;

SDispatchResult dispatchMagnify(std::string args);
int             luaMagnifyDispatcher(lua_State* L);
