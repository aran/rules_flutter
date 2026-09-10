// DXGI Desktop Duplication screenshot.
//
// Usage: screenshot <output_png>
//
// Captures the Windows desktop through the Desktop Duplication API, which
// sees D3D and Flutter surfaces. GDI's CopyFromScreen does not — it returns
// black for D3D content, which is why this helper exists at all.
//
// Native rather than a `py_binary`, and that is the point. A Python version
// needs dxcam, opencv, Pillow and numpy, so it needs a runfiles tree to find
// them at runtime; Bazel on Windows defaults to `--noenable_runfiles` and never
// materialises one, and rules_python's bootstrap can only find runfiles as a
// *directory* (it reads RUNFILES_MANIFEST_FILE solely to derive a directory
// name, then requires it to exist). A `py_binary` spawned out of another
// binary's runfiles therefore cannot start at all on a default Windows build,
// whatever the parent forwards. This links only Windows SDK libraries and reads
// nothing at runtime, so it has no runfiles to lose — the same shape as the
// macOS helper next door. See docs/TESTING.md.

// Pinned before any header: the SDK gates declarations on it, and Bazel's
// MSVC toolchain does not set it. Guarded so a toolchain that *does* define it
// on the command line wins instead of warning about a redefinition.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <windows.h>

#include <d3d11.h>
#include <dxgi1_2.h>
#include <shellapi.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <chrono>
#include <cstdio>

using Microsoft::WRL::ComPtr;

namespace {

// How long to keep asking the compositor for a frame.
//
// `AcquireNextFrame` answers DXGI_ERROR_WAIT_TIMEOUT when the desktop has not
// changed since the last call, which on an idle screen is most calls. That is
// not a failure, so it is retried rather than reported; this bounds the retry.
constexpr auto kAcquireDeadline = std::chrono::seconds(10);
constexpr UINT kAcquireTimeoutMs = 250;

int Fail(const char* what, HRESULT hr) {
  std::fprintf(stderr, "%s failed: 0x%08lx\n", what, static_cast<unsigned long>(hr));
  return 1;
}

// Writes BGRA pixels as a PNG through WIC, the imaging component that ships
// with Windows — no third-party encoder.
HRESULT WritePng(const wchar_t* path, const BYTE* pixels, UINT width, UINT height, UINT stride) {
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return hr;

  ComPtr<IWICStream> stream;
  hr = factory->CreateStream(&stream);
  if (FAILED(hr)) return hr;
  hr = stream->InitializeFromFilename(path, GENERIC_WRITE);
  if (FAILED(hr)) return hr;

  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (FAILED(hr)) return hr;
  hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  if (FAILED(hr)) return hr;

  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  hr = encoder->CreateNewFrame(&frame, &props);
  if (FAILED(hr)) return hr;
  hr = frame->Initialize(props.Get());
  if (FAILED(hr)) return hr;
  hr = frame->SetSize(width, height);
  if (FAILED(hr)) return hr;

  // The duplication surface is BGRA8, and WIC has that format natively, so
  // the pixels go out exactly as the compositor produced them. Asking for a
  // different pixel format here would add a conversion for no reason.
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  hr = frame->SetPixelFormat(&format);
  if (FAILED(hr)) return hr;
  if (!IsEqualGUID(format, GUID_WICPixelFormat32bppBGRA)) {
    return WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT;
  }

  hr = frame->WritePixels(height, stride, stride * height, const_cast<BYTE*>(pixels));
  if (FAILED(hr)) return hr;
  hr = frame->Commit();
  if (FAILED(hr)) return hr;
  return encoder->Commit();
}

}  // namespace

