# Outbreak — Interface Design

## The idea: your side is how you see the world

Picking a faction decides how you see your own city, every time you open the game.

- **Humans see the Survey**: your streets as a survivor's marked-up municipal map. Two-ink print on
  grey map paper, roads in survey brown, water in survey blue, grease-pencil circles around
  threats, and hazard-tape and embossed label-tape (Dymo-style) chrome. It reads as practical,
  human, something written by hand by someone who means to live.
- **Zombies see the Heat**: your streets as thermal sense. A dark, blood-warm void with roads as
  faint warm veins. Living things show as heat blooms in crimson, orange and white-hot. Text is
  lowercase and sensory. It reads as predatory, hungry, alive in the wrong way.

Same layout and controls for both. Different paint, different voice, different map.

The **signature moment** is the choosing. Your real neighbourhood is shown split down the middle,
Survey on one side and Heat on the other, with a draggable seam. You literally choose how you will
see your city forever. Committing burns the other half away.

## Tokens

Defined as CSS custom properties on `:root[data-lens="survey"|"heat"|"neutral"]`. Components only
use tokens, never raw colours.

### Neutral (before the choice: the broadcast)
| Token | Hex | Use |
|---|---|---|
| `--bg` | `#0B0C0E` | Night |
| `--fg` | `#EEF0F0` | Text |
| `--muted` | `#7C8288` | Secondary text |
| `--alert` | `#E2342D` | Emergency red, used sparingly |

### Survey (Human)
| Token | Hex | Use |
|---|---|---|
| `--paper` | `#DCDDD5` | Map paper and sheets |
| `--paper-2` | `#C9CBC1` | Recessed surfaces, building fill |
| `--ink` | `#1F2326` | Text, strong lines |
| `--survey-brown` | `#8A5A3C` | Roads |
| `--survey-blue` | `#3B6E99` | Water, the "you" marker, info |
| `--grease` | `#C8312B` | Threats, enemy circles, damage |
| `--hazard` | `#F2BE1A` | Faction accent: tape, primary buttons, XP |
| `--tape` | `#16181A` | Label-tape background (white embossed text) |

### Heat (Zombie)
| Token | Hex | Use |
|---|---|---|
| `--void` | `#120809` | Background and map base |
| `--cold` | `#2E1215` | Buildings, recessed surfaces, cold areas |
| `--vein` | `#6B1A22` | Roads |
| `--warm` | `#D12A3A` | Heat level 1, accents |
| `--hot` | `#FF6B2C` | Heat level 2: prey, primary buttons, XP |
| `--white-hot` | `#FFF0C2` | Heat level 3: elite, text highlights |
| `--flesh` | `#EDDDD6` | Body text |

### Shared
Rarity: Common `#A3A8AE` · Uncommon `#3FA34D` · Rare `#2F7BD9` · Legendary `#E8A317`. Rarity is
always shown with a label and a border treatment, never colour alone. HP uses the lens's `--grease`
or `--hot`; XP uses `--hazard` or `--hot`.

### Type (bundled via @fontsource, all OFL)
- **Display: Big Shoulders Display** (700–900). Condensed civic signage, the voice of headings,
  level numbers and CONTACT. Used with restraint.
- **Body: Barlow** (400/500/600). Clear at small sizes outdoors. Tabular numbers for stats.
- **Hand: Permanent Marker**. Survey only: grease-pencil annotations on the map ("3 walkers",
  "crate"), loot callouts, the occasional scrawl. Never for anything you have to read quickly.
- Heat has no hand face. Its voice is Barlow lowercase with wide tracking, plus a subtle wavering
  "breathing" animation on display text (reduced-motion: off).

Scale: 12 / 14 / 16 / 20 / 28 / 40 / 64. Minimum tap target 48 px. Body text 16 px.

### Voice
- **Survey**: terse field notes, sentence case, practical. "Walker, level 6. Close enough to
  engage." "You held. Took 31 damage."
- **Heat**: lowercase, sensory, short. "something warm. close." "fed. 31 wounds."
- Buttons are plain verbs in both: Engage, Open, Equip, Scrap, Upgrade, Use, Claim.

## Structure

Mobile portrait first. Desktop shows the same app in a centred phone-width column with the GPS
simulator panel beside it.

```
┌────────────────────────────┐
│ ◎12  CALLSIGN   ░HOSTILES░ │  top: level ring + callsign + title; hostile tape when active
│                            │
│          the map           │  full-bleed; you, enemies, caches, echoes, strongholds, raids
│      ( ) your 50 m ring    │
│                            │
│                 [◉ center] │
├────────────────────────────┤
│ HP ███████████░░  84 / 120 │  vitals strip: HP, XP sliver, buffs, downed timer
├────────────────────────────┤
│  Map  Gear  Tasks  War  You│  tab bar: icon + label
└────────────────────────────┘
```

- **Map**: tap a marker to open a bottom sheet: what it is, level, a threat read vs you
  (easy / even / dangerous / deadly, coloured), distance state ("in range" / "move closer"), and a
  primary action (Engage / Open). Out of range, the action is disabled with the reason.
