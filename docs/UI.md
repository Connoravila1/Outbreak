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
  caches, distance), the feed (recent events), the Store, the Field manual (Humans) / "what the blood knows" (Zombies)
  and Settings (server URL, sound,
  haptics, reduced motion) and Account (linked sign-ins, Link Google/Apple, Sign out, Delete account;
  guests see a dismissible "link an account" reminder at the top of the tab).

## Key moments

1. **Cold open → the bite → the choosing** (first launch only):
   - Black screen. An emergency broadcast types out, then stops. Location permission is asked here,
     framed by need: "Outbreak uses your location to build the world around you. It's never shown
     to other players." A quiet "Already playing? Sign in" link on the very first screen goes to a
     sign-in sheet; if the account already has a character it is restored and onboarding is skipped.
   - **The checkpoint** (the very first screens, before the broadcast, so the cold open runs unbroken; neutral lens): "Your papers."
     asks month and year of birth, without saying what the cutoff is. Under 13 sees a kind refusal
     ("Come back when you are older"), the screen stays shut for a day on that phone, and nothing is
     sent anywhere. Then "House rules": three plain lines, links to the Terms and the Privacy policy,
     and a checkbox with an explicit Accept. Then the broadcast, and after it the safety notice, a hazard-taped card with five
     numbered lines (traffic, private property, never driving or cycling, after dark, sanctuaries) and
     one "I understand". A phone that signs in to an existing account sees the notice once before its
     first map. **Play safe** in Settings reads it again in the player's lens; every third launch the
     boot screen carries one line of it. The re-accept sheet (a changed or missing terms version) is
     a bottom sheet with Accept and "Not now".
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
2b. **In transit**: when the server says the player is moving faster than walking pace, a calm banner
   under the top bar reads "Moving fast. Fights wait until you're on foot." (Heat: "too fast. the hunt
   waits for your feet."), and Engage, Open, Claim and Attack are disabled with the same reason.
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
8. **First-time explainers.** Reaching a level that unlocks something queues a bottom card (the unlock's
   name, 2-3 short sentences, one button to go there, "Got it"), shown over the map or any tab, never over
   a fight, a level-up or a note. After a button sends the player somewhere, the rest of the queue waits until
   they change tab. The You tab keeps a Field manual (Survey) / "what the blood knows" (Heat): unlocked entries
   re-open their card, locked ones read "Level N". Seen-state is local (`outbreak.guide`).

**Marker layers.** Map markers stack bottom to top: landmarks, caches and airdrops, enemies/echoes/raids/strongholds,
the First Blood target, the selected marker. Landmark labels also give way to any other marker's body.

## Rules

- Every control looks tappable and every selection looks selected. A disabled control says why.
- Numbers come from the server; names come from `/api/catalog`.
- Motion reinforces state changes (HP drain, XP fill, loot flip). `prefers-reduced-motion` turns
  off ambient motion, shake, and breathing.
- Honest empty states: "Nothing within 400 m. Walk a block and it changes every 10 minutes."
- Icons: game-icons.net via `@iconify-json/game-icons` (CC BY 3.0, attributed), one consistent set.

## Accessibility

What the client supports, and where it lives.

**Text size.** You tab > Settings > Text size: Default, Large (x1.15), Larger (x1.3), Largest (x1.5), stored on
the device and kept across sign-out. The `--fs-*` tokens are `calc(Npx * var(--ts))`; display sizes (28 px and up)
scale at half the rate (`--tsd`) so headings keep fitting; every other text size in CSS is written the same way.
`--top-clear` grows with the scale so panels, banners and toasts sit below the top bar and its time stamp, and the
top bar gets a solid backing over scrolling tabs. Controls wrap instead of clipping (segmented controls go to a second
row, Store and clan rows drop the button under the text, the split-lens details fold away once a side is chosen).
It was checked at 360 x 780 at Largest in both lenses: map HUD, top bar, tab bar, vitals, fight and result, level-up,
loot, Store, Gear, Tasks, War boards, clan, notes, collection log, field manual and onboarding.
*System font scale.* Android: `MainActivity` sets the WebView text zoom to the system font scale (capped at 200%), so
the whole page follows Settings > Display > Font size; Capacitor's WebView does not do this by itself. iOS: the page
measures `font: -apple-system-body` (Dynamic Type) and feeds `--ts-sys`. The Text size setting stacks on top of either.

**Screen readers.** Icon-only buttons have names in the viewer's lens voice (map "Center on me" / "find me", Nearby,
close note). Sheets and the fight/level-up layers are `role="dialog"` `aria-modal`, labelled, move focus in when
they open, keep Tab inside, return focus on close, and close with Escape or the Android back button (one overlay at
a time, topmost first). The tab bar is a real tablist: arrow keys, Home and End, one tab stop, `aria-controls`.
Toasts and the fight read out through polite live regions: one short sentence per blow ("Round 3. Brute hits you,
28.") and a one-line result summary, not every number on screen. Level-up announces itself.

**Nearby.** The map HUD's Nearby button opens a sheet listing everything on the map (threats, supplies, places),
nearest first, with distance and compass direction, threat word, and an in-range mark. Choosing a row opens the same
object sheet a marker tap does (Engage, Open, Claim), so the map is fully playable without seeing or touching it.

**Choosing a side.** Hold-to-commit is kept. A tap instead of a hold (which is what a screen reader sends) reveals
"Cannot hold? Confirm another way" and moves focus to it: a button, then "Are you sure?" with Yes and Go back. It stays
hidden until then so the ceremony is not diluted for everyone else. Both sides' copy is readable as one named control each.

**Contrast.** Body and secondary text meet WCAG AA (4.5:1) in all three lenses; large text and UI borders 3:1.
Fixes, measured on the lens surface (Survey paper `#DCDDD5`):

| Token | Before | After |
| --- | --- | --- |
| Survey `--text-dim` (62% ink) | 4.00 (3.33 on paper-2) | 76% ink: 5.9 (4.98 on paper-2) |
| Survey grease red as text | 3.90 | `#A8261F`: 5.18 |
| Survey blue as text (`--blue-ink`) | 3.96 | `#2D5880`: 5.44 |
| Survey "dangerous" amber | 3.12 | `#86480F`: 5.21 |
| Heat "even" threat (`--t-even`) | 3.69 | `#E5485A`: 4.87 |
| Heat rare label | 4.46 | `#5A98E6`: 6.36 |
| Neutral danger / rare | 4.11 / 4.27 | `#F0554F` 5.28 / `#4C8EE0` |

Heat's body (14.3:1) and secondary text (5.2:1) already passed and are unchanged.

**Motion.** The Reduce motion setting (default: the system setting) removes the screen shake, lunges, breathing, flashing
and slow-motion beats in fights, ends ambient loops, and shortens the level-up reveal pauses.


**World events (DESIGN.md section 18).** No new visual language: the map banner is a bordered strip like the other map banners (square
and ruled in Survey, rounded with a heat glow in Heat) with the kit's progress bar; the War tab's Events card, the "Upcoming" list and
the Event Exchange rows reuse `card`, `store-row` and `Action`. Event names, blurbs and goal units come from `/api/catalog` and are
read in the player's voice (`say`). Four more portrait frames (Tally Marks / Claw Marks, Static / Afterimage, Quarantine Seal /
Open Wound, Gilt) are drawn in `avatar/Frame.tsx` with the two lens inks in `frame.css`. A start alert is scheduled for each of the next
four events through the same local-notification code as the daily reset.
