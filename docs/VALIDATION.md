# Validation record

This record distinguishes the original local workaround from the portable package distributed here. A successful installer or compiler run is not a gameplay test.

| Check | Result | Scope |
| --- | --- | --- |
| Original local workaround: load a save with RT on / PT off | Confirmed by the tester on 2026-10-14 | Playable gameplay on one M5 Mac; duration not measured |
| Original local workaround: startup traces | Passed | Two bounded startup traces and observed frame presentation |
| Confirmed launch pipeline log | 66 normal RT compilations; seven SHARC substitutions; no subsequent pipeline failures | No substitute dispatches observed by the installed monitor; not a complete GPU capture |
| Portable source compilation | Passed | x86_64 build against Foundation and Metal with compiler warnings treated as errors |
| Portable normal GPU dispatch | Passed | An ordinary compute pipeline executed and wrote the expected value, 42 |
| Portable installer fixtures | Passed | Install/remove round trip, no-change dry runs, paths containing spaces, preservation of later preferences, rejection of PT-on and unknown executables |
| Portable build: load a save and play with RT on / PT off | Not performed | Gameplay confirmation applies to the original local edition |
| Gameplay video | Not published | No footage is bundled or represented as captured evidence |

## Tested configuration

Apple M5 with 16 GB RAM; macOS 27.2 build 26B5101f; Sikarugir wrapper 1.0.11; Wine 10.0; D3DMetal 4.0b2; Windows Steam; Witcher 3 Remastered 5.01 / executable 5.0.0.1048522 with the separately credited RT-only toggle unlock and startup proxy.

## Report a reproduction

Open an issue with your Mac chip and RAM, macOS version, wrapper/Wine version, D3DMetal version, game version, whether RT/PT were on, and whether a save reached playable gameplay. Include the relevant lines from `Witcher3RTCompatPublic.log`, after removing personal paths.

A short video can show the RT/PT settings and the same session running a loaded save. It supports a reproduction report; it does not establish compatibility with other setups or long-duration stability.
