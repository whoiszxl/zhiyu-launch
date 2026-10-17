import AppKit

/// Menu bar status item: open launchpad, settings, login item, quit.
@MainActor
final class StatusBarController: NSObject {
    var onOpenLaunchpad: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onMenuBarVisibilityChanged: ((Bool) -> Void)?

    private var statusItem: NSStatusItem?
    private weak var loginItemMenuItem: NSMenuItem?
    private weak var menuBarMenuItem: NSMenuItem?
    private weak var openItemMenuItem: NSMenuItem?

    func setVisible(_ visible: Bool) {
        if visible {
            install()
        } else {
            uninstall()
        }
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Zhiyu Launch")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Zhiyu Launch"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func uninstall() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: L10n.openLaunchpad, action: #selector(openLaunchpad), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        openItemMenuItem = open

        menu.addItem(.separator())

        let login = NSMenuItem(title: L10n.launchAtLogin, action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItemMenuItem = login

        let menuBar = NSMenuItem(title: L10n.showMenuBarIcon, action: #selector(toggleMenuBarIcon), keyEquivalent: "")
        menuBar.target = self
        menu.addItem(menuBar)
        menuBarMenuItem = menuBar

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L10n.settingsEllipsis, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.quitApp, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Actions

    @objc private func openLaunchpad() {
        onOpenLaunchpad?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        onQuit?()
    }

    @objc private func toggleLoginItem() {
        let enable = !LaunchAtLogin.isEnabled
        do {
            try LaunchAtLogin.setEnabled(enable)
        } catch {
            presentLoginItemError(error)
        }
    }

    @objc private func toggleMenuBarIcon() {
        Preferences.shared.showMenuBarIcon.toggle()
        onMenuBarVisibilityChanged?(Preferences.shared.showMenuBarIcon)
    }

    private func presentLoginItemError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.launchAtLoginError
        alert.informativeText = "\(error.localizedDescription)\n\n\(L10n.launchAtLoginErrorDetail)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItemMenuItem?.state = LaunchAtLogin.isEnabled ? .on : .off
        menuBarMenuItem?.state = Preferences.shared.showMenuBarIcon ? .on : .off
        openItemMenuItem?.title = "\(L10n.openLaunchpad) (\(Preferences.shared.hotKey.displayString))"
    }
}
