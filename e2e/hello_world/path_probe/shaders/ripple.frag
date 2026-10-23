// Fixture fragment shader: the spoke must expose it and may include
// siblings from this directory only, never example/build output.
precision mediump float;

uniform vec2 uSize;

void main() {
  gl_FragColor = vec4(gl_FragCoord.xy / uSize, 0.0, 1.0);
}
