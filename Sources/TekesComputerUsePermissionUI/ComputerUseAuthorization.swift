import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

/// Shared UI only. Each process requests consent using its own signed application identity.
@MainActor
public enum ComputerUseAuthorization {
  public static func request(accessibility: Bool, screenCapture: Bool) {
    if Bundle.main.bundleIdentifier == "com.tekes.computer-use.helper" {
      NSApplication.shared.setActivationPolicy(.accessory)
    }
    PermissionPanel.shared.show()
    if accessibility {
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    if screenCapture { _ = CGRequestScreenCaptureAccess() }
    let pane = accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
    }
  }
}

@MainActor
private final class PermissionPanel {
  static let shared = PermissionPanel()
  private var panel: NSPanel?

  func show() {
    if panel == nil {
      let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
      window.title = applicationName
      window.isReleasedWhenClosed = false
      window.isFloatingPanel = true
      window.level = .floating
      window.hidesOnDeactivate = false
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.contentView = NSHostingView(rootView: PermissionCard())
      if let screen = NSScreen.main {
        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.maxX - 340, y: frame.midY - 125))
      }
      panel = window
    }
    panel?.orderFrontRegardless()
  }
}

private struct PermissionCard: View {
  @State private var accessibility = false
  @State private var screenCapture = false
  private let app = Bundle.main.bundleURL
  private var chinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }

  var body: some View {
    VStack(spacing: 12) {
      ApplicationDragIcon(bundle: app)
        .frame(width: 64, height: 64)
        .accessibilityLabel(applicationName)
      Text(chinese ? "将 \(applicationName) 拖入权限列表" : "Drag \(applicationName) into the permission list")
        .font(.headline)
      Text(chinese ? "拖动上方图标到系统设置，然后打开对应应用的开关。此窗口会保持在前方。"
        : "Drag the icon into System Settings, then enable this app. This window stays visible.")
        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      HStack {
        Label(chinese ? "辅助功能" : "Accessibility", systemImage: accessibility ? "checkmark.circle.fill" : "circle")
        Label(chinese ? "录屏" : "Screen Recording", systemImage: screenCapture ? "checkmark.circle.fill" : "circle")
      }.font(.caption)
      Button(chinese ? "在 Finder 中显示" : "Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([app])
      }
    }
    .padding(20)
    .frame(width: 320, height: 300)
    .task {
      while !Task.isCancelled {
        accessibility = AXIsProcessTrusted()
        screenCapture = CGPreflightScreenCaptureAccess()
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }
}

private var applicationName: String {
  Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Tekes"
}
