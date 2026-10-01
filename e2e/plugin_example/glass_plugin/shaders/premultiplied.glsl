// Shared by the package's shaders, as a published package's GLSL often is:
// `#include`d by name from beside them.

// [c] inverted against its own alpha, as premultiplied colour must be.
vec4 invertPremultiplied(vec4 c) {
  return vec4(c.a - c.rgb, c.a);
}
