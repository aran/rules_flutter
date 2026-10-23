#version 460 core

precision highp float;

uniform vec2 uSize;

out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / uSize;
    fragColor = vec4(uv, 0.0, 1.0);
}
