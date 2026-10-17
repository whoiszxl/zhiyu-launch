import AppKit
import Carbon.HIToolbox

/// Small settings window: hot key recorder, launch at login, menu bar icon,
/// recently-used toggle, hidden apps management and layout reset.
@MainActor
final class SettingsWindowController: NSWindowController {
    var onMenuBarVisibilityChanged: ((Bool) -> Void)?
    var onToggleRecentApps: ((Bool) -> Void)?
    var onUnhideAll: (() -> Void)?
    var onResetLayout: (() -> Void)?

    private let hotKeyManager: HotKeyManager
    private let hiddenAppsStore: HiddenAppsStore
    private let recorder = ShortcutRecorderView()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: L10n.launchAtLogin, target: nil, action: nil)
    private let menuBarCheckbox = NSButton(checkboxWithTitle: L10n.showMenuBarIcon, target: nil, action: nil)
    private let recentAppsCheckbox = NSButton(checkboxWithTitle: L10n.showRecentApps, target: nil, action: nil)
    private let hiddenAppsLabel = NSTextField(labelWithString: "")
    private let unhideAllButton = NSButton(title: L10n.revealAllHiddenApps, target: nil, action: nil)
    private let resetLayoutButton = NSButton(title: L10n.resetLayout, target: nil, action: nil)

    init(hotKeyManager: HotKeyManager, hiddenAppsStore: HiddenAppsStore) {
        self.hotKeyManager = hotKeyManager
        self.hiddenAppsStore = hiddenAppsStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 392),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.settingsTitle
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
        refreshStates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        refreshStates()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let hotKeyLabel = NSTextField(labelWithString: L10n.globalHotKey)
        hotKeyLabel.font = .systemFont(ofSize: 13, weight: .medium)

        recorder.combo = Preferences.shared.hotKey
        recorder.onRecord = { [weak self] combo in
            guard let self else { return false }
            guard self.hotKeyManager.register(combo) else { return false }
            Preferences.shared.hotKey = combo
            return true
        }

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)

        menuBarCheckbox.target = self
        menuBarCheckbox.action = #selector(toggleMenuBarIcon)

        recentAppsCheckbox.target = self
        recentAppsCheckbox.action = #selector(toggleRecentApps)

        hiddenAppsLabel.font = .systemFont(ofSize: 12)
        hiddenAppsLabel.textColor = .secondaryLabelColor

        unhideAllButton.target = self
        unhideAllButton.action = #selector(unhideAllHiddenApps)
        unhideAllButton.bezelStyle = .rounded
        unhideAllButton.controlSize = .small

        resetLayoutButton.target = self
        resetLayoutButton.action = #selector(resetLayout)
        resetLayoutButton.bezelStyle = .rounded
        resetLayoutButton.controlSize = .small

        let hiddenSeparator = NSBox()
        hiddenSeparator.boxType = .separator

        let hint = NSTextField(wrappingLabelWithString: L10n.hotKeyHint)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let versionLabel = NSTextField(labelWithString: L10n.versionLine(Self.versionString))
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor

        let subviews: [NSView] = [
            hotKeyLabel, recorder, launchAtLoginCheckbox, menuBarCheckbox, recentAppsCheckbox,
            hiddenSeparator, hiddenAppsLabel, unhideAllButton, resetLayoutButton, hint, versionLabel,
        ]
        for subview in subviews {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            hotKeyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            hotKeyLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            hotKeyLabel.widthAnchor.constraint(equalToConstant: 110),

            recorder.leadingAnchor.constraint(equalTo: hotKeyLabel.trailingAnchor, constant: 12),
            recorder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            recorder.centerYAnchor.constraint(equalTo: hotKeyLabel.centerYAnchor),
            recorder.heightAnchor.constraint(equalToConstant: 28),

            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            launchAtLoginCheckbox.topAnchor.constraint(equalTo: hotKeyLabel.bottomAnchor, constant: 22),

            menuBarCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            menuBarCheckbox.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 10),

            recentAppsCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            recentAppsCheckbox.topAnchor.constraint(equalTo: menuBarCheckbox.bottomAnchor, constant: 10),

            hiddenSeparator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            hiddenSeparator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            hiddenSeparator.topAnchor.constraint(equalTo: recentAppsCheckbox.bottomAnchor, constant: 18),

            hiddenAppsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            hiddenAppsLabel.topAnchor.constraint(equalTo: hiddenSeparator.bottomAnchor, constant: 16),
            hiddenAppsLabel.trailingAnchor.constraint(lessThanOrEqualTo: unhideAllButton.leadingAnchor, constant: -12),

            unhideAllButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            unhideAllButton.centerYAnchor.constraint(equalTo: hiddenAppsLabel.centerYAnchor),

            resetLayoutButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            resetLayoutButton.topAnchor.constraint(equalTo: hiddenAppsLabel.bottomAnchor, constant: 12),

            hint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            hint.topAnchor.constraint(equalTo: resetLayoutButton.bottomAnchor, constant: 20),

            versionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            versionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func refreshStates() {
        recorder.combo = Preferences.shared.hotKey
        launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        menuBarCheckbox.state = Preferences.shared.showMenuBarIcon ? .on : .off
        recentAppsCheckbox.state = Preferences.shared.showRecentApps ? .on : .off

        let hiddenCount = hiddenAppsStore.bundleIDs.count
        hiddenAppsLabel.stringValue = String(format: L10n.hiddenAppsCount, hiddenCount)
        unhideAllButton.isEnabled = hiddenCount > 0
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = launchAtLoginCheckbox.state == .on
        do {
            try LaunchAtLogin.setEnabled(enable)
        } catch {
            launchAtLoginCheckbox.state = enable ? .off : .on
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L10n.launchAtLoginError
            alert.informativeText = "\(error.localizedDescription)\n\n\(L10n.launchAtLoginErrorDetail)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func toggleMenuBarIcon() {
        let show = menuBarCheckbox.state == .on
        Preferences.shared.showMenuBarIcon = show
        onMenuBarVisibilityChanged?(show)
    }

    @objc private func toggleRecentApps() {
        let show = recentAppsCheckbox.state == .on
        Preferences.shared.showRecentApps = show
        onToggleRecentApps?(show)
    }

    @objc private func unhideAllHiddenApps() {
        onUnhideAll?()
        refreshStates()
    }

    @objc private func resetLayout() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.resetLayoutConfirmTitle
        alert.informativeText = L10n.resetLayoutConfirmDetail
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.resetLayout)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self?.onResetLayout?()
            }
        }
    }

    private static var versionString: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
}

