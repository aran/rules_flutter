#version 460 core

#include <flutter/runtime_effect.glsl>

// Sums a uniform array over a count that is itself a uniform. Every Impeller
// backend compiles this; SkSL cannot ("index expression must be constant"),
// so the build keeps the Impeller stages and warns, as `flutter build` does.
uniform float uCount;
uniform float uWeights[4];

out vec4 fragColor;

void main() {
  float green = 0.0;
  for (int i = 0; i < int(uCount); i++) {
    green += uWeights[i];
  }
  fragColor = vec4(0.0, green, 0.0, 1.0);
}
