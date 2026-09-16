#include "../globals.hpp"
#include "../config/ConfigManager.hpp"
#include "Shake.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprland/src/animation/AnimationManager.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#include <hyprutils/animation/AnimationConfig.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/event/EventBus.hpp>

CShake::CShake() {
    // the timing and the bezier are quite crucial, as things will break down if they are just changed slightly
    // this is not ideal and should be fixed some time in the future, then it may be made configurable (if it has a substantial enough effect on behaviour)

    int time = 400;

    // add custom bezier (and read it after config reload)
    static constexpr const char* bezier = "dynamic-cursors-magnification";
    Animation::mgr()->addBezierWithName(bezier, {0.22, 1.0}, {0.36, 1.0});
    // Keep the listener on this object so PLUGIN_EXIT unregisters it. A static
    // listener would keep firing into unloaded plugin text after dlclose.
    m_bezierReload = Event::bus()->m_events.config.reloaded.listen([]() {
        Animation::mgr()->addBezierWithName(bezier, {0.22, 1.0}, {0.36, 1.0});
    });

    // Member, not static: a .so-static SP survives dlclose with STB_GNU_UNIQUE
    // and then dangles on the next load. pValues is a weak self-ref (Hyprland idiom).
    m_animProps                    = makeShared<SAnimationPropertyConfig>();
    m_animProps->internalBezier    = bezier;
    m_animProps->internalSpeed     = time / 100.f;
    m_animProps->internalEnabled   = 1;
    m_animProps->pValues           = m_animProps;

    Animation::mgr()->createAnimation(1.f, zoom, m_animProps, AVARDAMAGE_NONE);
}

CShake::~CShake() {
    m_bezierReload.reset();
    if (zoom) {
        zoom->resetAllCallbacks();
        if (zoom->ok())
            zoom->warp(false, true);
    }
}

float CShake::clampZoom(float z) const {
    if (!std::isfinite(z) || z < 1.f)
        return 1.f;
    float cap = CONFIG(shakeLimit);
    if (!(cap > 1.f) || !std::isfinite(cap))
        cap = kMaxCursorZoom;
    cap = std::min(cap, kMaxCursorZoom);
    return std::min(z, cap);
}

double CShake::update(Vector2D pos) {

    int max = 60;
    if (g_pHyprRenderer->m_mostHzMonitor) {
        const double hz = g_pHyprRenderer->m_mostHzMonitor->m_refreshRate;
        if (std::isfinite(hz) && hz > 0)
            max = std::clamp(static_cast<int>(std::lround(hz)), 1, kMaxShakeHz);
    }
    samples.resize(max);
    samples_distance.resize(max);
    samples_index = std::min(samples_index, max - 1);

    int previous                    = samples_index == 0 ? max - 1 : samples_index - 1;
    samples[samples_index]          = Vector2D{pos};
    samples_distance[samples_index] = samples[samples_index].distance(samples[previous]);
    samples_index                   = (samples_index + 1) % max; // increase for next sample

    // The idea for this algorithm was largely inspired by KDE Plasma
    // https://invent.kde.org/plasma/kwin/-/blob/master/src/plugins/shakecursor/shakedetector.cpp

    // calculate total distance travelled
    double trail = 0;
    for (double distance : samples_distance)
        trail += distance;

    // calculate diagonal of bounding box travelled within
    double left = 1e100, right = 0, bottom = 0, top = 1e100;
    for (Vector2D position : samples) {
        left   = std::min(left, position.x);
        right  = std::max(right, position.x);
        top    = std::min(top, position.y);
        bottom = std::max(bottom, position.y);
    }
    double diagonal = Vector2D{left, top}.distance(Vector2D(right, bottom));

    // if diagonal sufficiently large and over threshold
    double amount = (trail / diagonal) - CONFIG(shakeThreshold);
    if (diagonal > 100 && amount > 0) {
        float delta = 1.F / g_pHyprRenderer->m_mostHzMonitor->m_refreshRate;

        float next = this->zoom->goal();

        if (!started)
            next = CONFIG(shakeBase);                                                      // start on base zoom
        next += delta * (CONFIG(shakeSpeed) + (amount * amount) * CONFIG(shakeInfluence)); // increase when moving
        next = clampZoom(next);

        *this->zoom = next;
        this->end   = steady_clock::now() + milliseconds(CONFIG(shakeTimeout));
        started     = true;
    } else {
        if (started && end < std::chrono::steady_clock::now()) {
            *this->zoom = 1;
            started     = false;
        }
    }

    if (CONFIG(shakeIPC)) {
        if (started || this->zoom->value() > 1) {
            if (!ipc) {
                g_pEventManager->postEvent(SHyprIPCEvent{IPC_SHAKE_START});
                ipc = true;
            }

            g_pEventManager->postEvent(SHyprIPCEvent{IPC_SHAKE_UPDATE, std::format("{},{},{},{},{}", (int)pos.x, (int)pos.y, trail, diagonal, this->zoom->value())});
        } else {
            if (ipc) {
                g_pEventManager->postEvent(SHyprIPCEvent{IPC_SHAKE_END});
                ipc = false;
            }
        }
    }

    return this->zoom->value();
}

void CShake::force(std::optional<int> duration, std::optional<float> size) {
    started     = true;
    *this->zoom = clampZoom(size.value_or(CONFIG(shakeBase)));
    this->end   = steady_clock::now() + milliseconds(duration.value_or(CONFIG(shakeTimeout)));
}

void CShake::warp(Vector2D old, Vector2D pos) {
    auto delta = pos - old;

    for (auto& sample : samples)
        sample += delta;
}
