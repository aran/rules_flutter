#version 460 core

#include <flutter/runtime_effect.glsl>
#include "common.glsl"

uniform vec2 uSize;

out vec4 fragColor;

void main() {
  fragColor = tint(FlutterFragCoord().xy / uSize);
}
