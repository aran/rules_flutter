#version 460 core

#include <flutter/runtime_effect.glsl>

// Fills with one colour, set from Dart. Used as a `Paint.shader`.
uniform vec4 uColor;

out vec4 fragColor;

void main() {
  fragColor = uColor;
}
