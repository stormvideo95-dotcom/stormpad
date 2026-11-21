import SwiftUI

struct Chip: View {
    let text: String
    var lit = false
    var key = false
    var body: some View {
        Text(text)
            .font(key ? .system(.body, design: .monospaced).weight(.semibold) : .body)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(lit ? Color.green : (key ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.15))))
            .foregroundColor(lit ? .black : .primary)
    }
}

struct SetupView: View {
    @ObservedObject var core: Core

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 30)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("StormPad").font(.title2).bold()
                    Text("Controller → real keyboard keys, in every app").foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(core.controllerNames.isEmpty ? Color.gray : Color.green).frame(width: 8, height: 8)
                    Text(core.controllerNames.isEmpty ? "No controller" : core.controllerNames.joined(separator: ", "))
                        .lineLimit(1).font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().stroke(Color.secondary.opacity(0.4)))
            }

            if !core.trusted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("StormPad needs **Accessibility** permission to press keys. Turn StormPad on in the list, then come back.")
                    Spacer()
                    Button("Open settings") { core.requestTrust() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.15)))
            }

            GroupBox(label: Text("Mappings").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(core.mappings.count) mapped").foregroundColor(.secondary)
                        Spacer()
                        Button("+ Add mapping") { core.startWizard() }.disabled(core.wizard != .idle)
                    }
                    if core.wizard != .idle {
                        HStack {
                            if core.wizard == .pad {
                                Text("**1 ·** Press a button or move a stick on your controller…")
                            } else {
                                Text("**2 ·** \(Keys.pretty(core.pendingInput ?? "")) got it! Now press a key (or combo like ⌘C)…")
                            }
                            Spacer()
                            Button("Cancel") { core.cancelWizard() }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1.5))
                    }
                    ScrollView {
                        VStack(spacing: 6) {
                            if core.mappings.isEmpty {
                                Text("No mappings yet — click **+ Add mapping**.").foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(core.mappings) { m in
                                let lit = core.activeInputs.contains(m.input)
                                HStack(spacing: 10) {
                                    Chip(text: Keys.pretty(m.input))
                                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                                    Chip(text: m.label, key: true)
                                    Spacer()
                                    Button(action: { core.delete(m) }) { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                }
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 9)
                                    .fill(lit ? Color.green.opacity(0.2) : Color.clear))
                            }
                        }
                    }
                    .frame(height: 220)
                }
                .padding(6)
            }

            GroupBox(label: Text("Live controller").font(.headline)) {
                Group {
                    if core.activeInputs.isEmpty {
                        Text(core.controllerNames.isEmpty
                             ? "No controller found. Plug it in. If it's a Trust GXT, switch it to D-mode (DirectInput) and try again."
                             : "Press something on your controller…")
                            .foregroundColor(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(core.activeInputs.sorted(), id: \.self) { Chip(text: Keys.pretty($0), lit: true) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .padding(6)
            }

            GroupBox(label: Text("Settings").font(.headline)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Mapping on", isOn: $core.enabled)
                        Spacer()
                        Button("Re-center sticks") { core.hub.recenter() }
                    }
                    Toggle("Holding a button repeats the key (good for typing, off for games)", isOn: $core.repeatKeys)
                    HStack {
                        Text("Stick sensitivity")
                        Slider(value: Binding(get: { 1 - core.deadzone }, set: { core.deadzone = 1 - $0 }), in: 0.1...0.8)
                        Text("\(Int((1 - core.deadzone) * 100))%").frame(width: 40)
                    }
                    if #available(macOS 13.0, *) {
                        Toggle("Open at login", isOn: Binding(get: { core.launchAtLogin }, set: { core.launchAtLogin = $0 }))
                    }
                }
                .padding(6)
            }
        }
        .padding(20)
        .frame(width: 580, height: 700, alignment: .top)
    }
}
