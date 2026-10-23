#version 460 core

#include <flutter/runtime_effect.glsl>
#include "common.glsl"

out vec4 fragColor;

void main() {
    fragColor = sharedColor();
}
