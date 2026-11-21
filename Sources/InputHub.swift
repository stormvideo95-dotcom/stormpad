import Foundation
import GameController
import IOKit
import IOKit.hid

/// Reads every controller: modern ones via GameController, generic/DirectInput ones via raw HID.
final class InputHub {
    var deadzone: Double = 0.5
    private var manager: IOHIDManager?
    private var buttons: [String: Bool] = [:]   // "dev|hid:Button 3"
    private var axes: [String: Double] = [:]    // "dev|hid:Axis X" -> -1...1
    private var hats: [String: Int] = [:]       // "dev|hid:Hat" -> 0..7 or -1
    private var hidNames: [String: String] = [:]

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        setupHID()
    }

    var controllerNames: [String] {
        var n = GCController.controllers().map { $0.vendorName ?? "Controller" }
        for v in hidNames.values where !n.contains(v) { n.append(v) }
        return n
    }

    private func setupHID() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let usages = [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController]
        let matches: [CFDictionary] = usages.map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<InputHub>.fromOpaque(ctx).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<InputHub>.fromOpaque(ctx).takeUnretainedValue().removed(device)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            guard let ctx = ctx else { return }
            Unmanaged<InputHub>.fromOpaque(ctx).takeUnretainedValue().handle(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }

    private func key(_ d: IOHIDDevice) -> String { String(CFHash(d)) }

    private func added(_ d: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "USB controller"
        hidNames[key(d)] = name
    }

    private func removed(_ d: IOHIDDevice) {
        let k = key(d) + "|"
        hidNames.removeValue(forKey: key(d))
        buttons = buttons.filter { !$0.key.hasPrefix(k) }
        axes = axes.filter { !$0.key.hasPrefix(k) }
        hats = hats.filter { !$0.key.hasPrefix(k) }
    }

    private func axisName(_ u: Int) -> String? {
        switch u {
        case kHIDUsage_GD_X: return "Axis X"
        case kHIDUsage_GD_Y: return "Axis Y"
        case kHIDUsage_GD_Z: return "Axis Z"
        case kHIDUsage_GD_Rx: return "Axis Rx"
        case kHIDUsage_GD_Ry: return "Axis Ry"
        case kHIDUsage_GD_Rz: return "Axis Rz"
        case kHIDUsage_GD_Slider: return "Slider"
        case kHIDUsage_GD_Dial: return "Dial"
        default: return nil
        }
    }

    private func handle(_ value: IOHIDValue) {
        let el = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(el))
        let usage = Int(IOHIDElementGetUsage(el))
        let dk = key(IOHIDElementGetDevice(el)) + "|"
        let v = IOHIDValueGetIntegerValue(value)

        if page == kHIDPage_Button {
            buttons[dk + "hid:Button \(usage)"] = v != 0
            return
        }
        guard page == kHIDPage_GenericDesktop else { return }
        switch usage {
        case kHIDUsage_GD_Hatswitch:
            let lo = IOHIDElementGetLogicalMin(el), hi = IOHIDElementGetLogicalMax(el)
            let count = max(1, hi - lo + 1)
            hats[dk + "hid:Hat"] = (v >= lo && v <= hi) ? (v - lo) * 8 / count : -1
        case kHIDUsage_GD_DPadUp: buttons[dk + "hid:D-pad ↑"] = v != 0
        case kHIDUsage_GD_DPadDown: buttons[dk + "hid:D-pad ↓"] = v != 0
        case kHIDUsage_GD_DPadLeft: buttons[dk + "hid:D-pad ←"] = v != 0
        case kHIDUsage_GD_DPadRight: buttons[dk + "hid:D-pad →"] = v != 0
        default:
            guard let name = axisName(usage) else { return }
            let lo = Double(IOHIDElementGetLogicalMin(el)), hi = Double(IOHIDElementGetLogicalMax(el))
            guard hi > lo else { return }
            axes[dk + "hid:" + name] = (Double(v) - lo) / (hi - lo) * 2 - 1
        }
    }

    private func strip(_ k: String) -> String {
        guard let i = k.firstIndex(of: "|") else { return k }
        return String(k[k.index(after: i)...])
    }

    /// All inputs that are pressed right now, e.g. "gc:Button A", "hid:Axis X ←".
    func active() -> Set<String> {
        var s = Set<String>()
        let dz = deadzone
        for c in GCController.controllers() {
            let p = c.physicalInputProfile
            for (name, b) in p.buttons where b.isPressed { s.insert("gc:" + name) }
            for (name, d) in p.dpads {
                let x = Double(d.xAxis.value), y = Double(d.yAxis.value)
                if x > dz { s.insert("gc:\(name) →") } else if x < -dz { s.insert("gc:\(name) ←") }
                if y > dz { s.insert("gc:\(name) ↑") } else if y < -dz { s.insert("gc:\(name) ↓") }
            }
        }
        for (k, on) in buttons where on { s.insert(strip(k)) }
        for (k, v) in axes {
            let id = strip(k)
            let vertical = id.hasSuffix("Y") || id.hasSuffix("Ry") || id.hasSuffix("Rz")
            if v > dz { s.insert(id + (vertical ? " ↓" : " →")) }
            else if v < -dz { s.insert(id + (vertical ? " ↑" : " ←")) }
        }
        for (_, h) in hats where h >= 0 {
            if [7, 0, 1].contains(h) { s.insert("hid:D-pad ↑") }
            if [1, 2, 3].contains(h) { s.insert("hid:D-pad →") }
            if [3, 4, 5].contains(h) { s.insert("hid:D-pad ↓") }
            if [5, 6, 7].contains(h) { s.insert("hid:D-pad ←") }
        }
        return s
    }
}
