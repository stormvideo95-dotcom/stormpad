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
    // Raw Switch Pro (and clone) reports: sticks read directly + self-calibrated
    private var switchButtons = Set<String>()
    private var switchAxes: [String: Double] = [:]     // "sw:Left stick X" -> -1...1
    private var switchCenter: [Int: Int] = [:]         // axis index -> raw centre
    private var switchSpan: [Int: Double] = [:]        // axis index -> half range seen
    private var switchSeen = Date.distantPast
    private var reportBuffers: [String: UnsafeMutablePointer<UInt8>] = [:]
    var switchActive: Bool { Date().timeIntervalSince(switchSeen) < 1.0 }

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
        let vendor = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        if vendor == 0x057E && reportBuffers[key(d)] == nil {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
            reportBuffers[key(d)] = buf
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(d, buf, 512, { ctx, _, _, _, reportID, report, length in
                guard let ctx = ctx else { return }
                Unmanaged<InputHub>.fromOpaque(ctx).takeUnretainedValue().switchReport(reportID, report, length)
            }, ctx)
        }
    }

    func recenter() { switchCenter.removeAll(); switchSpan.removeAll() }

    private func switchReport(_ id: UInt32, _ p: UnsafeMutablePointer<UInt8>, _ len: Int) {
        // Buffer may or may not start with the report id byte.
        var o = 0
        if len > 0 && UInt32(p[0]) == id { o = 1 }
        guard id == 0x30 || id == 0x21, len - o >= 11 else { return }
        let r = { (i: Int) -> Int in Int(p[o + i - 1]) }   // r(1)=timer ... same layout as docs (byte index after id)
        let b3 = r(3), b4 = r(4), b5 = r(5)
        var bt = Set<String>()
        let add = { (on: Bool, n: String) in if on { bt.insert("sw:" + n) } }
        add(b3 & 0x01 != 0, "Y"); add(b3 & 0x02 != 0, "X"); add(b3 & 0x04 != 0, "B"); add(b3 & 0x08 != 0, "A")
        add(b3 & 0x40 != 0, "R"); add(b3 & 0x80 != 0, "ZR")
        add(b4 & 0x01 != 0, "Minus"); add(b4 & 0x02 != 0, "Plus"); add(b4 & 0x04 != 0, "Right stick click")
        add(b4 & 0x08 != 0, "Left stick click"); add(b4 & 0x10 != 0, "Home"); add(b4 & 0x20 != 0, "Capture")
        add(b5 & 0x01 != 0, "D-pad ↓"); add(b5 & 0x02 != 0, "D-pad ↑"); add(b5 & 0x04 != 0, "D-pad →")
        add(b5 & 0x08 != 0, "D-pad ←"); add(b5 & 0x40 != 0, "L"); add(b5 & 0x80 != 0, "ZL")
        switchButtons = bt
        let raw = [r(6) | ((r(7) & 0x0F) << 8), (r(7) >> 4) | (r(8) << 4),
                   r(9) | ((r(10) & 0x0F) << 8), (r(10) >> 4) | (r(11) << 4)]
        let names = ["Left stick X", "Left stick Y", "Right stick X", "Right stick Y"]
        for i in 0..<4 {
            let v = raw[i]
            if switchCenter[i] == nil { switchCenter[i] = v }
            let c = switchCenter[i]!
            let span = max(switchSpan[i] ?? 0, Double(abs(v - c)), 900)
            switchSpan[i] = span
            var n = Double(v - c) / span
            if i % 2 == 1 { n = -n }          // Switch: up is bigger -> make up negative like HID
            switchAxes["sw:" + names[i]] = n
        }
        switchSeen = Date()
    }

    private func removed(_ d: IOHIDDevice) {
        let k = key(d) + "|"
        hidNames.removeValue(forKey: key(d))
        if let b = reportBuffers.removeValue(forKey: key(d)) { _ = b }  // keep memory alive (callback may still fire)
        if reportBuffers.isEmpty { switchButtons = []; switchAxes = [:]; recenter() }
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
            for (name, d) in p.dpads where !(switchActive && name.contains("Thumbstick")) {
                let x = Double(d.xAxis.value), y = Double(d.yAxis.value)
                if x > dz { s.insert("gc:\(name) →") } else if x < -dz { s.insert("gc:\(name) ←") }
                if y > dz { s.insert("gc:\(name) ↑") } else if y < -dz { s.insert("gc:\(name) ↓") }
            }
        }
        if switchActive {
            s.formUnion(switchButtons)
            for (id, v) in switchAxes {
                let vertical = id.hasSuffix("Y")
                let base = String(id.dropLast(2))
                if v > dz { s.insert(base + (vertical ? " ↓" : " →")) }
                else if v < -dz { s.insert(base + (vertical ? " ↑" : " ←")) }
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
