import AppKit
import ApplicationServices
import ServiceManagement

enum Wizard { case idle, pad, key }

final class Core: ObservableObject {
    @Published var mappings: [Mapping] = [] { didSet { save() } }
    @Published var enabled: Bool = true {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled"); if !enabled { releaseAll() }; onEnabledChange?(enabled) }
    }
    @Published var repeatKeys: Bool = false { didSet { UserDefaults.standard.set(repeatKeys, forKey: "repeat") } }
    @Published var deadzone: Double = 0.5 { didSet { UserDefaults.standard.set(deadzone, forKey: "deadzone"); hub.deadzone = deadzone } }
    @Published var activeInputs: Set<String> = []
    @Published var controllerNames: [String] = []
    @Published var trusted = false
    @Published var wizard: Wizard = .idle
    @Published var pendingInput: String?

    var onEnabledChange: ((Bool) -> Void)?

    let hub = InputHub()
    private var timer: Timer?
    private var slowTimer: Timer?
    private var baseline = Set<String>()
    private var monitor: Any?
    private var pendingMod: UInt16?

    private struct Held { var m: Mapping; var flags: CGEventFlags; var since: Date; var last: Date }
    private var held: [UUID: Held] = [:]
    private var heldMods: CGEventFlags = []

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "mappings"), let m = try? JSONDecoder().decode([Mapping].self, from: data) { mappings = m }
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        repeatKeys = d.bool(forKey: "repeat")
        deadzone = d.object(forKey: "deadzone") as? Double ?? 0.5
        hub.deadzone = deadzone
        trusted = Core.checkTrust()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(mappings) { UserDefaults.standard.set(data, forKey: "mappings") }
    }

    static func checkTrust() -> Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let s = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let tr = Core.checkTrust()
            if tr != self.trusted { self.trusted = tr }
            let names = self.hub.controllerNames
            if names != self.controllerNames { self.controllerNames = names }
            self.hub.debugDump(active: self.activeInputs)
        }
        RunLoop.main.add(s, forMode: .common)
        slowTimer = s
    }

    // MARK: loop
    private func tick() {
        let act = hub.active()
        if act != activeInputs { activeInputs = act }

        if wizard == .pad {
            if let fresh = act.subtracting(baseline).sorted().first {
                pendingInput = fresh
                wizard = .key
                beginKeyCapture()
            }
            baseline.formIntersection(act)
        }

        guard enabled, wizard == .idle, trusted else {
            if !held.isEmpty { releaseAll() }
            return
        }
        let now = Date()
        for m in mappings {
            let on = act.contains(m.input)
            if on && held[m.id] == nil { press(m, now) }
            else if !on && held[m.id] != nil { release(m.id) }
            else if on, repeatKeys, var h = held[m.id], Keys.modifierFlag(m.keyCode) == nil,
                    now.timeIntervalSince(h.since) > 0.4, now.timeIntervalSince(h.last) > 0.05 {
                KeyOut.key(m.keyCode, down: true, flags: h.flags, isRepeat: true)
                h.last = now
                held[m.id] = h
            }
        }
    }

    private func press(_ m: Mapping, _ now: Date) {
        if let mf = Keys.modifierFlag(m.keyCode) {
            heldMods.insert(mf)
            KeyOut.modifier(m.keyCode, flags: heldMods)
            held[m.id] = Held(m: m, flags: heldMods, since: now, last: now)
            return
        }
        var f = heldMods
        let combo = CGEventFlags(rawValue: m.flags)
        for (flag, code) in Keys.comboCodes where combo.contains(flag) && !f.contains(flag) {
            f.insert(flag)
            KeyOut.modifier(code, flags: f)
        }
        KeyOut.key(m.keyCode, down: true, flags: f)
        held[m.id] = Held(m: m, flags: f, since: now, last: now)
    }

    private func release(_ id: UUID) {
        guard let h = held.removeValue(forKey: id) else { return }
        let m = h.m
        if let mf = Keys.modifierFlag(m.keyCode) {
            heldMods.remove(mf)
            KeyOut.modifier(m.keyCode, flags: heldMods)
            return
        }
        var f = h.flags
        KeyOut.key(m.keyCode, down: false, flags: f)
        for (flag, code) in Keys.comboCodes.reversed() where f.contains(flag) && !heldMods.contains(flag) {
            f.remove(flag)
            KeyOut.modifier(code, flags: f)
        }
    }

    func releaseAll() {
        for id in Array(held.keys) { release(id) }
        heldMods = []
    }

    // MARK: wizard
    func startWizard() {
        releaseAll()
        baseline = hub.active()
        pendingInput = nil
        wizard = .pad
    }

    func cancelWizard() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        pendingMod = nil
        wizard = .idle
        pendingInput = nil
    }

    private func beginKeyCapture() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self = self, self.wizard == .key else { return e }
            if e.type == .keyDown {
                let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
                let flags = UInt64(f.rawValue)
                self.finish(code: e.keyCode, flags: flags,
                            label: Keys.prefix(flags) + Keys.name(e.keyCode, e.charactersIgnoringModifiers))
            } else if Keys.modifierFlag(e.keyCode) != nil {
                let down = e.modifierFlags.contains(Keys.nsFlag(e.keyCode))
                if down { self.pendingMod = e.keyCode }
                else if self.pendingMod == e.keyCode {
                    self.finish(code: e.keyCode, flags: 0, label: Keys.name(e.keyCode, nil))
                }
            }
            return nil
        }
    }

    private func finish(code: UInt16, flags: UInt64, label: String) {
        guard let input = pendingInput else { cancelWizard(); return }
        var list = mappings.filter { $0.input != input }
        list.append(Mapping(input: input, keyCode: code, flags: flags, label: label))
        mappings = list
        cancelWizard()
    }

    func delete(_ m: Mapping) { release(m.id); mappings.removeAll { $0.id == m.id } }

    // MARK: login item
    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
            return false
        }
        set {
            if #available(macOS 13.0, *) {
                do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { NSLog("StormPad login item: \(error)") }
            }
            objectWillChange.send()
        }
    }
}
