#include <hyprland/src/helpers/AnimatedVariable.hpp>
#include <hyprutils/animation/AnimatedVariable.hpp>
#include <hyprutils/animation/AnimationConfig.hpp>
#include <hyprutils/math/Vector2D.hpp>
#include <hyprutils/memory/SharedPtr.hpp>
#include <hyprutils/signal/Listener.hpp>
#include <optional>
#include <vector>

#define IPC_SHAKE_START  "shakestart"
#define IPC_SHAKE_UPDATE "shakeupdate"
#define IPC_SHAKE_END    "shakeend"

using namespace Hyprutils::Math;
using namespace Hyprutils::Animation;
using namespace std::chrono;

// Hard ceiling for shake zoom. plugin:omacursorshake:shake:limit 0 means
// "unlimited" upstream; that grew damage boxes until pixman aborted Hyprland.
constexpr float kMaxCursorZoom = 32.f;
constexpr int   kMaxShakeHz    = 240;

class CShake {
  public:
    CShake();
    ~CShake();

    /* calculates the new zoom factor for the current pos */
    double update(Vector2D pos);
    /* called when a cursor warp has happened (to avoid magnifying on warps) */
    void   warp(Vector2D old, Vector2D pos);

    /* force magnification regardless of speed now */
    void force(std::optional<int> duration, std::optional<float> size);

  private:
    float clampZoom(float z) const;

    /* tracks whether the current shake has already been announced in the ipc */
    bool ipc = false;

    bool                     started = false;
    PHLANIMVAR<float>        zoom;
    SP<SAnimationPropertyConfig> m_animProps;
    steady_clock::time_point end;

    /* ringbuffer for last samples */
    std::vector<Vector2D> samples;
    /* we also store the distance for each sample to the last, so we do only compute this once */
    std::vector<double>   samples_distance;
    int                   samples_index = 0;

    Hyprutils::Signal::CHyprSignalListener m_bezierReload;
};
