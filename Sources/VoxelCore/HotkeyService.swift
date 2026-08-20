import Carbon.HIToolbox
import Foundation

/// C trampoline for Carbon's hot key event. Global (non-capturing) so it can be
/// passed where a `@convention(c)` function pointer is expected.
private func voxelHotkeyHandler(_ callRef: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotkeyID)
    guard status == noErr else { return status }
    HotkeyService.shared.fire(id: hotkeyID.id)
    return noErr
}

/// Global hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Deliberately *not* `NSEvent.addGlobalMonitorForEvents`: monitoring keyDown
/// globally requires Accessibility permission, and a panic button that opens a
/// "Voxel wants to control your computer" dialog on first run defeats itself.
/// RegisterEventHotKey needs no permission at all.
public final class HotkeyService {
    public static let shared = HotkeyService()

    public enum Slot: UInt32 {
        case panic = 1
        case resume = 2
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private let signature: OSType = 0x564F_584C // 'VOXL'

    private init() {}

    @discardableResult
    public func register(_ slot: Slot,
                         binding: HotkeyBinding,
                         action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(slot)

        let hotkeyID = EventHotKeyID(signature: signature, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode,
                                         binding.carbonModifiers,
                                         hotkeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { return false }

        refs[slot.rawValue] = ref
        actions[slot.rawValue] = action
        return true
    }

    public func unregister(_ slot: Slot) {
        if let ref = refs.removeValue(forKey: slot.rawValue) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: slot.rawValue)
    }

    public func unregisterAll() {
        for slot in refs.keys {
            if let ref = refs[slot] { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         voxelHotkeyHandler,
                                         1,
                                         &spec,
                                         nil,
                                         nil)
        handlerInstalled = (status == noErr)
    }
}
