// Custom Flutter Windows runner — Approach 3 example.
//
// Minimal Win32 runner compiled with cc_binary (rules_cc).
// Uses the C API (flutter_windows.h) directly.

#include <windows.h>

#include <cstdlib>

#include "flutter_windows.h"

int WINAPI WinMain(HINSTANCE instance, HINSTANCE /*prev*/, LPSTR /*cmd_line*/,
                   int /*show_cmd*/) {
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  FlutterDesktopEngineProperties properties = {};
  properties.assets_path = L"data\\flutter_assets";
  properties.icu_data_path = L"data\\icudtl.dat";

#ifdef NDEBUG
  properties.aot_library_path = L"app.so";
#else
  properties.aot_library_path = L"";
#endif

  FlutterDesktopEngineRef engine = FlutterDesktopEngineCreate(&properties);
  if (!engine) {
    return EXIT_FAILURE;
  }

  FlutterDesktopViewControllerRef controller =
      FlutterDesktopViewControllerCreate(800, 600, engine);
  if (!controller) {
    FlutterDesktopEngineDestroy(engine);
    return EXIT_FAILURE;
  }

  MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  FlutterDesktopViewControllerDestroy(controller);
  ::CoUninitialize();

  return EXIT_SUCCESS;
}
