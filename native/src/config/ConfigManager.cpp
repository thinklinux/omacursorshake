#include <any>    // IWYU pragma: keep
#include <chrono> // IWYU pragma: keep
#define private public
#include <hyprland/src/errorOverlay/Overlay.hpp>
#undef private

#include <hyprland/src/config/lua/bindings/LuaBindingsInternal.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprland/src/errorOverlay/Overlay.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprlang.hpp>
#include <hyprutils/memory/UniquePtr.hpp>
#include <hyprutils/string/VarList.hpp>
#include <hyprutils/utils/ScopeGuard.hpp>

#include "../globals.hpp"
#include "../cursor.hpp"
#include "ConfigManager.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

CConfigHandler::CConfigHandler() {
    c_enabled        = conf(NS("enabled"), true, "global toggle for shake to find");
    c_threshold      = conf(NS("threshold"), 2, "minimum scale/angle difference after which the cursor is redrawn");

    c_shakeEnabled   = conf(NS("shake:enabled"), true, "enables shake to find");
    c_shakeIPC       = conf(NS("shake:ipc"), false, "enable ipc events for shake");
    c_shakeThreshold = conf(NS("shake:threshold"), 6.0f, "controls how soon a shake is detected");
    c_shakeBase      = conf(NS("shake:base"), 4.0f, "magnification level immediately after shake start");
    c_shakeSpeed     = conf(NS("shake:speed"), 4.0f, "magnification increase per second when continuing to shake");
    c_shakeInfluence = conf(NS("shake:influence"), 0.0f, "how much the speed is influenced by the current shake intensity");
    c_shakeLimit     = conf(NS("shake:limit"), 0.0f, "maximal magnification the cursor can reach");
    c_shakeTimeout   = conf(NS("shake:timeout"), 2000, "time in milliseconds the cursor will stay magnified after a shake has ended");

    c_highresEnabled  = conf(NS("hyprcursor:enabled"), true, "enable dedicated hyprcursor support");
    c_highresNearest  = conf(NS("hyprcursor:nearest"), 1, "use nearest-neighbour scaling when magnifying beyond texture size");
    c_highresFallback = conf(NS("hyprcursor:fallback"), "clientside", "shape to use when clientside cursors are being magnified");
    c_highresSize     = conf(NS("hyprcursor:resolution"), -1, "resolution in pixels to load the magnified shapes at");

    c_hwDebug     = conf(NS("hw_debug"), false, "enable hardware debug mode");
    c_ignoreWarps = conf(NS("ignore_warps"), true, "ignore cursor warps");

    HyprlandAPI::addDispatcherV2(PHANDLE, NS("magnify"), ::dispatchMagnify);
    // Config values live at hl.plugin.omacursorshake (plugin:omacursorshake:*).
    // A Lua C function in that same table overwrites the config proxy and
    // corrupts the heap on reload / animation setup / cursor damage.
    // Upstream avoids this with dynamic-cursors (config) vs dynamic_cursors (Lua).
    HyprlandAPI::addLuaFunction(PHANDLE, "omacursorshake_api", "dsp_magnify", ::luaMagnifyDispatcher);
}

bool CConfigHandler::isEnabled() {
    return c_enabled->value() && g_pHyprRenderer->m_mostHzMonitor && g_pDynamicCursors;
}

void CConfigHandler::showError(const std::string& err) {
    if (ErrorOverlay::overlay()->active() && !ErrorOverlay::overlay()->m_queuedDestroy) {
        Log::logger->log(Log::ERR, "[omacursorshake] not overriding error overlay: {}", err);
        return;
    }

    ErrorOverlay::overlay()->m_queuedDestroy = false;
    ErrorOverlay::overlay()->queueCreate("Your omacursorshake config has errors:\n" + err, ErrorOverlay::Colors::ERROR);
}

SP<CBoolValue> CConfigHandler::conf(const char* name, bool def, const char* desc) {
    auto val = makeShared<CBoolValue>(name, desc, def);
    HyprlandAPI::addConfigValueV2(PHANDLE, val);
    return val;
}

SP<CIntValue> CConfigHandler::conf(const char* name, int def, const char* desc) {
    auto val = makeShared<CIntValue>(name, desc, def);
    HyprlandAPI::addConfigValueV2(PHANDLE, val);
    return val;
}

SP<CStringValue> CConfigHandler::conf(const char* name, const char* def, const char* desc) {
    auto val = makeShared<CStringValue>(name, desc, std::string{def});
    HyprlandAPI::addConfigValueV2(PHANDLE, val);
    return val;
}

SP<CFloatValue> CConfigHandler::conf(const char* name, float def, const char* desc) {
    auto val = makeShared<CFloatValue>(name, desc, def);
    HyprlandAPI::addConfigValueV2(PHANDLE, val);
    return val;
}

SDispatchResult dispatchMagnify(std::string in) {
    Hyprutils::String::CVarList args = in;
    SDispatchResult             result;
    std::optional<int>          duration;
    std::optional<float>        size;

    try {
        auto it = args.begin();
        if (it != args.end() && *it != "") {
            duration = std::stoi(*it);
            it++;
            if (it != args.end())
                size = std::stof(*it);
        }
    } catch (...) {
        result.error = "invalid types for arguments";
        Log::logger->log(Log::ERR, "[omacursorshake] dispatcher `magnify` received invalid args: {}", in);
    }

    if (g_pDynamicCursors)
        g_pDynamicCursors->dispatchMagnify(duration, size);
    return result;
}

int luaMagnifyDispatcher(lua_State* L) {
    if (!lua_istable(L, 1))
        return Config::Lua::Bindings::Internal::configError(L, "dsp_magnify: expected a table { duration, size }");

    std::optional<int>   duration;
    std::optional<float> size;

    {
        Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });
        lua_getfield(L, 1, "duration");
        if (!lua_isnil(L, -1)) {
            if (!lua_isinteger(L, -1))
                return Config::Lua::Bindings::Internal::configError(L, "dsp_magnify: `duration` must be an integer");
            duration = lua_tointeger(L, -1);
        }
    }

    {
        Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });
        lua_getfield(L, 1, "size");
        if (!lua_isnil(L, -1)) {
            if (!lua_isnumber(L, -1))
                return Config::Lua::Bindings::Internal::configError(L, "dsp_magnify: `size` must be a number");
            size = lua_tonumber(L, -1);
        }
    }

    auto dispatch = [](lua_State* L) -> int {
        std::optional<int>   duration;
        std::optional<float> size;
        if (!lua_isnil(L, lua_upvalueindex(1)))
            duration = lua_tointeger(L, lua_upvalueindex(1));
        if (!lua_isnil(L, lua_upvalueindex(2)))
            size = lua_tonumber(L, lua_upvalueindex(2));
        if (g_pDynamicCursors)
            g_pDynamicCursors->dispatchMagnify(duration, size);
        return 0;
    };

    if (duration.has_value())
        lua_pushinteger(L, duration.value());
    else
        lua_pushnil(L);

    if (size.has_value())
        lua_pushnumber(L, size.value());
    else
        lua_pushnil(L);

    lua_pushcclosure(L, dispatch, 2);
    return 1;
}
