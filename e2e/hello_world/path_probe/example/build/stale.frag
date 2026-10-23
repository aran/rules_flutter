// Stale build output inside the fixture example app: it matches the old
// whole-tree "**/*.frag" shader glob, so a spoke that still globs the
// package root picks machine-local output up as a shader include.
precision mediump float;

void main() {
  gl_FragColor = vec4(0.0);
}
