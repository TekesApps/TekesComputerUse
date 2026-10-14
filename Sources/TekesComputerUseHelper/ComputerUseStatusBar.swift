import AppKit
import Foundation

@MainActor
final class ComputerUseStatusBarController: NSObject {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private let statusLabel = NSTextField(labelWithString: "")
  private let accessibilityLabel = NSTextField(labelWithString: "")
  private let screenCaptureLabel = NSTextField(labelWithString: "")
  private let connectionsLabel = NSTextField(labelWithString: "")
  private let activityTextView = NSTextView()
  private var timer: Timer?

  override init() {
    super.init()
    configureStatusItem()
    configurePopover()
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  private func configureStatusItem() {
    guard let button = statusItem.button else { return }
    let iconURL = Bundle.main.resourceURL?.appendingPathComponent("ComputerUseStatusIcon.svg")
    let icon =
      iconURL.flatMap(NSImage.init(contentsOf:))
      ?? NSImage(systemSymbolName: "display", accessibilityDescription: "Computer Use")
    icon?.size = NSSize(width: 18, height: 18)
    icon?.isTemplate = true
    button.image = icon
    button.toolTip = "Tekes Computer Use"
    button.target = self
    button.action = #selector(togglePopover)
  }

  private func configurePopover() {
    popover.behavior = .transient
    popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    popover.contentSize = NSSize(width: 360, height: 470)

    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 12
    root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)

    let title = NSTextField(labelWithString: "Computer Use")
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let versionLabel = NSTextField(labelWithString: version.map { "Version \($0)" } ?? "")
    versionLabel.textColor = .secondaryLabelColor
    versionLabel.font = .systemFont(ofSize: 11)
    root.addArrangedSubview(title)
    root.addArrangedSubview(versionLabel)
    root.addArrangedSubview(statusLabel)
    root.addArrangedSubview(separator())
    root.addArrangedSubview(sectionTitle("Permissions"))
    root.addArrangedSubview(accessibilityLabel)
    root.addArrangedSubview(screenCaptureLabel)

    let permissionButtons = NSStackView(views: [
      button("Open Accessibility Settings", action: #selector(openAccessibilitySettings)),
      button("Open Screen Recording Settings", action: #selector(openScreenRecordingSettings)),
    ])
    permissionButtons.orientation = .vertical
    permissionButtons.alignment = .leading
    permissionButtons.spacing = 6
    root.addArrangedSubview(permissionButtons)
    root.addArrangedSubview(separator())
    root.addArrangedSubview(sectionTitle("Connections"))
    root.addArrangedSubview(connectionsLabel)
    root.addArrangedSubview(sectionTitle("Recent activity"))

    activityTextView.isEditable = false
    activityTextView.isSelectable = true
    activityTextView.drawsBackground = false
    activityTextView.textContainerInset = NSSize(width: 0, height: 2)
    activityTextView.font = .systemFont(ofSize: 11)
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.documentView = activityTextView
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.heightAnchor.constraint(equalToConstant: 145).isActive = true
    root.addArrangedSubview(scrollView)

    let actions = NSStackView(views: [
      button("Copy Diagnostics", action: #selector(copyDiagnostics)),
      button("Quit", action: #selector(quit)),
    ])
    actions.orientation = .horizontal
    actions.spacing = 10
    root.addArrangedSubview(actions)

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 470))
    root.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(root)
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      root.topAnchor.constraint(equalTo: container.topAnchor),
      root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      root.widthAnchor.constraint(equalToConstant: 328),
      scrollView.widthAnchor.constraint(equalToConstant: 328),
    ])
    let controller = NSViewController()
    controller.view = container
    controller.preferredContentSize = NSSize(width: 360, height: 470)
    popover.contentViewController = controller
  }

  private func refresh() {
    let permissions = MacAutomation.currentPermissionState()
    let sessions = ComputerUseActivityJournal.activeSessions()
    let permissionsReady = permissions.accessibility && permissions.screenCapture
    if !permissionsReady {
      statusLabel.stringValue = "● Needs permission"
      statusLabel.textColor = .systemOrange
    } else if sessions.isEmpty {
      statusLabel.stringValue = "● Ready"
      statusLabel.textColor = .secondaryLabelColor
    } else {
      statusLabel.stringValue = "● Active"
      statusLabel.textColor = .systemGreen
    }
    accessibilityLabel.stringValue = row("Accessibility", allowed: permissions.accessibility)
    screenCaptureLabel.stringValue = row("Screen Recording", allowed: permissions.screenCapture)
    connectionsLabel.stringValue =
      sessions.isEmpty
      ? "No active MCP sessions"
      : sessions.map { "\($0.host) · PID \($0.pid)" }.joined(separator: "\n")

    let activities = ComputerUseActivityJournal.recentActivities(limit: 20)
    activityTextView.string =
      activities.isEmpty
      ? "No recent activity"
      : activities.map(activityLine).joined(separator: "\n")
  }

  private func row(_ name: String, allowed: Bool) -> String {
    "\(allowed ? "✓" : "!") \(name): \(allowed ? "Allowed" : "Missing")"
  }

  private func activityLine(_ activity: ComputerUseActivity) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    let detail = activity.detail.map { " · \($0)" } ?? ""
    return "\(formatter.string(from: activity.timestamp))  \(activity.action)\(detail)"
  }

  private func sectionTitle(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 12, weight: .semibold)
    return label
  }

  private func separator() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    return box
  }

  private func button(_ title: String, action: Selector) -> NSButton {
    let result = NSButton(title: title, target: self, action: action)
    result.bezelStyle = .inline
    return result
  }

  @objc private func togglePopover() {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      refresh()
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }

  @objc private func openAccessibilitySettings() {
    openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  @objc private func openScreenRecordingSettings() {
    openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
  }

  private func openSettings(_ value: String) {
    guard let url = URL(string: value) else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func copyDiagnostics() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(ComputerUseActivityJournal.diagnosticsText, forType: .string)
  }

  @objc private func quit() { NSApplication.shared.terminate(nil) }
}

@MainActor
enum ComputerUseStatusBarApp {
  private static var controller: ComputerUseStatusBarController?

  static func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    controller = ComputerUseStatusBarController()
    app.run()
  }
}
