import AppKit
import Carbon.HIToolbox
import LinkCKit

/// One registered global keyboard shortcut via Carbon `RegisterEventHotKey` — deliberately
/// not an `NSEvent` global monitor, which needs Accessibility permission for key events; the
/// Carbon app-hotkey API does not (and Carbon is a system framework: no new dependency).
/// The C callback can't capture Swift context, so `userData` carries the instance; Carbon
/// dispatches on the main run loop, so `MainActor.assumeIsolated` is sound.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register(keyCode: UInt32, modifiers: UInt32) throws {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else {
            throw LinkCError.process("hotkey handler install failed (OSStatus \(installStatus))")
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4B_4331), id: 1)  // "LKC1"
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            throw LinkCError.process("hotkey registration failed (OSStatus \(registerStatus)) — the shortcut may be taken by another app")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
