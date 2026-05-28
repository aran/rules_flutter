// macOS screenshot helper for the dev tool's native screenshot endpoint.
//
// Usage:
//   screenshot --pid <N> --output <path> [--title <encoded>]
//
// Without --title, captures every on-screen window owned by <pid> and
// composites them onto a transparent canvas at screen-relative offsets —
// "the app's window set, lifted off the desktop." With --title, captures
// only the window whose SCWindow.title matches exactly.
//
// Built on ScreenCaptureKit (macOS 14+); the older CGWindowListCreateImage
// API was obsoleted in macOS 15. Requires Screen Recording permission for
// the calling terminal.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct Args {
  let pid: pid_t
  let outputPath: String
  let title: String?
}

func die(_ msg: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
  exit(code)
}

func parseArgs() -> Args {
  var pid: pid_t?
  var output: String?
  var title: String?
  var it = CommandLine.arguments.dropFirst().makeIterator()
  while let a = it.next() {
    switch a {
    case "--pid":
      guard let v = it.next(), let p = pid_t(v) else { die("--pid requires an integer", code: 2) }
      pid = p
    case "--output":
      guard let v = it.next() else { die("--output requires a path", code: 2) }
      output = v
    case "--title":
      guard let v = it.next() else { die("--title requires a value", code: 2) }
      title = v
    default:
      die("Unknown argument: \(a)", code: 2)
    }
  }
  guard let pid = pid, let output = output else {
    die("Usage: screenshot --pid <N> --output <path> [--title <T>]", code: 2)
  }
  return Args(pid: pid, outputPath: output, title: title)
}

@available(macOS 14.0, *)
func captureWindow(_ window: SCWindow) async throws -> CGImage {
  let filter = SCContentFilter(desktopIndependentWindow: window)
  let config = SCStreamConfiguration()
  // Render at the source's native pixel resolution so Retina windows aren't
  // downsampled. pointPixelScale is 1.0 on non-Retina, 2.0 on Retina.
  config.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
  config.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
  config.scalesToFit = false
  config.showsCursor = false
  config.ignoreShadowsSingleWindow = true
  config.ignoreGlobalClipSingleWindow = true
  return try await SCScreenshotManager.captureImage(
    contentFilter: filter, configuration: config)
}

func writePNG(_ image: CGImage, to path: String) {
  let url = URL(fileURLWithPath: path)
  let utType = UTType.png.identifier as CFString
  guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil) else {
    die("Failed to create PNG destination at \(path)")
  }
  CGImageDestinationAddImage(dest, image, nil)
  if !CGImageDestinationFinalize(dest) {
    die("Failed to write PNG to \(path)")
  }
}

@available(macOS 14.0, *)
func captureSingle(windows: [SCWindow], title: String, to outputPath: String) async {
  guard let match = windows.first(where: { $0.title == title }) else {
    let available = windows.compactMap { $0.title }
    die(
      "No window titled \"\(title)\" for the target pid. Available titles: \(available). (Titles require Screen Recording permission to be populated.)"
    )
  }
  do {
    let image = try await captureWindow(match)
    writePNG(image, to: outputPath)
  } catch {
    die("Failed to capture window titled \"\(title)\": \(error.localizedDescription)")
  }
}

@available(macOS 14.0, *)
func captureComposite(windows: [SCWindow], to outputPath: String) async {
  var captures: [(rect: CGRect, image: CGImage)] = []
  for w in windows {
    if w.frame.width == 0 || w.frame.height == 0 {
      FileHandle.standardError.write(
        "Skipping window \(w.windowID) (\(w.title ?? "<untitled>")): zero-sized frame.\n"
          .data(using: .utf8)!)
      continue
    }
    do {
      let image = try await captureWindow(w)
      captures.append((rect: w.frame, image: image))
    } catch {
      // A single window vanishing or refusing capture mid-enumeration
      // shouldn't fail the whole composite, but the user needs to know
      // the result is partial.
      FileHandle.standardError.write(
        "Skipping window \(w.windowID) (\(w.title ?? "<untitled>")): \(error.localizedDescription)\n"
          .data(using: .utf8)!)
      continue
    }
  }
  if captures.isEmpty {
    die("No capturable windows for the target pid.")
  }

  let unionRect = captures.dropFirst().reduce(captures[0].rect) { $0.union($1.rect) }

  // Detect Retina from the first captured image: image is in pixels, frame
  // is in points. All windows on the same display share the scale; cross-
  // display capture is rare enough that picking one is acceptable.
  let first = captures[0]
  let rawScale = max(
    CGFloat(first.image.width) / max(first.rect.width, 1),
    CGFloat(first.image.height) / max(first.rect.height, 1)
  ).rounded()
  let pixelScale = rawScale < 1 ? 1 : rawScale

  let canvasW = Int((unionRect.width * pixelScale).rounded())
  let canvasH = Int((unionRect.height * pixelScale).rounded())
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard let ctx = CGContext(
    data: nil,
    width: canvasW,
    height: canvasH,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else {
    die("Failed to create \(canvasW)x\(canvasH) bitmap context")
  }
  ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(canvasW), height: CGFloat(canvasH)))

  // SCWindow.frame is in display space (top-left origin); the bitmap context
  // is in CG default coords (bottom-left origin). Inverting Y at the dy step
  // (rather than flipping the context) avoids ctx.draw rendering the image
  // upside-down inside its target rect.
  for c in captures {
    let dx = (c.rect.minX - unionRect.minX) * pixelScale
    let dy = (unionRect.maxY - c.rect.maxY) * pixelScale
    let dw = c.rect.width * pixelScale
    let dh = c.rect.height * pixelScale
    ctx.draw(c.image, in: CGRect(x: dx, y: dy, width: dw, height: dh))
  }

  guard let composite = ctx.makeImage() else {
    die("Failed to materialize composite image")
  }
  writePNG(composite, to: outputPath)
}

@main
struct Main {
  static func main() async {
    guard #available(macOS 14.0, *) else {
      die(
        "This screenshot helper requires macOS 14 or newer (ScreenCaptureKit's single-shot capture API).",
        code: 2)
    }
    // ScreenCaptureKit requires an initialized CoreGraphics connection;
    // without an NSApplication context, SCShareableContent.excludingDesktopWindows
    // trips `CGS_REQUIRE_INIT` assertion. .accessory keeps us out of the Dock.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let args = parseArgs()
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: true)
    } catch {
      die(
        "Failed to enumerate windows via ScreenCaptureKit: \(error.localizedDescription). This usually means Screen Recording permission is not granted to the terminal that launched the dev tool. Grant it in System Settings → Privacy & Security → Screen Recording."
      )
    }
    let windows = content.windows.filter { $0.owningApplication?.processID == args.pid }
    if windows.isEmpty {
      die(
        "No on-screen windows found for pid \(args.pid). The app may not have opened a window yet, or Screen Recording permission is not granted."
      )
    }
    if let title = args.title {
      await captureSingle(windows: windows, title: title, to: args.outputPath)
    } else {
      await captureComposite(windows: windows, to: args.outputPath)
    }
  }
}
