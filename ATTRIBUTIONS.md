# Attributions

Everything in this project that someone else made, what it is licensed under, and where it came
from. **This file is not a courtesy.** The OFL and CC BY both require the notice to travel with the
work, so a licence we cannot prove we honoured is a licence we have broken.

**If you add an asset, you add a row here in the same commit.** An asset whose provenance is only
in someone's memory is an asset we will one day have to delete.

---

## Code

| | |
|---|---|
| **stb_truetype** v1.26 | `vendor/stb_truetype.h` |
| Author | Sean Barrett |
| Licence | **Public domain** (Unlicense), per the dual-licence block at the foot of the header |
| Why it is here | Parses TrueType outlines to an anti-aliased coverage bitmap. The written justification for taking it as a dependency at all is at the import site, in `vendor/stb_impl.c` (F1, F6). |

---

## Fonts

Both are **SIL Open Font License 1.1**. The OFL requires the copyright notice and licence to be
distributed with the font, which is why the licence files sit next to the `.ttf`s rather than being
linked from here.

| | |
|---|---|
| **Inter** (Regular) | `assets/fonts/Inter-Regular.ttf` |
| Copyright | © 2016 The Inter Project Authors — https://github.com/rsms/inter |
| Licence | SIL OFL 1.1 — `assets/fonts/Inter-OFL.txt` |
| Used for | **Body prose.** The sentences the player actually reads. |

| | |
|---|---|
| **Oxanium** (SemiBold, Bold, ExtraBold) | `assets/fonts/Oxanium-*.ttf` |
| Copyright | © 2019 The Oxanium Project Authors — https://github.com/sevmeyer/oxanium |
| Licence | SIL OFL 1.1 — `assets/fonts/Oxanium-OFL.txt` |
| Used for | **Labels, headings, and the alarm.** The chrome, and the things the game shouts. |

> A note worth keeping, because it nearly bit us. The prior art these were ported from carried
> comments claiming it embedded IBM Plex Sans; its build file embedded Inter. Ported carelessly,
> this repository would have shipped a false attribution for a font it does not contain.
> **Verify what is embedded, not what a comment says is embedded.**

---

## Audio

| | |
|---|---|
| **Piano Zombie** | `assets/audio/piano-zombie.mp3` |
| Source | https://www.youtube.com/watch?v=JkDIMhhSpR4 |
| Licence | **Creative Commons Attribution 4.0 International (CC BY 4.0)** — https://creativecommons.org/licenses/by/4.0/deed.en |
| Used for | Ambient background music. **Not yet wired in** — the file is in the tree, nothing plays it. |

**CC BY 4.0 obliges us to credit the creator, link the licence, and state whether we changed the
work.** That credit has to be somewhere a player can actually reach — this file is where the
obligation is recorded, but it is not yet discharged in the app itself.

**Owed, before any build that plays this ships:**

- [ ] The creator's name, as they wish to be credited. The row above has a URL and no name, and a
      URL is not a credit.
- [ ] A credits screen, or a line in the app, carrying that name and a link to the licence.
- [ ] A statement of whether the audio was modified (trimmed, looped, re-encoded — a loop is a
      modification).
