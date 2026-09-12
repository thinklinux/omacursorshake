#pragma once

#include <hyprutils/math/Vector2D.hpp>

using namespace Hyprutils::Math;

enum EModeUpdate {
    MOVE,
    TICK
};

struct SModeResult {
    double rotation = 0;
    double scale    = 1;

    struct {
        double   angle     = 0;
        Vector2D magnitude = Vector2D{1, 1};
    } stretch;

    void clamp(double angle, double scale, double stretch);
    bool hasDifference(SModeResult* other, double angle, double scale, double stretch);
};
