#include "utils.hpp"

#include <cmath>

void SModeResult::clamp(double angle, double scale, double stretch) {
    if (std::abs(this->rotation) < angle)
        this->rotation = 0;

    if (std::abs(1 - this->scale) < scale)
        this->scale = 1;

    if (std::abs(1 - this->stretch.magnitude.x) < stretch && std::abs(1 - this->stretch.magnitude.y) < stretch)
        this->stretch.magnitude = Vector2D{1, 1};
}

bool SModeResult::hasDifference(SModeResult* other, double angle, double scale, double stretch) {
    return std::abs(other->rotation - this->rotation) > angle || std::abs(other->scale - this->scale) > scale || std::abs(other->stretch.angle - this->stretch.angle) > angle ||
        std::abs(other->stretch.magnitude.x - this->stretch.magnitude.x) > stretch || std::abs(other->stretch.magnitude.y - this->stretch.magnitude.y) > stretch;
}
