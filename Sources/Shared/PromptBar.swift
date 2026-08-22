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
            if let lane = client.openLane, let ask = pendingAsk {
                AskStrip(client: client, lane: lane, ask: ask)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
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
        .animation(.easeInOut(duration: 0.22), value: pendingAsk?.id)
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

    private var pendingAsk: EchoClient.AskInfo? {
        guard let lane = client.openLane else { return nil }
        return client.laneStates[lane]?.ask
    }
}

/// The model's question, made tappable — the last piece of the non-power-user
/// interface (2026-08-21). Tapping an option drives the terminal picker, so
/// the answer is the same one the dialog would have recorded; the dialog stays
/// live for the keyboard too. Multi-question asks list in order: answer the
/// first, the terminal advances, the next card follows it.
private struct AskStrip: View {
    @ObservedObject var client: EchoClient
    let lane: String
    let ask: EchoClient.AskInfo

    /// Rows toggled on for a multi-select question (indices into options).
    @State private var picked: Set<Int> = []
    /// The "Other" row's free text, when he'd rather answer in his own words.
    @State private var other = ""
    @State private var showingOther = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ask.questions.enumerated()), id: \.offset) { qi, q in
                VStack(alignment: .leading, spacing: 6) {
                    if !q.header.isEmpty {
                        Text(q.header.uppercased())
                            .font(.caption2.weight(.semibold))
                            .kerning(0.6)
                            .foregroundStyle(.tint)
                    }
                    // fixedSize: without it SwiftUI shrinks the question to
                    // one truncated line inside this stack — a question you
                    // can't finish reading is not a question (Ranny).
                    Text(q.question)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Only the FIRST question is answerable from here: the
                    // terminal picker shows one at a time, and a tap on a
                    // later one would land on the wrong list.
                    if qi == 0 {
                        ForEach(Array(q.options.enumerated()), id: \.offset) { oi, opt in
                            Button {
                                if q.isMulti {
                                    if picked.contains(oi) { picked.remove(oi) }
                                    else { picked.insert(oi) }
                                } else {
                                    client.answerAsk(lane: lane, choice: oi)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    // Multi-select shows real checkboxes: the
                                    // terminal is toggling rows with space, so
                                    // the card must read as "pick several".
                                    if q.isMulti {
                                        Image(systemName: picked.contains(oi)
                                              ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(picked.contains(oi)
                                                             ? AnyShapeStyle(.tint)
                                                             : AnyShapeStyle(.secondary))
                                            .frame(width: 14)
                                    } else {
                                        Text("\(oi + 1)")
                                            .font(.caption2.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 14)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(opt.label)
                                            .font(.callout)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        // The trade-off each option carries —
                                        // shown in the terminal, so it belongs
                                        // here too, or the choice is blind.
                                        if !opt.description.isEmpty {
                                            Text(opt.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(Color.primary.opacity(0.07))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        if q.isMulti {
                            Button {
                                client.answerAsk(lane: lane, choices: Array(picked))
                                picked = []
                            } label: {
                                Text(picked.isEmpty ? "Pick one or more"
                                                    : "Send \(picked.count) answer\(picked.count == 1 ? "" : "s")")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(picked.isEmpty)
                        }
                        // The "Other" row the terminal always offers: his own
                        // words instead of one of ours.
                        if showingOther {
                            HStack(spacing: 6) {
                                TextField("Your own answer", text: $other)
                                    .textFieldStyle(.plain)
                                    .onSubmit(sendOther)
                                Button(action: sendOther) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundStyle(other.isEmpty
                                                         ? AnyShapeStyle(.tertiary)
                                                         : AnyShapeStyle(.tint))
                                }
                                .buttonStyle(.plain)
                                .disabled(other.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        } else {
                            Button("Something else…") { showingOther = true }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("answer above first")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .onChange(of: ask.id) { _ in          // a new question starts clean
            picked = []; other = ""; showingOther = false
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                )
        )
    }

    private func sendOther() {
        let text = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.answerAsk(lane: lane, other: text)
        other = ""
        showingOther = false
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
                // In FULL (Ranny): deciding on a command you can only half
                // read is not deciding. The server caps the summary at 500
                // chars, so "all of it" stays a sane height; fixedSize is
                // what stops SwiftUI truncating it inside this stack.
                Text(confirm.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
