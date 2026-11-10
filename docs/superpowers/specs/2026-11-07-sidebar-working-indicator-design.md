# Sidebar working indicator: the hairline sweep

The sidebar's status words, a green "working" and an orange "done · 2m", clash with the shimmering activity text beside them. This spec replaces them with a quieter design: a faint light runs along the bottom of a working row, the right side of the row shows numbers instead of words, and a coral dot marks a row that needs the user. Jacob picked it from four animated mockups (option D). The mockup is in `docs/superpowers/specs/2026-11-07-sidebar-working-indicator-mockup.html`; open it in a browser to see the motion.

## 1. What each state shows

Status today comes from `SessionAttention.status(...)` (`Sources/LinkCKit/Core/SessionAttention.swift`) as a `SessionRowStatus`. The new right-hand side of a row, by state:

| State | Today | New right side | Row decoration |
|---|---|---|---|
| `.working` | "working", green | time spent in this turn, e.g. "24s", "1m 12s", "3m 05s", "1h 04m"; tertiary text | the hairline sweep (§2) |
| `.finished` / `.waitingIdle`, not yet seen | "done · 2m", coral | "2m", tertiary, then a coral dot | none |
| `.waitingPermission` (needs you) | "needs you · 1m", coral | "1m", tertiary, then a coral dot that sends out a slow ring (§3) | none |
| `.ready`, or finished and seen | "idle 3m", tertiary | "3m", tertiary, no dot | none |
| `.starting` | "starting" | unchanged | none |
| `.error` | "error" / "rate limited", red | unchanged | none |
| `.ended` | "ended" | unchanged | none |

- **The time spent** is counted from the turn's start (`turnStartedAt`), kept across an answered permission prompt.
  - It reads "Ns" under a minute and "Nm SSs" under an hour (two-digit seconds).
  - It reads "Nh MMm" from an hour on (two-digit minutes).
- **Ages keep today's formatting and update schedule** (`AgeTimelineSchedule`). Only the "done ·", "needs you ·" and "idle" prefixes go.
- **No green** is used for a session's status any more. `Theme.statusRunning` may stay where other screens use it (the project dashboard); this spec does not change those.
- **Coral still marks attention, and only attention:**
  - `SessionRowStatus.isCoral` keeps its meaning (unseen done, needs you, error). The menu-bar tint and the project dot read it.
  - The coral *dot* replaces the coral *text*.

## 2. The hairline sweep (working rows)

- A 1 pt line along the bottom of the row, inset 10 pt from both edges, drawn over the row and taking no layout space.
- A soft white band glides along it from left to right: a gradient from clear to white at 70% opacity to clear, about 40% of the row's width. It loops over 1.6 s, ease-in-out, and the line is invisible outside the band.
- It runs only while the row is working. It follows the same rule as the activity text shimmer (`ShimmerPolicy`, `Sources/linkc/SmoothShimmer.swift`): it stops when the panel is hidden, when the row is off screen, or when Reduce Motion is on. With Reduce Motion, the row shows no line at all; the time spent still shows.

## 3. The dots

- A 7 pt circle, `Theme.accent` (coral), 6 pt after the age text, vertically centered.
- **Needs you:** the dot also sends out a ring:
  - a 1.5 pt coral stroke;
  - it grows from the dot's size to 2.6 times it while fading to clear, over 1.6 s, ease-out, repeating;
  - it stops under the same rule as the sweep, and with Reduce Motion the dot stays without a ring.

## 4. The model (LinkCKit)

Keep the decision in `SessionAttention.status(...)` and its tests, not in the view.
- `SessionRowStatus.Format` gains `case elapsed(since: Date)` for a working session. Its `text` is the time-spent string from §1, computed by a pure, tested function.
- `SessionRowStatus` gains a marker for the dot: `enum Marker { case none, dot, pingDot }`. The marker is `.dot` for unseen done and `.pingDot` for needs you.
- The `age` prefixes for done, needs you and idle become empty.
- `Tone` keeps its cases. `.working` now means "draw the sweep and show the time spent", not "green".

## 5. Views (linkC app)

- **`SessionStatusLabel`** (`Sources/linkc/Sidebar.swift`) renders all of it:
  - the elapsed time, refreshed once a second, but only while the panel or the row's window is visible: a `TimelineView` with a one-second schedule is paused when not visible, never a timer of its own;
  - the dot or the pinging dot;
  - the tertiary color for every state except error, which keeps today's red.
- **The sweep** is a view modifier on the session row, beside the existing shimmer code, applied when the status's tone is `.working`.
- **Every other place that shows a `SessionRowStatus`** follows the same rules, so the sidebar and the tab strip agree. Find them through `AppModel.rowStatus(_:)` (`AppModel+Sidebar.swift`, `LinkCApp.swift`).
- **No work happens in a view body** beyond reading values. The per-second updates live in `TimelineView`, and nothing writes observable state from a body.

## 6. Testing

- **`SessionAttentionTests`** gets the new table:
  - working: `.elapsed(since: turnStartedAt)`, tone `.working`, no marker;
  - unseen done: age, `.dot`, coral;
  - needs you: age, `.pingDot`, coral;
  - idle and seen: age, no marker, quiet;
  - error, starting and ended unchanged.
- **The time-spent formatter:** 0 s → "0s", 59 s → "59s", 60 s → "1m 00s", 185 s → "3m 05s", 3599 s → "59m 59s", 3600 s → "1h 00m", 3840 s → "1h 04m". A start time after now reads "0s".
- **`ShimmerPolicyTests`:** the sweep and the ring use the same policy.
- **Manual check (Jacob, on an installed build):**
  - a working row shows the sweep and a ticking time;
  - a finished, unseen row shows the coral dot;
  - a permission prompt shows the pinging dot;
  - hiding the panel stops all motion;
  - Reduce Motion removes the sweep and the ring.