- **Landmarks**: real places the phone reported. Survey draws a stamped municipal symbol with the
  real name in marker script ("WALGREENS - PHARMACY"); Heat a warm smear with the lowercase kind
  ("sick ward"). The sheet shows name, kind, what it tends to hold and Open, or "Restocks in 2 h 10 min".
- **Stance**: enemy, echo and raid sheets get a three-way control above Engage (Aggressive /
  Careful / Evasive; frenzy / stalk / slink for Zombies) with its numbers, the last choice remembered
  and a one-line hint after three fights against that archetype. The fight header shows the stance.
- **Time**: a small sun/moon stamp under the top bar ("Night: they're stronger" / "night. we're
  hungrier."); at night Heat gains contrast and Survey a darker paper.
- **Gear**: three slot cards at top (tap to see the item; long text in a sheet). Below them the
  inventory grid, filterable by slot and sortable by power or rarity. Item sheet: stats with a
  delta against equipped (▲▼), perks, Equip, Upgrade (cost), Scrap (value). Multi-select scrap
  mode. Consumables row with Use. Abilities section: unlocked abilities and slots.
- **Tasks**: daily missions with progress bars, a reset countdown, the streak, the weekly mission,
  and Claim buttons.
- **War**: global faction bar, district bar, week countdown, top players this week, a leaderboard
  toggle (weekly / level), and Clan (L10+: create, join or your clan page with roster and chat).
- **You**: big level and title, XP to next, stat block, record (wins, losses, contacts, echoes,
  caches, distance), the feed (recent events), the Store, and Settings (server URL, sound,
  haptics, reduced motion) and Account (linked sign-ins, Link Google/Apple, Sign out, Delete account;
  guests see a dismissible "link an account" reminder at the top of the tab).

## Key moments

1. **Cold open → the bite → the choosing** (first launch only):
   - Black screen. An emergency broadcast types out, then stops. Location permission is asked here,
     framed by need: "Outbreak uses your location to build the world around you. It's never shown
     to other players." A quiet "Already playing? Sign in" link on the very first screen goes to a
     sign-in sheet; if the account already has a character it is restored and onboarding is skipped.
   - "You've been bitten." Heartbeat audio and haptics, and veins creep in from the edges.
   - The split lens over your real streets, from the live map. The left side is labelled
     "Fight it. Stay human." and the right side "Let it in." Each side lists three plain lines
     about how that side plays, and the live faction share with any underdog bonus. Drag the seam
     or tap a side to lean into it.
   - "This is permanent." Hold to commit (3 s) with the heartbeat rising, then either the flatline
     averted (Survey) or flatline into eyes opening (Heat). The other lens burns away.
   - "Save your survivor" (lens voice): Continue with Apple / Continue with Google in each
     provider's official button style (Apple first on iOS, Google first on Android, both on web),
     and a small "Play as guest" link. Signing in to an account that already has a character asks
     "Switch to the existing character?" first.
   - Callsign ("What do they call you?"), then your first kit is handed over item by item.
   - A 3-card briefing in the faction voice: walk to find things, tap to fight, enemies find you.
2. **Engage → fight → result**: a full-screen fight. Your card at the bottom, theirs at the top,
   HP bars that drain with a lag trail, and damage numbers. Abilities slap on as label tape
   (Survey) or flare as heat (Heat). Crits shake the screen. It's skippable. The result is a card
   stack: outcome, XP bar fill, and loot cards flipped one by one with a rarity glow (Legendary
   gets a held beat).
3. **CONTACT**: interrupts anything. Full-screen alert, a strong haptic pattern, "A Zombie is
   close. Level 14." Its gear names appear, then the fight plays automatically.
4. **Level up**: a full-screen takeover with the new number, then the unlocks, named one per line.
5. **A found note** (docs/LORE.md): after the gear, the result stack adds a torn scrap with the
   note's title. Survey: paper with a strip of tape. Heat: a smeared, warm fragment. Tap it and a
   full-screen reader opens, drawn on the paper of the note's form (ruled notebook, memo, email,
   phone bubbles, receipt, sticky notes, radio log, poster, handwritten letter, review, index
   card; handwriting in marker). The Heat lens warms and glows the paper but keeps the ink dark.
   A note found outside a fight (cache, landmark, raid event) shows in the reward list and in a
   toast that opens the reader. The **Archive** in the You tab lists sets with progress, finds as
   rows, the rest as `???` silhouettes with their rarity, and a Claim button on a finished set (its
   title joins the profile). Unread notes carry a red dot, also on the You tab.

## Rules

- Every control looks tappable and every selection looks selected. A disabled control says why.
- Numbers come from the server; names come from `/api/catalog`.
- Motion reinforces state changes (HP drain, XP fill, loot flip). `prefers-reduced-motion` turns
  off ambient motion, shake, and breathing.
- Honest empty states: "Nothing within 400 m. Walk a block and it changes every 10 minutes."
- Icons: game-icons.net via `@iconify-json/game-icons` (CC BY 3.0, attributed), one consistent set.
