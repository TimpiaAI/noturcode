# Notch Motion Contract

This contract controls the compact-to-hover transition. Keep it in sync with
`AdaptiveDockHeader` in `Sources/NoturcodeApp/NotchSurfaceView.swift`.

```text
REST -> 0-60 ms chips fade out -> 60-160 ms quote fades in -> HOVER
HOVER -> 0-60 ms quote fades out -> 60-160 ms chips fade in -> REST
```

## Stable shell

The compact and hover states use one mounted surface. The following parts stay
mounted for the full transition:

- the AppKit window envelope;
- the notch background;
- `AdaptiveDockHeader`;
- the Noturcode mark;
- the separator;
- the header content slot.

Do not replace the full header view. Do not animate a second card over it.

## Header content

The compact state shows the session chips. The hover state shows one short Bill
Gates quote. The quote changes every 10 seconds with a 240 ms opacity change.
It does not show a session state, preview, count, marble, provider mark, or
action. Quote sources are in `docs/QUOTE-SOURCES.md`.

`ExpandedSessionList` receives the full `SessionStore.sortedSessions` list. The
quote header does not remove or filter a session.

The header content uses opacity only. Do not add scale, offset, blur, or matched
geometry effects. The two content states must not be visible at the same time.

On a built-in display with a physical notch, the compact surface is the notch:

```text
[brand + latest session] [physical camera gap] [+N aggregate state]
```

The built-in compact surface shows one named session on the left and one fixed
78 point overflow chip on the right. The overflow marble combines the state of
all other sessions. The two wings stay at the native notch height. They reserve
the camera gap with an empty layout region. External displays keep the floating
pill and quote transition described above. Do not apply the fused-wing layout
to an external display.

On hover, the built-in surface grows to a 640 point target. It uses the same
surface spring as the external pill: response `0.24`, damping `0.90` to open;
response `0.20`, damping `1.0` to close. Do not add a separate hardware-notch
animation or replace the mounted surface during this transition. Width and
height must use this one `isExpanded` transaction. Do not attach a second
animation to `surfaceHeight`; it makes the surface look like two screens.

During built-in hover, only the brand mark remains in the top camera row and it
moves from the camera edge to the left surface edge. Session and overflow chips
hide. A centered 30 point quote row appears below the physical camera gap. Text
must not cross the camera area. The compact chips and quote stay mounted during
both directions. Opacity stages their swap so collapse never creates compact
content in one frame while the expanded quote still exists in another.

## Left recent-app shelf

The recent-app shelf is separate from the top notch. It attaches to the left
edge and stays centered on the screen's vertical axis. It shows only the three
most recently active regular applications. Hover expands the same surface to
the right and reveals names. It never moves toward the top or bottom edge.

A click activates the selected application without `activateAllWindows`. This
keeps its last active window and its selected browser tab. The shelf listens to
launch, activation, termination, and display-change events. Its hover transition
uses one spring: response `0.22`, damping `0.90`.

The collapsed icons use their own centered 44 by 46 point layout. They do not
inherit the expanded row padding. In the expanded state, hovering Chrome shows
up to three local tab targets. Each target uses the Chrome tab title and the
favicon from Chrome's local profile cache. A missing cached favicon uses the
system globe. A tab click selects the exact Chrome window ID and tab index. No
tab title, URL, or icon leaves the Mac.

The source installer uses a stable Apple Development signing identity when the
Mac has one. This keeps the same macOS Automation identity between local builds.
It falls back to ad-hoc signing on Macs without a development identity.

## Surface and detail motion

- Hover entry: start the surface spring on the first pointer event; no dwell.
- Hover exit grace: `60 ms`, then start the collapse spring.
- Expand: spring response `0.24`, damping `0.90`.
- Collapse: spring response `0.20`, damping `1.0`.
- Detail insertion: opacity `100 ms`, delayed by `40 ms`.
- Detail removal: opacity `50 ms`.
- Session-set updates: spring response `0.28`, damping `0.88`.

Reduce Motion makes the header content swap immediate. It keeps the detail
transition to opacity only.

## Release checks

Before release:

1. Run the two Core motion contract tests.
2. Capture rest, `40 ms`, `80 ms`, and settled hover frames.
3. Confirm that the `80 ms` frame has no chip/quote overlap.
4. Confirm that every session still exists in the normal session list.
5. Confirm that the logo, separator, and background do not remount or jump.
