import SwiftUI

/// Where you point Echo at your Mac. These three values match
/// `core/voice/echo.conf` on the Mac side — same host reachability, same token.
/// Also shows the diagnostic log ring, so "it didn't play" is answerable
/// from the phone.
struct SettingsView: View {
    @AppStorage("macHost") private var macHost = ""
    @AppStorage("macPort") private var macPort = "8790"
    @AppStorage("token") private var token = ""
    @ObservedObject private var log = EchoLog.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Your Mac (over Tailscale)") {
                    TextField("Mac host, e.g. 100.x.x.x", text: $macHost)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $macPort)
                        .keyboardType(.numbersAndPunctuation)
                    SecureField("Shared token", text: $token)
                }
                Section {
                    Text("Run `tailscale ip -4` on the Mac for the host. The token must match core/voice/echo.conf.")
                        .font(.footnote).foregroundStyle(.secondary)
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
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
