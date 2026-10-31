# Moderating your server

You run the server, so you are the moderator. Players can report a callsign, a clan or a clan chat
message from inside the game; you read the reports and act on them from a terminal on the machine
that runs the server. There is no admin website, so there is nothing to log in to and nothing for
anyone else to find.

All commands start with the server program and the word `admin`. Use the same data folder the
server uses (the one with `outbreak.db` in it). If you followed `server/README.md`, that is
`/opt/outbreak/data`:

    cd /opt/outbreak
    ./outbreak-server admin --data /opt/outbreak/data reports

You can run these while the server is running. Nothing needs restarting; changes take effect at once.

## A normal check, once a day

1. **See what was reported.**

       ./outbreak-server admin --data /opt/outbreak/data reports

   The first table has one line per target (a player, a clan, or a chat message) with how many people
   reported it and why. The second table lists each report: its number, when, who it was about,
   the reason, who sent it and their note. For a chat message it also shows the message number and
   what was said (kept even if the message is later deleted).

2. **Look at the person** if you need more:

       ./outbreak-server admin --data /opt/outbreak/data player Rowdy

   This shows how old the account is, their clan, how many reports there are about them and by them,
   and whether they are suspended. It never shows where anyone is or who they fought. Nobody's
   position is stored, and fights stay anonymous.

3. **Act, or dismiss.**

| Problem | Command |
|---|---|
| Offensive callsign | `rename Rowdy` — the callsign becomes `Survivor1234` and the player is asked to pick a new one the next time the app opens (at once if it is open). They keep everything they earned. |
| Offensive clan name or tag | `clan-rename TAG` — the clan becomes `Clan 123` with the tag `C123`. |
| Abusive chat message | `delete-message 57` — use the message number from `reports`. |
| Cheating, or repeated abuse | `ban Rowdy --days 7 --reason "Harassing clan members."` — leave out `--days` to ban for good. |
| Banned by mistake, or time served early | `unban Rowdy` |
| Nothing wrong | `resolve 12` — closes that one report. |

The four action commands also close every open report about the same person, clan or message, so the
list stays short. Callsigns are not case sensitive.

## Fake GPS

`player Rowdy` has a line "Fake GPS": how many sessions the phone reported a simulated location
(Android mock provider, iOS software-simulated fix), and when last. It never shows a position. While
a phone reports that, the server already keeps the player out of real-world fights, war points and
walking XP, and does not offer their build as an Echo, so nothing needs doing for a single session.
The player sees a calm notice saying so. Treat a high count as a reason to look, not as proof: some
phones flag a fix wrongly, and a modified app can leave the flag out. If you are sure, `ban`.

## Crash reports

The app sends anonymous error reports (no account, no position) so you can see what breaks on real
phones:

    ./outbreak-server admin --data /opt/outbreak/data errors
    ./outbreak-server admin --data /opt/outbreak/data errors --since 7d

One line per kind of fault, biggest first: how many times, when last, which app versions and
platforms, the message and the top line of the stack. The table keeps the newest 5000 reports.
`errors clear` deletes them all (for instance after you ship a fix).

## Asking old apps to update

Start the server with `--min-client 0.2.0` (and `--store-android` / `--store-ios` links) and any app
older than that shows "Update to keep playing" instead of the game. Change it by restarting the
server. Only raise it once the new build is available in the stores; players keep their characters.

## What a suspended player sees

Their app shows a plain screen with your reason and the date the suspension ends (or that it has no
end date). Every request from their phone is refused, so they cannot play, chat or see boards. Their
build is no longer offered to other players as an Echo and they disappear from the leaderboards. When
a timed ban ends it stops by itself; `unban` ends it sooner. They can press "Check again" on the screen.

The reason is read by the player, so keep it short and civil. A suspended account keeps its
progress; nothing is deleted.

## Things worth knowing

- **Names are checked when they are made.** A short list of slurs and obvious obscenities (with
  look-alike spellings such as `Sh1t`) is refused when someone picks a callsign or founds a clan, with
  a message asking for another name. It is deliberately small so ordinary names such as "Scunthorpe"
  pass. The list is `server/src/names.zig`; changing it needs a rebuild. Names that slip through
  arrive as reports.
- **Reports are limited.** Each player may send five an hour, and only one open report per target, so
  the list stays readable.
- **Players can hide a reported player's chat** on their own phone. That is separate from anything you do.
- **Someone you ban can still start a new guest account.** The game has no way to recognise a person,
  by design: it does not store positions or devices. If a person keeps coming back, banning each
  account as it is reported is the tool you have.
- **A suspended player can still delete their account** from the suspension screen. Everything else
  is refused.
- **Back up first** if you are unsure: see "Backup" in `server/README.md`. Every command here changes
  only the player, clan, message or report you name.

## If a command says something is wrong

The commands answer in a sentence and stop, for example "No player with the callsign ...". Check the
spelling against the `reports` table. "No database at ..." means `--data` points at the wrong
folder; use the one that contains `outbreak.db`. Run `./outbreak-server admin help` for the list of commands.
