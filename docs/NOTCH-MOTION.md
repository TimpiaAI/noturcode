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

## Surface and detail motion

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
