#include <any>    // IWYU pragma: keep
#include <chrono> // IWYU pragma: keep
#define private public
#include <hyprland/src/pointer/cursor/CursorManager.hpp>
#undef private

#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprlang.hpp>
#include <hyprcursor/hyprcursor.hpp>
#include <hyprutils/memory/UniquePtr.hpp>
#include <hyprland/src/config/ConfigValue.hpp>

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <future>

#include "highres.hpp"
#include "config/ConfigManager.hpp"

CHighresHandler::CHighresHandler() {
    // Do not call update() here: CDynamicCursors is still being constructed, so
    // g_pDynamicCursors is null and isEnabled() is false. PLUGIN_INIT calls
    // updateTheme() once the unique_ptr is assigned.
    //
    // The listener must be a member. A static lambda capturing `this` keeps a
    // dangling CHighresHandler* after PLUGIN_EXIT / object rebuild.
    m_configReload = Event::bus()->m_events.config.reloaded.listen([this]() { update(); });
}

CHighresHandler::~CHighresHandler() {
    m_configReload.reset();
    if (managerFuture) {
        managerFuture->wait();
        managerFuture.reset();
    }
    manager = nullptr;
}

static void hcLogger(enum eHyprcursorLogLevel level, char* message) {
    // hyprcursor invokes this from the async theme loader. Hyprland's logger
    // is not thread-safe; logging here has aborted the compositor.
    (void)level;
    (void)message;
}

bool CHighresHandler::hyprcursorWanted() {
    static auto PINT = CConfigValue<Hyprlang::INT>("cursor:enable_hyprcursor");
    return *PINT != 0;
}

std::string CHighresHandler::themeName() {
    std::string name = Pointer::Cursor::mgr()->m_theme;
    if (!name.empty())
        return name;
    if (const char* env = getenv("HYPRCURSOR_THEME"); env && *env)
        return env;
    if (const char* env = getenv("XCURSOR_THEME"); env && *env)
        return env;
    return "Adwaita";
}

unsigned int CHighresHandler::targetSize() {
    if (CONFIG(highresSize) != -1)
        return CONFIG(highresSize);
    const float base = Pointer::Cursor::mgr()->m_currentStyleInfo.size;
    return std::max(1, (int)std::round(base * CONFIG(shakeBase) * 1.5f));
}

void CHighresHandler::update() {
    if (!g_pConfigHandler->isEnabled() || !CONFIG(highresEnabled) || !CONFIG(shakeEnabled)) {
        manager       = nullptr;
        managerFuture = nullptr;
        xcursor       = nullptr;
        texture       = nullptr;
        buffer        = nullptr;
        return;
    }

    const auto         name = themeName();
    const unsigned int size = targetSize();
    style                   = Hyprcursor::SCursorStyleInfo{size};

    if (hyprcursorWanted()) {
        if (!(manager && loadedName == name && loadedSize == size) && !managerFuture) {
            loadedSize = size;
            loadedName = name;

            Log::logger->log(Log::INFO, "[omacursorshake] loading hyprcursor theme '{}' at {}", name, size);

            auto fut = std::async(std::launch::async, [=, style = style]() -> UP<Hyprcursor::CHyprcursorManager> {
                auto options                 = Hyprcursor::SManagerOptions();
                options.logFn                = hcLogger;
                options.allowDefaultFallback = true;

                // Do not log on this thread. Hyprland's logger is not safe for
                // concurrent use from plugin workers and has aborted sessions.
                auto mgr = makeUnique<Hyprcursor::CHyprcursorManager>(name.empty() ? nullptr : name.c_str(), options);
                if (!mgr->valid())
                    return nullptr;
                mgr->loadThemeStyle(style);
                return mgr;
            });

            manager       = nullptr;
            managerFuture = makeUnique<std::future<UP<Hyprcursor::CHyprcursorManager>>>(std::move(fut));
        }
    } else {
        manager       = nullptr;
        managerFuture = nullptr;
    }

    // Own CXCursorManager so we can load 96px Adwaita frames without
    // changing the compositor's 24px theme. hyprcursor cannot read XCursor
    // themes; without this, shake nearest-neighbour-scales the 24px bitmap.
    if (!xcursor)
        xcursor = makeUnique<CXCursorManager>();
    if (xcLoadedName != name || xcLoadedSize != size) {
        xcursor->syncGsettings();
        xcursor->loadTheme(name, (int)size, 1.0f);
        xcLoadedName = name;
        xcLoadedSize = size;
        Log::logger->log(Log::INFO, "[omacursorshake] loaded XCursor theme '{}' at {}", name, size);
    }
}

void CHighresHandler::adoptBuffer(SP<Pointer::Cursor::CCursorBuffer> buf) {
    buffer  = buf;
    texture = g_pHyprRenderer->createTexture(SP<Aquamarine::IBuffer>(buffer));
}

bool CHighresHandler::tryHyprcursor(const std::string& name) {
    if (!manager)
        return false;

    Hyprcursor::SCursorShapeData data = manager->getShape(name.c_str(), style);
    if (data.images.empty())
        data = manager->getShape(CONFIG(highresFallback).c_str(), style);
    if (data.images.empty())
        return false;

    adoptBuffer(makeShared<Pointer::Cursor::CCursorBuffer>(data.images[0].surface,
                                                           Vector2D{data.images[0].size, data.images[0].size},
                                                           Vector2D{data.images[0].hotspotX, data.images[0].hotspotY}));
    return texture != nullptr;
}

bool CHighresHandler::tryXcursor(const std::string& name) {
    if (!xcursor)
        return false;

    const int size = (int)style.size;
    auto      tryShape = [&](const std::string& n) -> bool {
        auto cursors = xcursor->getShape(n, size, 1.0f);
        if (!cursors || cursors->images.empty())
            return false;
        auto& im = cursors->images[0];
        if (im.pixels.empty() || im.size.x <= 0 || im.size.y <= 0)
            return false;
        adoptBuffer(makeShared<Pointer::Cursor::CCursorBuffer>(reinterpret_cast<const uint8_t*>(im.pixels.data()), im.size, im.hotspot));
        return texture != nullptr;
    };

    if (tryShape(name))
        return true;
    if (tryShape("left_ptr"))
        return true;
    return tryShape("default");
}

void CHighresHandler::loadShape(const std::string& name) {
    if (!name.empty())
        shape = name;

    if (!manager && managerFuture && managerFuture->wait_for(std::chrono::seconds(0)) == std::future_status::ready) {
        Log::logger->log(Log::INFO, "[omacursorshake] hyprcursor theme ready");
        manager       = managerFuture->get();
        managerFuture = nullptr;
        if (manager)
            update();
    }

    if (tryHyprcursor(shape))
        return;
    if (tryXcursor(shape))
        return;

    texture = nullptr;
    buffer  = nullptr;
}

void CHighresHandler::tick() {
    if (!manager && managerFuture && managerFuture->wait_for(std::chrono::seconds(0)) == std::future_status::ready)
        loadShape(shape);
}

SP<Render::ITexture> CHighresHandler::getTexture() {
    return texture;
}

SP<Pointer::Cursor::CCursorBuffer> CHighresHandler::getBuffer() {
    return buffer;
}