/// Click-to-record shortcut control. Captures the next key combination while it
/// is first responder; Esc cancels.
final class ShortcutRecorderView: NSView {
    /// Returns whether the combination could be registered.
    var onRecord: ((HotKeyCombo) -> Bool)?

    var combo: HotKeyCombo = .default {
        didSet { label.stringValue = combo.displayString }
    }

    private(set) var isRecording = false
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        label.isSelectable = false
        addSubview(label)
        label.stringValue = combo.displayString
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startRecording()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Esc cancels recording
            stopRecording()
            return
        }

        let carbon = Self.carbonModifiers(from: event.modifierFlags)
        let required: UInt32 = UInt32(cmdKey | optionKey | controlKey)
        guard carbon & required != 0 else {
            label.stringValue = L10n.recorderNeedModifier
            NSSound.beep()
            return
        }

        let candidate = HotKeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
        if onRecord?(candidate) == true {
            combo = candidate
            stopRecording()
        } else {
            label.stringValue = L10n.recorderUnavailable
            NSSound.beep()
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return super.resignFirstResponder()
    }

    private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        label.stringValue = L10n.recorderPrompt
        needsDisplay = true
    }

    private func stopRecording() {
        isRecording = false
        label.stringValue = combo.displayString
        needsDisplay = true
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.quaternaryLabelColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 16), height: 18)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
