import SwiftUI

/// The cockpit's mouth (input phase, 2026-08-21 night): a glass field pinned
/// under the pager, on both platforms. Enter — or the send icon riding the
/// trailing edge — injects the draft into the OPEN lane's session (server
/// /prompt → herdr types + submits it). There is deliberately no local echo:
/// the bubble appearing in the transcript IS the delivery receipt (the
/// UserPromptSubmit mirror coming back through the server), so what he sees
/// is always what the session actually received. Slash commands ride the
/// same pipe untouched — "/model haiku" typed here IS a model switch.
///
/// Above the field, two transients: a failure line (409 no live session /
/// 502 injection trouble — success says nothing), and the permission strip —
/// when the open lane's harness is holding a PermissionRequest for Echo
/// (nic-confirm.sh), Allow / Deny answer it from right here; no decision and
/// the terminal dialog takes over ~25s later, untouched.
struct PromptBar: View {
    @ObservedObject var client: EchoClient
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let confirm = pendingConfirm {
                ConfirmStrip(client: client, confirm: confirm)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let why = client.promptFeedback {
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            HStack(alignment: .center, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(ready ? AnyShapeStyle(.tint)
                                               : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(!ready)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(glass)
        }
        .animation(.easeInOut(duration: 0.22), value: pendingConfirm?.id)
        .animation(.easeInOut(duration: 0.22), value: client.promptFeedback)
    }

    private var ready: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        client.openLane.map { "Message \(client.displayName(for: $0))" } ?? "Message"
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.sendPrompt(text)
        draft = ""
        focused = true            // keep the caret for the next thought
    }

    /// Ultra-thin material reads as glass on the cockpit ground on every OS
    /// this app targets; the hairline stroke gives the edge its catchlight.
    private var glass: some View {
        RoundedRectangle(cornerRadius: 21, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private var pendingConfirm: EchoClient.ConfirmInfo? {
        guard let lane = client.openLane else { return nil }
        return client.laneStates[lane]?.confirm
    }
}

/// The permission question, made tappable: tool name, the concrete input
/// (the command, the path), and the two answers. Lives in attention orange —
/// the same hue the orb turns when a lane waits on him.
private struct ConfirmStrip: View {
    @ObservedObject var client: EchoClient
    let confirm: EchoClient.ConfirmInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(confirm.tool)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Deny") { client.decideConfirm(confirm.id, allow: false) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Allow") { client.decideConfirm(confirm.id, allow: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if !confirm.summary.isEmpty {
                Text(confirm.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
        )
    }
}
