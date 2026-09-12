#pragma once

#include <any>    // IWYU pragma: keep
#include <chrono> // IWYU pragma: keep
#define private public
#include <hyprland/src/pointer/PointerManager.hpp>
#undef private

#include <hyprcursor/hyprcursor.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprutils/math/Vector2D.hpp>

#include "mode/utils.hpp"
#include "other/Shake.hpp"
#include "highres.hpp"

class CDynamicCursors {
  public:
    CDynamicCursors();
    ~CDynamicCursors();

    void onCursorMoved(Pointer::CPointerManager* pointers);
    void onTick(Pointer::CPointerManager* pointers);

    void renderSoftware(Pointer::CPointerManager* pointers, PHLMONITOR pMonitor, const Time::steady_tp& now, CRegion& damage, std::optional<Vector2D> overridePos,
                        bool screencopy, bool forceRender);
    void damageSoftware(Pointer::CPointerManager* pointers);
    SP<Aquamarine::IBuffer> renderHardware(Pointer::CPointerManager* pointers, SP<Pointer::CPointerManager::SMonitorPointerState> state, SP<Render::ITexture> texture);
    bool                    setHardware(Pointer::CPointerManager* pointers, SP<Pointer::CPointerManager::SMonitorPointerState> state, SP<Aquamarine::IBuffer> buf);

    void setShape(const std::string& name);
    void unsetShape();
    void updateTheme();

    void setMove();

    void dispatchMagnify(std::optional<int> duration, std::optional<float> size);

  private:
    SP<CEventLoopTimer> tick;
    CHighresHandler     highres;

    SModeResult resultMode;
    double      resultShake = 1;
    Vector2D    lastPos;
    SModeResult resultShown;

    bool zoomSoftware = false;

    CShake shake;

    bool isMove = false;

    void calculate(EModeUpdate type);
};

inline UP<CDynamicCursors> g_pDynamicCursors;
