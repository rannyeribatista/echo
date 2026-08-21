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
