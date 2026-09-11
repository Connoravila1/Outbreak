# Attributions

Everything in this project that someone else made, what it is licensed under, and where it came
from. **This file is not a courtesy.** The OFL and CC BY both require the notice to travel with the
work, so a licence we cannot prove we honoured is a licence we have broken.

**If you add an asset, you add a row here in the same commit.** An asset whose provenance is only
in someone's memory is an asset we will one day have to delete.

---

## Code

No third-party code ships in the project today. (stb_truetype was removed with the GLES
renderer when presentation moved to DVUI; DVUI itself lands as a vendored dependency with its
own row here when it does.)

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
| **Creator** | **Tim Beek** — https://timbeek.com/ |
| Source | https://www.youtube.com/watch?v=JkDIMhhSpR4 |
| Licence | **Creative Commons Attribution 4.0 International (CC BY 4.0)** — https://creativecommons.org/licenses/by/4.0/deed.en |
| Modified? | **Not yet.** The file is byte-identical to the download. If we ever trim it, loop it, or re-encode it, that is a modification and this row must say so. |
| Used for | Ambient background music. **Not yet wired in** — the file is in the tree, nothing plays it. |

**CC BY 4.0 obliges us to credit the creator, link the licence, and state whether we changed the
work.** The first is recorded above. The second and third are recorded above. **None of the three
are discharged in the app itself, because the app does not yet play the track.**

The credit has to be somewhere a player can actually reach. A line in a repository file is not
that — it is where we keep our own books.

**Owed, before any build that plays this ships:**

- [ ] A credits screen, or a line in the app, carrying **Tim Beek**, a link to https://timbeek.com/,
      and a link to the CC BY 4.0 licence.
- [ ] If the track is trimmed, looped or re-encoded by then — and looping it almost certainly means
      trimming it — the **Modified?** row above changes to yes, and the app must say so too.

The attribution is the *price* of the music, not a nicety attached to it. If we cannot put a credit
on a screen, we do not get to use the track.
