import SwiftUI

/// Where you point Echo at your Mac. These three values match
/// `core/voice/echo.conf` on the Mac side — same host reachability, same token.
struct SettingsView: View {
    @AppStorage("macHost") private var macHost = ""
    @AppStorage("macPort") private var macPort = "8790"
    @AppStorage("token") private var token = ""
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
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
