#version 460 core

#include <flutter/runtime_effect.glsl>

// Inverts what is behind it. Used as `ImageFilter.shader`, which sets the
// first two floats to the input's size and the first sampler to the input.
uniform vec2 uSize;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
  vec4 c = texture(uTexture, FlutterFragCoord().xy / uSize);
  // Premultiplied: invert against alpha, not against 1.
  fragColor = vec4(c.a - c.rgb, c.a);
}
