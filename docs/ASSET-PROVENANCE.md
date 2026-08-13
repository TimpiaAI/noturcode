# Asset provenance

Noturcode is published with provenance for every bundled visual and audio asset.

## Application mark

The current app icon is derived from a GPT Image concept generated specifically for Noturcode, then flattened and alpha-extracted locally. The source trail is recorded in [`Resources/LOGO-SOURCES.md`](../Resources/LOGO-SOURCES.md).

Provider marks identify third-party coding harnesses and remain the property of their owners. See [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

## Notification sounds

The WAV files under `Resources/Assets.xcassets/Noturcode*.dataset/` are original tones synthesized for this repository. They contain no external samples.

| Cue | Synthesis |
| --- | --- |
| Connect | 520 Hz sine, 0.22 s |
| Send | 760 Hz sine, 0.14 s |
| Open | 620 Hz sine, 0.18 s |
| Close | 420 Hz sine, 0.20 s |
| Done | 660 Hz then 880 Hz, 0.31 s |
| Asking | 740 Hz then 930 Hz, 0.39 s |
| Failed | 310 Hz then 220 Hz, 0.40 s |

Each file is mono PCM at 48 kHz. Fade envelopes and conservative volume are applied during generation to avoid clicks and clipping.
