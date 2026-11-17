#version 460 core

#include <flutter/runtime_effect.glsl>
#include "common.glsl"

uniform vec2 uSize;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  fragColor = vec4(glowColor(uv), 1.0);
}
