import Carbon.HIToolbox
import Foundation

/// Global hot key support built on the public Carbon hot key API.
///
/// Carbon's `RegisterEventHotKey` needs no accessibility permission (unlike
/// `CGEvent` taps) and no helper process, which fits this app's constraints.
@MainActor
final class HotKeyManager {
    /// Called on the main actor when the registered combination is pressed.
    var onTrigger: (() -> Void)?

    private(set) var combo: HotKeyCombo?
    // Unsafe (but correct): only touched from the main actor while alive, and from
    // the nonisolated deinit after the last reference is gone.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var handlerRef: EventHandlerRef?

    private static let signature: OSType = 0x5A59_4C48 // 'ZYLH'

    /// Registers a new combination, replacing the previous one.
    /// Returns false when the system refuses the combination (e.g. already taken).
    @discardableResult
    func register(_ combo: HotKeyCombo) -> Bool {
        unregister()
        installEventHandlerIfNeeded()

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyID.id = 1

        guard status == noErr, let ref else {
            NSLog("[ZhiyuLaunch] RegisterEventHotKey failed: \(status)")
            return false
        }
        hotKeyRef = ref
        self.combo = combo
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        combo = nil
    }

    private func installEventHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != noErr {
            NSLog("[ZhiyuLaunch] InstallEventHandler failed: \(status)")
        }
    }

    fileprivate func trigger() {
        onTrigger?()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}

/// C callback for the Carbon hot key event; hops back to the main actor.
private func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        manager.trigger()
    }
    return noErr
}