// `main` with a wide command line rather than `wmain`: which entry point the
// CRT selects is a linker detail this does not need to depend on, and the path
// still arrives as UTF-16 so a non-ASCII output path survives.
//
// No DPI call: Desktop Duplication hands back the physical framebuffer, so
// process DPI awareness — which governs GDI and window coordinates — does not
// affect what is captured.
int main() {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr || argc < 2) {
    std::fprintf(stderr, "Usage: screenshot <output_png>\n");
    return 1;
  }
  const wchar_t* output = argv[1];

  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(hr)) return Fail("CoInitializeEx", hr);

  // Hardware first, WARP second — the ordered driver list D3D itself
  // documents, not a retry papering over a failure. A developer machine has a
  // GPU; a cloud VM without one has WARP, the software rasteriser, and that is
  // what makes this path testable on a VM at all. Both failing is reported
  // with both codes, because "no D3D device" has two quite different causes.
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  const D3D_DRIVER_TYPE kDriverTypes[] = {D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP};
  HRESULT driver_hr[2] = {S_OK, S_OK};
  for (int i = 0; i < 2; ++i) {
    driver_hr[i] = D3D11CreateDevice(nullptr, kDriverTypes[i], nullptr, 0, nullptr, 0,
                                     D3D11_SDK_VERSION, &device, nullptr, &context);
    if (SUCCEEDED(driver_hr[i])) break;
  }
  if (device == nullptr) {
    std::fprintf(stderr, "D3D11CreateDevice failed: hardware 0x%08lx, WARP 0x%08lx\n",
                 static_cast<unsigned long>(driver_hr[0]), static_cast<unsigned long>(driver_hr[1]));
    return 1;
  }

  ComPtr<IDXGIDevice> dxgi_device;
  hr = device.As(&dxgi_device);
  if (FAILED(hr)) return Fail("ID3D11Device::QueryInterface(IDXGIDevice)", hr);

  ComPtr<IDXGIAdapter> adapter;
  hr = dxgi_device->GetAdapter(&adapter);
  if (FAILED(hr)) return Fail("IDXGIDevice::GetAdapter", hr);

  ComPtr<IDXGIOutput> output0;
  hr = adapter->EnumOutputs(0, &output0);
  if (FAILED(hr)) return Fail("IDXGIAdapter::EnumOutputs(0)", hr);

  ComPtr<IDXGIOutput1> output1;
  hr = output0.As(&output1);
  if (FAILED(hr)) return Fail("IDXGIOutput::QueryInterface(IDXGIOutput1)", hr);

  ComPtr<IDXGIOutputDuplication> duplication;
  hr = output1->DuplicateOutput(device.Get(), &duplication);
  if (FAILED(hr)) return Fail("IDXGIOutput1::DuplicateOutput", hr);

  // Acquire the current desktop surface.
  //
  // The surface always holds what is on screen now, whether or not this call
  // reports accumulated frames, so the first success is the frame to keep.
  // WAIT_TIMEOUT only means "nothing changed since the last call".
  ComPtr<ID3D11Texture2D> desktop;
  const auto deadline = std::chrono::steady_clock::now() + kAcquireDeadline;
  for (;;) {
    DXGI_OUTDUPL_FRAME_INFO info{};
    ComPtr<IDXGIResource> resource;
    hr = duplication->AcquireNextFrame(kAcquireTimeoutMs, &info, &resource);
    if (SUCCEEDED(hr)) {
      hr = resource.As(&desktop);
      if (FAILED(hr)) return Fail("IDXGIResource::QueryInterface(ID3D11Texture2D)", hr);
      break;
    }
    if (hr != DXGI_ERROR_WAIT_TIMEOUT) return Fail("IDXGIOutputDuplication::AcquireNextFrame", hr);
    if (std::chrono::steady_clock::now() >= deadline) {
      std::fprintf(stderr,
                   "AcquireNextFrame saw no desktop frame within %llds. The session has no "
                   "desktop compositor — a screenshot needs an interactive session, not a "
                   "service one.\n",
                   static_cast<long long>(kAcquireDeadline.count()));
      return 1;
    }
  }

  D3D11_TEXTURE2D_DESC desc{};
  desktop->GetDesc(&desc);

  // The duplicated texture lives in GPU memory and cannot be mapped; a
  // staging copy is the documented way to read it back.
  D3D11_TEXTURE2D_DESC staging_desc = desc;
  staging_desc.Usage = D3D11_USAGE_STAGING;
  staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  staging_desc.BindFlags = 0;
  staging_desc.MiscFlags = 0;
  ComPtr<ID3D11Texture2D> staging;
  hr = device->CreateTexture2D(&staging_desc, nullptr, &staging);
  if (FAILED(hr)) return Fail("ID3D11Device::CreateTexture2D(staging)", hr);

  context->CopyResource(staging.Get(), desktop.Get());

  D3D11_MAPPED_SUBRESOURCE mapped{};
  hr = context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
  if (FAILED(hr)) return Fail("ID3D11DeviceContext::Map", hr);

  hr = WritePng(output, static_cast<const BYTE*>(mapped.pData), desc.Width, desc.Height,
                mapped.RowPitch);
  context->Unmap(staging.Get(), 0);
  duplication->ReleaseFrame();

  if (FAILED(hr)) return Fail("WritePng", hr);
  return 0;
}
