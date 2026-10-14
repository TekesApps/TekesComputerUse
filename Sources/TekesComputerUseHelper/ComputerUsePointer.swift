import AppKit

/// A visual marker only: never moves the user's cursor or participates in hit testing.
@MainActor
final class ComputerUsePointer {
  static let shared = ComputerUsePointer()
  private var panel: NSPanel?
  private var dismissal: Task<Void, Never>?

  static func appKitPoint(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: primaryHeight - point.y)
  }

  func flash(at point: CGPoint) async {
    show(at: point)
    // Yield so AppKit can present the target before the action changes the application.
    try? await Task.sleep(for: .milliseconds(100))
  }

  func show(at point: CGPoint) {
    guard point.x.isFinite, point.y.isFinite,
      let primary = NSScreen.screens.first
    else { return }
    if panel == nil {
      let window = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 72, height: 72),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = false
      window.ignoresMouseEvents = true
      window.hidesOnDeactivate = false
      window.level = .screenSaver
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      window.contentView = PointerView(frame: NSRect(x: 0, y: 0, width: 72, height: 72))
      panel = window
    }
    let location = Self.appKitPoint(point, primaryHeight: primary.frame.height)
    panel?.setFrameOrigin(CGPoint(x: location.x - 36, y: location.y - 36))
    panel?.orderFrontRegardless()
    dismissal?.cancel()
    dismissal = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
      self?.panel?.orderOut(nil)
    }
  }
}

@MainActor
private final class PointerView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let ring = NSBezierPath(ovalIn: NSRect(x: 25, y: 25, width: 22, height: 22))
    NSColor.systemTeal.withAlphaComponent(0.10).setFill()
    ring.fill()
    NSColor.systemTeal.withAlphaComponent(0.55).setStroke()
    ring.lineWidth = 1.25
    ring.stroke()

    // The arrow tip stays exactly at the action target (the panel's center).
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 36, y: 36))
    arrow.line(to: NSPoint(x: 36, y: 15))
    arrow.line(to: NSPoint(x: 41, y: 20))
    arrow.line(to: NSPoint(x: 45, y: 12))
    arrow.line(to: NSPoint(x: 49, y: 14))
    arrow.line(to: NSPoint(x: 45, y: 22))
    arrow.line(to: NSPoint(x: 52, y: 22))
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 1.5

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 2
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.set()
    NSColor.white.setStroke()
    arrow.stroke()
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    arrow.fill()
    NSGraphicsContext.restoreGraphicsState()
  }
}
