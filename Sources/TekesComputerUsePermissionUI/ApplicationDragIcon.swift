import AppKit
import SwiftUI

/// Publishes the app's file URL directly, without loading or promising its bundle contents.
public struct ApplicationDragIcon: NSViewRepresentable {
  public let bundle: URL
  public init(bundle: URL) { self.bundle = bundle }

  public func makeNSView(context: Context) -> NSView {
    ApplicationDragImageView(bundle: bundle)
  }

  public func updateNSView(_ view: NSView, context: Context) {
    (view as? ApplicationDragImageView)?.setBundle(bundle)
  }
}

@MainActor
public final class ApplicationDragImageView: NSImageView, NSDraggingSource {
  private var bundle: URL
  private var mouseDownPoint: NSPoint?

  public init(bundle: URL) {
    self.bundle = bundle
    super.init(frame: .zero)
    image = NSWorkspace.shared.icon(forFile: bundle.path)
    imageScaling = .scaleProportionallyUpOrDown
    setAccessibilityLabel(bundle.deletingPathExtension().lastPathComponent)
  }

  public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public func setBundle(_ bundle: URL) {
    guard self.bundle != bundle else { return }
    self.bundle = bundle
    image = NSWorkspace.shared.icon(forFile: bundle.path)
    setAccessibilityLabel(bundle.deletingPathExtension().lastPathComponent)
  }

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  public override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }
  public override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

  public override func mouseDragged(with event: NSEvent) {
    guard let start = mouseDownPoint,
      hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3,
      let image else { return }
    mouseDownPoint = nil
    let item = NSDraggingItem(pasteboardWriter: bundle as NSURL)
    item.setDraggingFrame(bounds, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  public func draggingSession(_ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
