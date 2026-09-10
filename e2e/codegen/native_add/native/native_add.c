#include "native_add.h"

int32_t native_add(int32_t a, int32_t b) {
    // Added as unsigned and converted back: signed overflow is undefined in C,
    // and the Dart-side test deliberately overflows to prove the call really
    // reaches native code. Wrapping has to be defined for that to be a test
    // rather than something that happens to hold until someone runs UBSan.
    return (int32_t)((uint32_t)a + (uint32_t)b);
}
