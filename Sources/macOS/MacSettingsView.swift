import SwiftUI

/// Mac settings (design: "on the Mac, host is just 127.0.0.1, so settings
/// shrink to the token" — still true since 2026-08-08, when echo-server.py went
/// tailnet-only for the phone but kept a loopback listener for exactly this):
/// connection fields, the duck engine picker, the
/// Test-duck button — which deliberately fires the one-time TCC prompt while
/// he's watching AND detects the silent-denial case by measuring captured
/// RMS — and the shared log ring.
struct MacSettingsView: View {
    @ObservedObject var client: EchoClient
    @AppStorage("macHost") private var macHost = ""
    @AppStorage("macPort") private var macPort = "8790"
    @AppStorage("token") private var token = ""
    @AppStorage("macDuckMode") private var duckMode = "tap"
    @AppStorage("duckGain") private var duckGain = 0.16
    @AppStorage("appTheme") private var appTheme = "auto"
    @ObservedObject private var log = EchoLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var duckVerdict: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Form {
                Section("This Mac's Echo server") {
                    TextField("Host", text: $macHost, prompt: Text("127.0.0.1"))
                    TextField("Port", text: $macPort, prompt: Text("8790"))
                    SecureField("Shared token", text: $token)
                    Text("The token must match core/voice/echo.conf. Leave host empty for 127.0.0.1 — the server runs on this Mac and always binds loopback alongside the tailnet address.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appTheme) {
                        Text("Auto").tag("auto")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appTheme) { _, t in Self.applyTheme(t) }
                }
                Section("Ducking") {
                    Picker("Engine", selection: $duckMode) {
                        Text("Process tap — ducks everything").tag("tap")
                        Text("AppleScript — Spotify & Music only").tag("applescript")
                    }
                    .pickerStyle(.radioGroup)
                    HStack {
                        Text("Music volume while Nic speaks")
                        Slider(value: $duckGain, in: 0.05...0.5)
                        Text("\(Int(duckGain * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    Button("Test duck") {
                        duckVerdict = "Testing — listen for the dip…"
                        client.testDuck { duckVerdict = $0 }
                    }
                    if let verdict = duckVerdict {
                        Text(verdict).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Log") {
                    if log.lines.isEmpty {
                        Text("Nothing yet.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        // Newest first — the line you need is the one from
                        // thirty seconds ago.
                        ForEach(Array(log.lines.reversed().enumerated()),
                                id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Button("Clear log", role: .destructive) { log.clear() }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 400, height: 480)
    }

    /// Theme = NSApp appearance: nil follows the system (Auto, the default).
    /// Called on change here and at launch from the app delegate.
    static func applyTheme(_ t: String) {
        switch t {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
