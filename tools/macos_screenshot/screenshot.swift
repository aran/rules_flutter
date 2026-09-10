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

/// Why a capture fails *after* the windows have been found and named.
///
/// Reaching here means `SCShareableContent` enumerated successfully, which
/// itself requires Screen Recording — so the permission is granted and "grant
/// Screen Recording" is the wrong answer. What
/// ScreenCaptureKit will not do is start a stream against a powered-down panel,
/// and it keeps enumerating windows perfectly well after the display idles out.
/// A suite runs unattended for minutes and a terminal driving it does not count
/// as user activity, so `displaysleep` reaches it mid-run.
let sleepingDisplayHint =
  "ScreenCaptureKit enumerated the windows, so Screen Recording is granted"
  + " — what it could not do is start a capture stream. The usual cause is a"
  + " sleeping display: it keeps enumerating windows after the panel powers"
  + " down. Confirm with `pmset -g log | grep \"Display is turned\"`, and hold"
  + " it awake with `caffeinate -d <command>` (plain `caffeinate` prevents"
  + " system sleep only, which is not the same thing)."

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
    // No permission claim here, for the reason given on `dieNoOnScreenWindow`:
    // this line is only reachable once the enumeration succeeded, and the grant
    // is a precondition of that. An untitled window is just untitled.
    let available = windows.map { w -> String in
      let t = w.title ?? ""
      return t.isEmpty ? "<untitled>" : "\"\(t)\""
    }.joined(separator: ", ")
    die(
      "No window titled \"\(title)\" for the target pid. Its \(windows.count) "
        + "window(s): \(available)."
    )
  }
  do {
    let image = try await captureWindow(match)
    writePNG(image, to: outputPath)
  } catch {
    die(
      "Failed to capture window titled \"\(title)\": \(error.localizedDescription)\n"
        + sleepingDisplayHint)
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
    die(
      "No capturable windows for the target pid, though \(windows.count) "
        + "window(s) were found.\n" + sleepingDisplayHint)
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

/// Report what the enumeration found when the target pid owns no window in
/// ScreenCaptureKit's on-screen set.
///
/// A cause named but not established is worse than no cause at all: it costs
/// every later reader the round trip to disprove it. In particular, a window
/// absent from the on-screen set need not be minimized or hidden — one whose
/// `AXMinimized` is false and whose frame sits wholly inside the display can
/// stay out of the capturable set regardless.
///
/// So the empty set is re-enumerated *including* off-screen windows, and this
/// reports what came back rather than why. The two shapes it can come back in
/// are still worth telling apart, because the caller acts on them differently:
///   * windows exist but none are in the on-screen set — reported with their
///     titles and geometry, and with no claim about the reason;
///   * no windows at all — the app has not created one, or this is not the pid
///     that owns its UI.
///
/// Do not report a third shape — "every title is empty, so Screen Recording
/// must be missing". Reaching this function at all proves the opposite.
/// `SCShareableContent` does not degrade to titleless windows when the grant is
/// absent — it *fails*, with `SCStreamErrorUserDeclined` (-3801, "the user did
/// not allow TCCs to start capture"), which `main`'s catch reports before
/// anything can get here. Degrading to titleless output is
/// `CGWindowListCopyWindowInfo` behaviour, the pre-macOS-15 API this file
/// replaces, which omits `kCGWindowName` without the grant. And plenty of
/// windows simply have no title: with the grant present, Finder and Tailscale
/// both enumerate with every title empty.
@available(macOS 14.0, *)
func dieNoOnScreenWindow(pid: pid_t) async -> Never {
  let all: SCShareableContent
  do {
    all = try await SCShareableContent.excludingDesktopWindows(
      true, onScreenWindowsOnly: false)
  } catch {
    die(
      "No on-screen windows found for pid \(pid), and re-enumerating with "
        + "off-screen windows included also failed: \(error.localizedDescription)")
  }
  let owned = all.windows.filter { $0.owningApplication?.processID == pid }
  if owned.isEmpty {
    die(
      "No windows at all for pid \(pid) — on screen or off. Either the app has "
        + "not created its window yet, or this pid does not own the app's UI.")
  }

  let described = owned.map { w -> String in
    let title = w.title ?? ""
    let name = title.isEmpty ? "<untitled>" : "\"\(title)\""
    return
      "\(name) \(Int(w.frame.width))x\(Int(w.frame.height)) at (\(Int(w.frame.minX)),\(Int(w.frame.minY)))"
  }.joined(separator: ", ")

  die(
    "pid \(pid) owns \(owned.count) window(s), and ScreenCaptureKit's on-screen set — the only "
      + "windows it can capture — contains none of them: \(described)."
  )
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
      await dieNoOnScreenWindow(pid: args.pid)
    }
    if let title = args.title {
      await captureSingle(windows: windows, title: title, to: args.outputPath)
    } else {
      await captureComposite(windows: windows, to: args.outputPath)
    }
  }
}
