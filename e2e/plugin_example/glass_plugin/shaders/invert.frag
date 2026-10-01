#version 460 core

#include <flutter/runtime_effect.glsl>
#include "premultiplied.glsl"

// Inverts what is behind it. Used as `ImageFilter.shader`, which sets the
// first two floats to the input's size and the first sampler to the input.
uniform vec2 uSize;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
  fragColor = invertPremultiplied(
      texture(uTexture, FlutterFragCoord().xy / uSize));
}
