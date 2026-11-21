import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let core = Core()
    var status: NSStatusItem!
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "StormPad")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        core.onEnabledChange = { [weak self] on in self?.status.button?.appearsDisabled = !on }
        status.button?.appearsDisabled = !core.enabled
        core.start()
        if !core.trusted { core.requestTrust() }
        if core.mappings.isEmpty { openSetup() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "StormPad", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let pads = core.controllerNames.isEmpty ? "No controller" : core.controllerNames.joined(separator: ", ")
        let p = NSMenuItem(title: "🎮 " + pads, action: nil, keyEquivalent: "")
        p.isEnabled = false
        menu.addItem(p)
        menu.addItem(.separator())
        let on = NSMenuItem(title: "Mapping on", action: #selector(toggle), keyEquivalent: "")
        on.target = self
        on.state = core.enabled ? .on : .off
        menu.addItem(on)
        let setup = NSMenuItem(title: "Open setup…", action: #selector(openSetup), keyEquivalent: ",")
        setup.target = self
        menu.addItem(setup)
        if !core.trusted {
            let t = NSMenuItem(title: "⚠️ Allow Accessibility…", action: #selector(allow), keyEquivalent: "")
            t.target = self
            menu.addItem(t)
        }
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit StormPad", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    @objc func toggle() { core.enabled.toggle() }
    @objc func allow() { core.requestTrust() }
    @objc func quit() { core.releaseAll(); NSApp.terminate(nil) }

    @objc func openSetup() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "StormPad"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(core: core))
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { core.cancelWizard() }
}
