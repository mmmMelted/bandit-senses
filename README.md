# Bandit Senses

**Smarter, more human AI for Road to Vostok.** Inspired by SAIN (the Tarkov AI mod): bots notice you gradually, hear
you, remember where you were, and fight with personalities instead of a dice roll.

- **Vision:** awareness builds over time instead of instant line-of-sight. Distance, angle, your stance and movement,
  night, fog, your flashlight, partial cover and the bot's alertness all matter. At night the dark hides you more the
  farther away you are.
- **Hearing:** footsteps, landings, gunshots, reloads, using items and crafting are sounds with ranges by action and
  surface. Walls muffle them. Bots investigate roughly where the noise came from instead of knowing exactly where
  you are.
- **Decisions:** the vanilla random combat choice is replaced by scoring (health, distance, cover, squad, morale),
  weighted by a per-bot personality: Normal, Rat, Timid, Rusher, Berserker.
- **Memory:** bots remember where you were and which way you were moving, aim where you should be, and keep updating
  that guess from your footsteps.
- **Squads:** bots share contacts, flank, suppress and call out (using the game's own voice lines).
- **Firepower and reflexes:** a reaction delay before the first shot, accuracy that tightens while you stay in sight,
  flinching when hit, suppressive fire at your last position, deliberate single shots at long range.
- **Morale:** hits, near misses and squadmates dying wear bots down; broken bots fall back or flee, and hurt bots heal
  behind cover if they carry meds.
- **Grenades, dynamic cover, scavenging:** bots flush you out of known hiding spots, find cover from nearby geometry,
  and loot houses and bodies when calm. Rats sneak into houses and camp them.
- Applies to Bandits, Guards and Military (Nomads use it against their enemies). Bosses stay vanilla.
- **F9** toggles a debug overlay above each bot (state, health, awareness, personality, last decision).

## Download

Get `BanditSenses.vmz` from the [Releases](https://github.com/mmmMelted/bandit-senses/releases) page (or build it
yourself with `python build.py`).

## Requirements

- Road to Vostok Build 2 ("Nomads", v0.2.0.0).
- [Metro Mod Loader](https://github.com/ametrocavich/vostok-mod-loader) v3.4.1 or newer.

## Install

Drop `BanditSenses.vmz` into `Road to Vostok/mods/` and check it in the loader window.
To uninstall, delete the file (or uncheck it).

## Compatibility

Single player. Safe for existing saves.

- **Replaces AI behaviour**, so it conflicts with other AI overhauls (AI System Overhaul, Improvised AI Tweaker,
  Simple Engagement and similar). Use one.
- Works with my other mods: [AI Actually Loots](https://github.com/mmmMelted/ai-actually-loots) (if installed,
  Bandit Senses hands looting to it), [Invisible Backpack Fix](https://github.com/mmmMelted/invisible-backpack-fix)
  and [Shot Indicator](https://github.com/mmmMelted/shot-indicator).

## Troubleshooting

The game log (`%APPDATA%\Road to Vostok\logs\godot.log`) should show `[BanditSenses] v0.17.1 loaded`.

## Credits

- Mod by **mmmMelted** ([github.com/mmmMelted](https://github.com/mmmMelted)).
- Behaviour design inspired by [SAIN](https://github.com/Solarint/SAIN) by Solarint. This is a clean-room
  reimplementation in GDScript; no SAIN code is used.
- Built on [Metro Mod Loader](https://github.com/ametrocavich/vostok-mod-loader) by ametrocavich (RTVModLib hooks).
- Made with AI assistance: designed and written with Claude Code (Anthropic, Claude Opus 5.5), tested by mmmMelted.
- No game files or assets are included.

## License

MIT, see `LICENSE`.
