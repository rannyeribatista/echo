# Echo Cockpit — the v3 window design (record of the 2026-08-21 sit, part 1)

> Design sit run on branch `design/cockpit` (base v2.0 main `964f7a9`), canvas at
> https://claude.ai/code/artifact/c4bcd391-dfd8-4bc7-a2c4-b53355978c3c (the session
> record; this file is the durable repo-side record — same pattern as
> `unification-design.md`). Personas: Ranny (listener & operator), Nic
> (coordinator), Wren (a silent worker lane). Prior record: `unification-design.md`
> (One Echo). This document covers the sit's first walked part — **the stories
> rail**; the remaining stops (assistant-feel frame, live-message evolution,
> finished→act flow, closing out) stay on the canvas for later sessions.

## Thesis

Echo's window becomes the face of the working system. The first element, top to
bottom, is a horizontal **stories rail** — one circle per open agent/lane/session
(Instagram-stories style), the ring around each circle carrying that lane's work
status and whether unheard content waits. Clicking a circle opens that lane's
messages. **Every lane speaks with its own voice, but only the open lane sounds
aloud** — other lanes queue silently and light their ring. In Ranny's words: each
lane owns its own communication, "which kinda makes every session its own
orchestrator." One session can optionally be promoted to **main orchestrator**
and lead the audio (today's Nic behavior, kept as a mode).

## The calls resolved 2026-08-21 (Ranny's, quoted or paraphrased)

1. **A5 (inherited from One Echo) — Echo owns routing.** Every session's finished
   turn POSTs to Echo through the universal shim; Echo decides what sounds (open
   lane aloud, others ring + queue, main leads); the `owner`/`mailbox` files stay
   as the orchestrator session's reading surface. This closes the amber One Echo
   left standing, on its "Echo as the orchestrator's dashboard" branch.
2. **A10 — main-orchestrator semantics: "we could have both."** With a main set,
   the main lane behaves exactly as today's Nic — watches the mailbox, composes
   the announcement in its own words, its voice leads. *And* the working lane's
   original message still arrives in Echo, sits in its pane ring-lit, available
   in the lane's own words on consult. Router rule that falls out: **the sounding
   set = the open lane ∪ the main lane (if set)**; arrivals queue behind live
   audio, never cut it (standing walkie rule). Motivating scenario for keeping
   the mode: running with the phone locked while multiple lanes work.
   On the consequence (no-main mode = nobody curates cross-lane; Ranny curates by
   choosing the open circle): "agreed and expected" — the point is interacting
   with any lane the way only the orchestrator lane allows today.
3. **A9 — ring vocabulary = whatever the harness actually distinguishes.** "The
   rings can simply reflect whatever statuses are possible from original Claude
   statuses." Verified against current Claude Code hook docs: four states plus an
   honest failure flavor, every one deterministic (table below). The board-rhyme
   collision on "ready" dissolves: the rail only shows lanes whose session
   exists, so the board's ready-to-dispatch never appears on it.
4. **A8 — sequencing, resolved by action.** "Start small — no need to rush the
   architectural decisions," then the go on building the rail. That is Shape C in
   practice: the rail builds on the v2.0 base now; One Echo P1 (native render)
   lands whenever, beneath the `ClipPlayer` seam; the status feed is designed
   Echo-side (per A5) so P2 absorbs it rather than rebuilding it.

## The status state machine (A9, doc-verified)

| Ring | Deterministic signal | Board rhyme (spec §2.2) |
|---|---|---|
| **ready** — open, not yet prompted | `SessionStart` (startup/resume distinguished by matcher), no prompt yet | just-dispatched |
| **working** | `UserPromptSubmit` → until `Stop`; `PreToolUse` ticks may pulse the ring (real heartbeat) | running |
| **needs attention** | `Notification` (`permission_prompt` · `idle_prompt` · `agent_needs_input`) · `PermissionRequest` · `StopFailure` (turn died on API error — never leaves a ring stuck "working") | blocked (plus micro-blocks the board never sees) |
| **finished** | `Stop` — turn done, message lands in the lane's pane (dot = unheard) | review |
| *closed* — circle leaves | `SessionEnd` (reason: clear/logout/exit) | merged/closed |

Wiring facts that shape the shim (doc-confirmed): **ignore subagent events**
(`agent_id` payloads; `SubagentStop` can fire after the main turn already
stopped — the same lesson herdr's hook records in its comments). `Notification`
carries `session_id` but **not** `cwd` → Echo keeps a session→lane map learned
from events that carry both. Lane identity = session cwd basename ("home" for
`~`); collisions acceptable v0, `session_id` is in every payload if circles ever
need to split per-session.

## Target shape

```
Every Claude session (composes; curates its own output)   ← unchanged, by design
  ├─ say shim (Stop): extract → POST /say, lane-tagged — never speaks
  ├─ status shim (~10 lines, async): SessionStart · UserPromptSubmit · Stop ·
  │  StopFailure · Notification · SessionEnd → POST /status {lane, session, event}
  └─ mailbox write stays (the orchestrator session's reading surface)
        └─ Echo, the router: sounding set = open lane ∪ main lane ·
           others → ring + silent per-lane queue · quit → spool (quiet) ·
           rail = shared SwiftUI view (iPhone inherits it)
```

The structural gap this closes (verified before design): with an owner set,
`nic-say.sh:61-76` writes a worker's turn to the mailbox and exits before
anything renders or enqueues — **nothing of a worker ever reaches Echo today**.
The rail's second circle exists only once every session posts. That change is
One Echo's P2 shim direction arriving early, not new architecture.

## Build spec — the stories rail (dispatch-ready)

> **Status: BUILT 2026-08-21, same sit** ("ship it" — Ranny), on `design/cockpit`
> (echo) + `feature/cockpit-rail` (core). Both app targets compile; the server
> state machine, status shim, worker fall-through, and scoped hush are proven
> 25/25 by an end-to-end run on an alternate port with an isolated outbox
> (live pipeline untouched). App-side E2E is the deploy moment: rebuild + sign
> both apps, wire the status hooks, then `ECHO_ALL_LANES=on`.

**Outcome:** the rail live in both apps, per-lane audio gating, status rings,
main-orchestrator toggle. ≈ 2½–3½ lane-days, four independently shippable layers.

| Layer | Builds | Size |
|---|---|---|
| 1 | Rail view (shared) · lane-scoped history + card · per-lane arrival queues · open-lane-only auto-play. Works against today's server (circles from 24h lane tags). | ~1 day |
| 2 | `nic-say.sh` mailbox branch stops exiting early: workers also render + enqueue, lane-tagged (mailbox write stays). Gate: `ECHO_ALL_LANES` in voice.conf. | ~½–1 day |
| 3 | Status shim (`nic-status.sh`, async on the six events) + `/status` on the server + per-lane ring state in the app. | ~½ day |
| 4 | Main-orchestrator toggle: router rule (sounding set) + writes the `owner` file. | ~½ day |

**Acceptance criteria (testable):**

1. Two sessions open (coordinator + one worker) → two circles, each appearing
   within one poll cycle of its session's first event.
2. Prompting a session flips its ring to working; tool activity animates it.
3. A permission prompt or 60s idle in any session flips its ring to
   needs-attention within async-hook latency (~1s).
4. A worker's finished turn: pane open → plays aloud under walkie rules; pane
   not open → silent, ring lit + dot; full text present in its pane either way.
5. Main set → only the main lane sounds regardless of arrivals; the worker's
   original stays in its pane, ring lit. Clearing main restores the open-lane rule.
6. `StopFailure` shows needs-attention — never a ring stuck on working.
7. `ECHO_ALL_LANES=off` → behavior identical to v2.0 (workers mailbox-only, one
   voice). One line, no rebuild.
8. New apps against an old server degrade to a lanes-from-history rail; an old
   phone build against the new server keeps today's behavior until updated.
9. Quit Echo → silence; on return, rings and dots reflect what spooled.

**Sequencing gate (learned from walkie v2):** the moment workers post, an
un-updated app plays every lane ungated — so **both apps rebuild with the rail
before `ECHO_ALL_LANES` flips on**. The flag is the transition gate, same
pattern as `ECHO_LEGACY_CLIP`. Headless build/sign/ship proven 2026-08-21.

**Decidable in-lane (listed so nothing surfaces as a surprise):** how status
events reach the app (fold into the existing long-poll vs a `/v2/status` poll) ·
exact `/status` POST shape (token-gated like everything else) · hush scope under
multiple lanes (recommend: any prompt quiets the room, as today — One Echo A7
still observes) · the main toggle writes `owner` for routing, but the re-speak
behavior still needs the chosen session running the coordinator ritual ("claim
the voice") — v0 keeps the ritual unchanged.

**Resolved from the first live drive (2026-08-21, Ranny at the window):**
**ghost the dead.** The owner role hopped across sessions for 36h, so the 24h
history carried lane tags from closed sessions and the v0 history-union rule
gave each a full circle (8 showed; 5 were dead). Rule now: once the status
feed has spoken, lanes it doesn't know — or knows closed — render as ghosts:
dashed, dim, sorted last, no main toggle, tappable for their history, gone
with the 24h sweep. Feed absent (old server) → nothing ghosts. Chosen over
hiding so open-vs-gone reads at a glance and unheard backlogs (Journaling had
13) stay reachable. Follow-ups filed by the same drive: a `claude -p` session
exits before its async Stop hook runs and strands a "working" ring (candidate:
server-side working→ready decay) · lane display names are raw cwd basenames
(mapping belongs to the profile-pictures pass).

**Resolved across the live drive (same day) — the MESSAGE PAGER, the final
Stop-3 shape.** Four passes of scroll mechanics taught the lesson the hard
way: modern SwiftUI ScrollView on macOS is not NSScrollView-backed —
`ScrollTargetBehavior`, GeometryReader offset preferences, and clip-view
observation all had nothing to hook. The final design (Ranny's redesign)
stops asking the framework: **one message fills the pane** — small text
vertically centered (17pt, centered alignment, 28pt breathing at both ends),
tall text scrolling within its container — and an NSEvent scroll-wheel
monitor over the pager area drives all physics. Pushing past a message's
edge is the page switch: rubber-banded elastic pull (asymptotic 90/140
curve), 150pt threshold, springs 0.42/0.85 (switch) and 0.3/0.8 (release);
gesture deltas count toward the pull, momentum only scrolls — crossing an
edge takes a deliberate push. Entering from below lands at the message's
bottom; a LIVE message lands on its sounding paragraph (per-message
paragraph-position maps) so the highlight follows you back. Floating
arrow-down button returns to the newest and re-arms follow-the-newest.
Fades: the page reads strong; while audio plays only the sounding paragraph
stays strong. iOS: same layout, native inner scroll, no edge gesture yet.

Bugs the drive caught and killed: per-page height clobbering during switch
transitions (two alive pages shared one scalar) · the stale-capture bug (the
engine's onSwitch closure froze the clips array at onAppear — lists must
derive from the client reference) · double-reproduction (stale auto-play
tickets + selectLane queueing the sounding message behind itself) · the
preamble predating the rail (owner-gated worker openings; now flag-gated
like nic-say, with per-session dedup state/hash).

**Cockpit rounding (drive close):** the status row died — status (dot + one
word, no counters) and Settings live in the Echo app menu; quit is the off
switch. "Stop listening" became MUTE (messages arrive and light dots, never
auto-play, taps still obey). One control row: transport left, right cluster =
auto-play (bolt) · reasoning/full-play segmented (brain/infinity) · mute
(speaker). "Play again" gone — every paragraph is a play button. Freed height
reserved for user input (next iteration). Full lifecycle verified live:
ready → working → finished → ghost on a fresh terminal lane, closed by hand.

**Design notes (recommendations, revisit from use):** render every worker turn
v0 — background audio has no latency requirement; defer-render-until-opened is
the many-lane optimization and lands naturally after P1's warm engine · worker
speech = cleaned text as-is; the headline/announcement wrapper stays
coordinator-only · ring colors (visual pass later, like profile photos): teal
working (pulsing), amber needs-attention, solid+dot finished-unheard, dim
hollow ready, red flavor on failure · in main mode a re-spoken original keeps
its lit ring (it's the consult pointer); soften only if real use finds it noisy.

## Premise check

Claude keeps exactly its two jobs — composing words, curating its own output.
The hooks stay deterministic shims that never speak. Routing, rings, and the
orchestrator rule are router logic inside the Echo bundle — exactly what One
Echo's P2 planned to move there. Quit means quiet holds (closed Echo = every
lane spools; rings light on return). P1 is untouched beneath the `ClipPlayer`
seam.

## Open remainder (the sit continues on the canvas)

- Stop 1 — the cockpit at rest (assistant-feel frame, feature ①): unwalked.
- Stop 3 — the live message evolving: unwalked.
- Stop 4 — the finished→consult→act flow (beyond the ring): unwalked.
- Stop 5 — closing out / history / quit-means-quiet surfaces: unwalked.
- Parked (their own sits): voice IN · Project Parking Lot browser surface ·
  One Echo's parked list.

## Ops residue — EXECUTED at the 2.1.0 deploy (2026-08-21 evening)

> Shipped: both repos merged to main and pushed · canonical EchoMac 2.1.0
> dev-signed at the login path · iPhone 2.1.0 installed over USB (fresh 7-day
> clock) · hooks rewired to live core paths · ECHO_ALL_LANES=on live · server
> restarted from main · integrity baseline + core backup. The amber-orb icon
> (a frozen frame of the sphere itself) rides both apps. Remaining from the
> list below: only the orchestrator-spec §5 sync (Nic's file, next touch).

## Ops residue (as accumulated during the sit)

- `nic-orchestrator-spec.md`: the single-voice/owner assumption becomes the
  optional main-orchestrator mode (sanctioned 08-21, A10) — sync at re-sync.
- `unification-design.md`: mark A5 resolved (Echo owns routing; shim posts every
  session; mailbox = orchestrator's reading surface).
- At deploy: rebuild + re-sign both apps → then `ECHO_ALL_LANES=on` · board
  reflection is Nic's (single-writer) · core-side `integrity.sh baseline` +
  `./backup.sh` after the spec syncs.

## Input phase — dispatch-ready spec (2026-08-21 night; build after token reset)

> The cockpit becomes the primary interaction surface: type to any lane from
> Echo (Mac AND phone) — no more app-switching to the terminal/Termius. Lays
> the VoiceFlow rail: voice-in later lands on the same endpoint. Budget note:
> deliberately NOT built same-day (14% Fable remaining); the one hard unknown
> was spiked instead and is SOLVED.

**The proven primitive (spike 2026-08-21, `it-really-works-42`):** herdr's CLI
injects into panes — `herdr pane send-text <pane> <text>` + `herdr pane
send-keys <pane> enter` executed a command in a live scratch pane, verified by
filesystem side effect. Also available: `herdr agent send <target> <text>`
(agent/session-addressed — herdr already knows session→pane from the very
`report-agent-session` hook wired on this Mac), `herdr agent list` (the
mapping), `herdr agent wait --status`, and **raw `send-keys`** (arrow keys,
enter — and the mode-cycle chord, if herdr names it; verify `shift+tab` naming
during build).

**The pipe:** Echo app (input box) → `POST /prompt {lane, text}` on
echo-server (token-gated, same pattern as /status and /links) → a small
dispatcher resolves lane → session (the status feed's session ids) → `herdr
agent send` (fallback: pane send-text via the session→pane map) + enter.
Server-side, ~40 lines; phone works free via the same tailnet endpoint.

**The UI (all owned territory):**
- Turn containers: one magnetic page = user prompt + preamble + final. Group
  key = `prompt_id` (hook payloads carry it — nic-say/nic-preamble/nic-status
  pass it through sidecars/manifests; app groups clips by (lane, prompt_id)).
- Bubbles: semi-transparent matte/satin, background-tone rule; Ranny's inputs
  a lighter tone than Claude's outputs.
- TERMINAL prompts appear too: `UserPromptSubmit` payload includes
  `user_input` — the status shim posts it, so prompts typed in the terminal
  render as bubbles in Echo. Both input surfaces converge in one transcript.
- The input field: liquid glass (macOS/iOS 26 `glassEffect` where available,
  `.ultraThinMaterial` fallback), send icon inside the trailing edge. Sits in
  the height cleared by the cockpit rounding.

**The full non-power-user horizon (Ranny's question, assessed):** everything
still missing collapses onto two primitives, both now in hand —
1. *Injection* (proven): free text → prompts · `/model …` and ANY slash
   command → model switch + a future command palette · `send-keys` raw →
   mode cycling (shift+tab) and dialog navigation (arrows/enter/number keys
   for AskUserQuestion option picking — payload carries the full question +
   options via PreToolUse `tool_input`, so Echo can RENDER the question
   natively and inject the choice).
2. *Decision hooks* (no injection needed at all): a `PermissionRequest` hook
   can RETURN `{permissionDecision: allow|deny}` — so permission confirmations
   can be a synchronous hook that asks echo-server "does Ranny approve?",
   Echo shows Allow/Deny on the attention-orange orb (tool name + input in
   the payload), the answer flows back as the hook's output. Cleaner than
   keystrokes; timeout falls back to the terminal dialog untouched.
   Verdict: a fully human-first Claude CLI face is genuinely reachable —
   output ✓, links ✓, agent spawn (via prompt) ✓, input/model/slash =
   injection, confirmations = decision hook, mode switch = raw keys.

**Sizing:** UI + grouping ≈ ½–1 heavy day · dispatcher + shim pass-through ≈
½ day · confirmations/mode/model each small once the base lands. Performance
investigation (To-Do, 📅 08-25) should precede or ride along — the input surface
deserves 60fps.

**BUILD EXECUTED (2026-08-21 night, post-compact).** Everything above is live:
server /prompt + /keys (herdr dispatch, lane→pane via `agent list`; key
allowlist), /confirm round-trip (nic-confirm.sh sync PermissionRequest hook →
Allow/Deny in the apps' ConfirmStrip → decision JSON; 25s fallback to the
terminal dialog), user prompts mirrored as role:"user" chunkless manifests
(BOTH surfaces — Echo field and terminal), prompt_id through the whole queue
chain (nic-status stash → .pid sidecar → NIC_PROMPT → manifests/sidecars),
turn containers in the pager (String page ids; a page = bubble + opening +
final), PromptBar glass field both platforms, mode cycle in the orb context
menu. E2E proof: injected prompt → Nic (home) → reply manifest carried the
same prompt UUID — one turn page. Deployed: core main + echo main, canonical
Mac relaunched. Deferred: AskUserQuestion native rendering (attention orb +
free-text injection cover the flow meanwhile). Pending at close: phone
install (device unreachable), PermissionRequest hook wire in settings.json
(classifier blocked the edit — needs Ranny's hand; snippet in the session
close-out).

**INPUT PHASE COMPLETE — 2026-08-21, every surface verified live.**
Type to any lane · hear and read every turn · switch permission modes ·
answer permission requests · **answer the model's questions**. Nothing
pending; the non-power-user interface is closed.

*AskUserQuestion (the last piece).* nic-ask.sh publishes the question and
its option labels on scoped Pre/PostToolUse matchers (async — it can never
stall a turn); they ride the status snapshot; AskStrip renders them above
the input. A tap ANSWERS BY DRIVING THE TERMINAL PICKER — `down` × index
then `enter` — so Echo's tap and the keyboard produce the identical
result and the dialog stays fully usable. Only the first question is
tappable: the picker shows one list at a time, and a tap on a later one
would land on the wrong list. Proven by using it for a real decision
(server log: `ASK open` → `ASK answer … option 0`, tool returned that
option). Deliberately unbuilt: multiSelect toggling (needs space) and the
free-text "Other" row.

*Performance — 65% → 12% idle CPU (same Debug build; ~5x), 2026-08-21.*
Profiled with `sample(1)`, not guessed, and the guess in the To-Do was
WRONG: the cost was never Canvas/blur drawing or the audio stack — it was
SwiftUI **layout**, driven by O(clips) derived state recomputed inside the
rail's 24fps animation. `EchoClient.lanes` walked every clip (once per orb
per frame, plus twice more from CockpitGround) and `TranscriptView.ordered`
rebuilt the whole turn grouping ~5× per body pass. Both are now cached on
the client, invalidated by `didSet` on clips / laneStates / openLane /
mainLane. **That is the mechanism behind "it degrades through the day and
a relaunch fixes it"**: per-frame work scaled with the day's message count.
Also cut: 10Hz `audioLevel`/`playbackTime` publishes now fire only on a
change worth a repaint (every view observes that one object), fleet orbs
animate at 12fps, and nothing animates while the window is occluded.
Release measures 9.5% but canonical deliberately STAYS on Debug (Ranny's
call, answered from Echo): re-signing risks a ducking-permission re-grant
for ~2 points of CPU. Method note for next time: `sample <pid> 3 -f out`
then rank frames — it named the two getters in one pass.

*The last bug, and its lesson.* Allow/Deny taps flowed end-to-end for hours
(the server logged `CONFIRM → allow`, the hook returned it) while the
harness silently ignored the decision. The published docs — and a
docs-reading subagent quoting them — say the payload is a flat string
`"decision":"allow"`. **It is not.** The CLI's own zod validator (2.1.239),
read straight out of the binary, wants an OBJECT:

```
hookSpecificOutput.decision = {"behavior":"allow"}                (allow)
                            | {"behavior":"deny","message":"…"}   (deny)
```

The harness reads `decision.behavior`; the flat string fails the shape and
falls through to the dialog with no error surfaced anywhere. Lesson worth
keeping: **for hook payload schemas the shipped binary is ground truth, not
the docs** — `strings "$(readlink -f ~/.local/bin/claude)" | grep -o
'PermissionRequest"),decision.\{0,200\}'` settles it in one command. Proof
of the fix is harness-side, in the session transcript:
`{"type":"hook_permission_decision","decision":"allow","hookEvent":
"PermissionRequest"}` — tool calls approved from the cockpit with no
terminal dialog. nic-confirm.sh logs every emission (`confirm: EMITTED
allow …` in nic-say.log), which is what split "script never emitted" from
"harness ignored it".

*Context that took the night to learn:* herdr is now 0.8.2 (brew,
symlinked at ~/.local/bin/herdr; 0.7.1 backed up beside it) — send-keys
encodes modifiers correctly, so mode cycling is headless (verified circle
default→acceptEdits→plan→auto→default; Echo even set its own lane's mode to
stage the confirm test); 0.8.2 `agent read` prints PLAIN TEXT where 0.7
sent JSON (probe_mode accepts both); echo-server's status seq is
clock-seeded (a zero-reset stranded apps on stale snapshots — the stuck
strip with dead buttons); confirm wait is 240s, deliberately under the
harness's 300s hook ceiling so the hand-back to the terminal is ours and
orderly. **AskUserQuestion rendering is now UNBLOCKED** (arrows/digits/
enter land) — the natural next build after the 08-25 token reset.

**Ride-along adjustments (Ranny, 2026-08-21 night — ship with the input build):**
- iPhone: the transport is claustrophobic in the narrow width — audio controls
  (buttons + scrubber + Continue) move to a NEW ROW beneath the mode row;
  the chunk counter ("n of m") stays far-left ON the mode row. Phone only;
  the Mac keeps its single row.
- Both platforms: MUTE is redundant with auto-play — remove the mute feature
  entirely; the auto-play toggle adopts the speaker/mute iconography
  (speaker.wave = auto-play on · speaker.slash = off) instead of the bolt.
  Strip the `muted` gates from EchoClient (`isMuted`, the autoPlayArrived/
  selectLane/playNextQueued guards) and the `muted` @AppStorage.
