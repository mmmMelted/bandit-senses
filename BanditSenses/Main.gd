extends Node
## Bandit Senses: SAIN-inspired perception for Road to Vostok bandits.
## Clean-room reimplementation of SAIN's ideas (gradual spotting, sound events, investigating).
## No SAIN code is used.
##
## - Vision: awareness builds over time instead of instant LOS. Distance, angle off-center,
##   player stance/movement, night/fog/flashlight, partial cover and alertness all matter.
## - Hearing: footsteps, landings and gunshots are sound events with ranges by action and surface.
##   Walls damp them. Bots investigate the rough position instead of knowing exactly where you are.
## - Decisions: the vanilla dice-roll Decision() is replaced by utility scoring (Brain.gd) weighted by
##   a per-bot personality (Normal, Rat, Timid, Rusher, Berserker). Bots remember where they last saw you,
##   keep aiming there from cover, and sprint when pushing.
## - Noisy actions (reload, ammo check, using items, magazines, crafting) are heard nearby and mark the player
##   as vulnerable for the action's duration, which makes bots push hard.
## - Pushes: sprinting bots never fire; near the target they stop, aim and fire, then re-decide.
##   Berserkers keep charging in sight (at an aimed run, spraying) and stop ~3 m (10 ft) away to dump full auto.
## - Crouching is for sneaking only: a bot creeps crouched only while the player hasn't seen it, it isn't in a
##   firefight, and it is close to its target. Otherwise it moves upright.
## - Grenades flush a player who went out of sight at a known position (per-bot and squad cooldowns).
## - Memory: bots remember where you were and which way you were moving, aim where you should be, and keep
##   updating that guess from your footsteps.
## - Firepower: faster trigger and far more full auto than vanilla (bandits most of all), and suppressive bursts
##   at the remembered position while the player is behind cover. At range fire turns deliberate: full auto rare and
##   short past 40 m, single aimed shots only past 70 m.
## - Reflexes: a human reaction delay before the first shot, accuracy that ramps up while the target stays in sight
##   (first shots go high), flinching when hit or nearly hit, running from grenades.
## - Morale: hits, near misses and squadmates dying wear it down; below a personality threshold the bot retreats to
##   cover farther back or flees. Recovers when left alone. Hurt bots heal behind cover if they carry meds.
## - Barks: the combat voice marks callouts (contact, grenade out, grenade!, man down, falling back), rate-limited.
## - Rats go to ground: instead of wandering they sneak to a house hide point and camp it.
## - Optics by faction: rare for Bandits, common for Guards and Military.
## - Applies to Bandits, Guards and Military (Military never rolls Rat). Bosses stay vanilla.
## - F9 toggles the AI debug overlay (state, health, awareness, personality, last decision), plus Dev Tools' ESP
##   (AI tinted through walls by alert level) when Dev Tools is loaded.


const VERSION := "0.17.0"
const TAG := "[BanditSenses] "
const Brain = preload("res://BanditSenses/Brain.gd")
const Cover = preload("res://BanditSenses/Cover.gd")


var gameData = preload("res://Resources/GameData.tres")


## AIData.Faction values this mod takes over. Bosses stay vanilla. Nomads use the new AI against
## enemies but ignore the player while the game considers them friendly (Sensor.PlayerValid()).
var affectedFactions := [AIData.Faction.Bandit, AIData.Faction.Guard, AIData.Faction.Military, AIData.Faction.Nomad]
## Chance a bot carries an optic, replacing the vanilla ~6% any-attachment roll.
var opticChance := {AIData.Faction.Bandit: 0.02, AIData.Faction.Guard: 0.45, AIData.Faction.Military: 0.65, AIData.Faction.Nomad: 0.06}


const LOS_CYCLE := 0.2
const MAX_SIGHT := 150.0
const SPOT_TIME_NEAR := 0.3
const SPOT_TIME_FAR := 7.0
const AWARENESS_DECAY := 0.08
const SUSPICION := 0.45
## Night Gear (separate mod) weapon light: the beam's reach and half-angle off the bot's view center.
const NG_LIGHT_RANGE := 30.0
const NG_LIGHT_ANGLE := 20.0
const INVESTIGATE_COOLDOWN := 8.0
const INVESTIGATE_HOT := 25.0
const CALM_STATES := ["Idle", "Wander", "Loot", "Guard", "Patrol", "Group"]
const HIT_REACT_COOLDOWN := 3.0
const HIT_GUESS_ERROR := 5.0
const PUSH_SPRINT := 5.0
## A Berserker charging a target in sight runs at this speed so it fires from the aimed run animation: the movement
## blend plays Aim_Run_F at 3 but Sprint_F (weapon not aimed) at 5, and shots come from an invisible ray, not the gun.
const PUSH_RUN_FIRE := 3.0
const PUSH_STOP_VISIBLE := 15.0
const PUSH_STOP_NEAR := 6.0
const ACTION_REACT_COOLDOWN := 1.5
const RAT_HIDE_RANGE := 120.0
const COVER_SEARCH := 24.0
const COVER_CACHE_TIME := 2.0
const COVER_SEARCHES_PER_FRAME := 1
const MIN_DECISION_INTERVAL := 0.75
const PERF_INTERVAL := 60.0
## Hunting/flanking bots move upright; they creep crouched only within CREEP_RANGE of the target and only while
## sneaking (the player hasn't seen them or traded fire with them for SNEAK_FORGET seconds).
const CREEP_RANGE := 40.0
const TRAVEL_SPEED := 3.0
const SNEAK_FORGET := 20.0
const GAIT_CHECK := 0.5
## cos of the half-angle of the player's view cone used for "the player can see this bot" (~53 deg).
const PLAYER_VIEW_DOT := 0.6
## Personalities that never creep.
const NEVER_SNEAK := ["Berserker"]
## Berserkers sprint until this close (flat metres, ~10 ft), then stop and fire full auto.
const BERSERK_STOP := 3.0
const BERSERK_HOLD := Vector2(2.0, 3.5)


## Memory: last seen position + movement; aim where the player should be after up to PREDICT_TIME s.
const PREDICT_TIME := 2.5
const PREDICT_MAX := 6.0
const MEMORY_FRESH := 10.0
const AWARENESS_DECAY_HOT := 0.03
const MEMORY_SHIFT := 10.0
const MEMORY_SHIFT_COOLDOWN := 4.0
## Memory of the player is forgotten after this long without news (or when the bot cools down).
const MEMORY_MAX := 60.0
## Memory of an AI target (Nomad vs Bandit fights): kept this long after the last sighting while it stays the bot's
## target and alive. Vanilla lets LKL drift 5 m in front of the bot as soon as the target leaves sight.
const AI_MEMORY := 45.0
## Seen within this many seconds = still engaged: 360-degree tracking like vanilla, no FOV gate.
const ENGAGED_MEMORY := 5.0
## Spot-time caps so close threats are never ignored: inside SPOT_CAP_NEAR_DIST, and anywhere unless the player is
## crouched and still.
const SPOT_CAP_NEAR := 1.5
const SPOT_CAP_NEAR_DIST := 50.0
const SPOT_CAP_FAR := 3.0
## A player entering view this close starts the bot at least half-aware.
const POINT_BLANK := 20.0
## Human-like field of view: PERIPHERAL_HALF degrees each side (vanilla viewAngle 150 = 75 each side left a blind spot
## beside the bot). The far periphery is slow to notice a still target but catches movement. Inside PROXIMITY m with a
## clear line, a bot senses you from any direction.
const PERIPHERAL_HALF := 100.0
const PERIPHERAL_CAP := 2.5
const PROXIMITY := 4.0
const PROXIMITY_CAP := 0.8
## Night (no player light, bot without night vision or its own beam on you): the dark hides more the farther away you
## are, NIGHT_NEAR..NIGHT_FAR x spot time over NIGHT_RANGE m (vanilla night view distance is 50). The quick near cap
## only applies inside NIGHT_CAP_NEAR_DIST; beyond, spotting a moving player takes at most NIGHT_CAP s.
const NIGHT_NEAR := 1.5
const NIGHT_FAR := 5.0
const NIGHT_RANGE := 50.0
const NIGHT_CAP_NEAR_DIST := 12.0
const NIGHT_CAP := 6.0
## Watchdog for a reload flag left on (vanilla clears it from an animation callback).
const RELOAD_WATCHDOG := 7.0


## Firepower by faction. Bandits are untrained: fast trigger, lots of full auto, long bursts, long suppression.
## Trained factions fire controlled bursts. [full-auto chance, semi shot-gap scale, burst s, pause s, suppress memory s]
const FIRE_STYLE := {
	AIData.Faction.Bandit:   {"auto": 0.5, "gap": 0.8, "burst": Vector2(0.8, 2.2), "pause": Vector2(0.4, 1.2), "memory": 9.0, "ramp": 1.5},
	AIData.Faction.Nomad:    {"auto": 0.25, "gap": 1.0, "burst": Vector2(0.5, 1.2), "pause": Vector2(1.0, 2.5), "memory": 5.0, "ramp": 1.2},
	AIData.Faction.Guard:    {"auto": 0.3, "gap": 1.0, "burst": Vector2(0.4, 1.0), "pause": Vector2(0.8, 2.0), "memory": 6.0, "ramp": 1.2},
	AIData.Faction.Military: {"auto": 0.3, "gap": 0.9, "burst": Vector2(0.3, 0.8), "pause": Vector2(0.6, 1.6), "memory": 6.0, "ramp": 0.9},
}
## Fire discipline by range: past MID_RANGE full auto is capped at MID_AUTO_CAP chance with bursts x MID_BURST;
## past LONG_RANGE only single shots, LONG_GAP s apart (bandits sometimes snap a quick follow-up, BANDIT_FOLLOWUP).
const MID_RANGE := 40.0
const LONG_RANGE := 70.0
const MID_AUTO_CAP := 0.25
const MID_BURST := 0.5
const LONG_GAP := Vector2(0.8, 2.5)
const BANDIT_FOLLOWUP := 0.2
## Aim spread (+- metres at the target, before full auto x2 / optic) by distance, per faction: a smooth curve instead of
## vanilla's 0.1 / then 0.4-0.5 past 10 m / then 0.7-1.0 past 50 m cliffs. By 70 m it's back to vanilla's long-range
## accuracy and keeps getting worse to 150 m. Bandits sloppy, Military sharp. Roughly per aimed shot at a standing
## player in the open: 70 m Bandit 20% / Guard 30% / Military 40%, 100 m 15 / 22 / 30%, 150 m 10 / 15 / 20%.
const AIM_CURVE := {
	AIData.Faction.Bandit:   [Vector2(0, 0.08), Vector2(10, 0.15), Vector2(25, 0.4), Vector2(50, 0.55), Vector2(70, 0.99), Vector2(100, 1.14), Vector2(150, 1.4)],
	AIData.Faction.Nomad:    [Vector2(0, 0.08), Vector2(10, 0.15), Vector2(25, 0.4), Vector2(50, 0.55), Vector2(70, 0.99), Vector2(100, 1.14), Vector2(150, 1.4)],
	AIData.Faction.Guard:    [Vector2(0, 0.08), Vector2(10, 0.12), Vector2(25, 0.32), Vector2(50, 0.45), Vector2(70, 0.8), Vector2(100, 0.94), Vector2(150, 1.14)],
	AIData.Faction.Military: [Vector2(0, 0.08), Vector2(10, 0.1), Vector2(25, 0.25), Vector2(50, 0.35), Vector2(70, 0.7), Vector2(100, 0.8), Vector2(150, 1.0)],
}
## Suppressive fire at the remembered position while the player is out of sight.
const SUPFIRE_RANGE := 80.0
const SUPFIRE_SPREAD := 1.5
## Player moving toward the bot faster than this (m/s) counts as closing in.
const CLOSING_SPEED := 1.0


## Reflexes. First shot after (re)acquiring the target waits REACTION s (x1.4 when caught calm). Spread starts at
## ACC_START x and ramps to normal over the faction's "ramp" seconds of continuous sight; early shots also go up to
## HIGH_MISS m high (over the head / into the top of cover). Losing sight longer than REACQUIRE_GRACE resets it.
const REACTION := Vector2(0.2, 0.45)
const REACQUIRE_GRACE := 1.5
const ACC_START := 1.8
const HIGH_MISS := 0.4
## Flinch: hit or near miss delays the next shot and widens spread for FLINCH_SPREAD_TIME.
const FLINCH_DELAY := Vector2(0.15, 0.35)
const FLINCH_SPREAD := 1.0
const FLINCH_SPREAD_TIME := 0.6


## Morale 0..1. Below the personality's threshold the bot breaks: retreats to full cover RETREAT_GAIN m farther from the
## threat, or flees (Timid, or far below threshold). Recovers MORALE_RECOVER/s after MORALE_CALM s without stress.
const MORALE_BREAK := {"Normal": 0.3, "Rat": 0.4, "Timid": 0.5, "Rusher": 0.2, "Berserker": -1.0}
const MORALE_RECOVER := 0.03
const MORALE_CALM := 5.0
const ALLY_DEATH_RANGE := 40.0
const BREAK_TIME := 25.0
const RETREAT_GAIN := 10.0
const RETREAT_SEARCH := 40.0
const FLEE_DIST := Vector2(20.0, 32.0)


## Healing: hurt (< HEAL_BELOW), holding a position, unseen and unhurt for a while -> crouch HEAL_TIME s, +HEAL_AMOUNT.
const HEAL_BELOW := 0.6
const HEAL_TIME := 5.0
const HEAL_AMOUNT := 0.4


## Grenade evasion: bots within NADE_DANGER of a live frag that notice it (close, seen, or a squadmate yelled) run
## NADE_EVADE_DIST away after NADE_REACT s. Timid bots sometimes freeze.
const NADE_DANGER := 9.0
const NADE_NOTICE := 15.0
const NADE_EVADE_DIST := 12.0
const NADE_REACT := Vector2(0.2, 0.6)
const NADE_EVADE_TIME := 4.0
const NADE_SCAN := 0.1


## Peek cycle at a firing position (low cover): crouched (hidden, reload/heal here) PEEK_DOWN s, standing to fire
## PEEK_UP s. Suppression keeps a bot down longer.
const PEEK_DOWN := Vector2(0.6, 1.2)
const PEEK_UP := Vector2(2.0, 3.5)
## From full cover, go back to a firing position if the target was seen within this many seconds.
const REENGAGE_MEMORY := 25.0


## Search: when a hunter reaches the remembered spot and nobody is there, check SEARCH_POINTS spots around it.
const SEARCH_POINTS := 4
const SEARCH_RADIUS := 18.0
const SEARCH_SQUAD := 60.0


## Cover fire: when a bot moves (flank, push, relocate) the nearest squadmate lays down fire this long.
const COVER_FIRE_TIME := 3.5
const COVER_FIRE_RANGE := 40.0
const COVER_FIRE_MEMORY := 30.0


## Corner checks while creeping: pause CORNER_PAUSE s at path turns sharper than CORNER_ANGLE within CORNER_NEAR m.
const CORNER_ANGLE := 50.0
const CORNER_NEAR := 2.5
const CORNER_PAUSE := Vector2(0.6, 1.2)


## Scavenging: calm bots check every LOOT_CHECK s; containers within LOOT_RANGE (HOUSE_RANGE for hiders in their house),
## fresh corpses within CORPSE_RANGE; LOOT_PER_VISIT items per visit, at most LOOT_CAP items carried.
const LOOT_CHECK := Vector2(2.0, 4.0)
const LOOT_RANGE := 35.0
const HOUSE_RANGE := 15.0
const CORPSE_RANGE := 50.0
const CORPSE_FRESH := 900.0
const LOOT_PER_VISIT := Vector2i(1, 3)
const LOOT_CAP := 10
const LOOT_TASK_TIMEOUT := 45.0
const VISIT_FORGET := 600.0
const RESERVE_TIME := 40.0
## After a container, keep searching unchecked containers this close (same room/house) for SEARCH_ON_TIME s.
const SEARCH_ON := 10.0
const SEARCH_ON_TIME := 6.0
const GRAB_TIME := 0.6
const APPROACH_DIST := 0.9
## Chance per check to go looting when calm, by faction (Rats and hiders at least 0.84).
## Checks come every ~3 s while calm: Guards loot about once per 5 calm minutes, Military about once per 10.
const LOOT_WILL := {AIData.Faction.Bandit: 0.5, AIData.Faction.Guard: 0.01, AIData.Faction.Military: 0.005}


## Barks: one combat callout per faction every BARK_COOLDOWN s.
const BARK_COOLDOWN := 2.5
## Tactical tick: this many bots per physics frame (round robin) for morale, healing.
const TICK_BOTS_PER_FRAME := 2


## Grenades: thrown at the remembered position to flush the player out.
const NADE_RANGE := Vector2(8.0, 45.0)
const NADE_COOLDOWN := 25.0
const SQUAD_NADE_COOLDOWN := 10.0
const RAT_CAMP_TIME := Vector2(180.0, 420.0)
const VISIBLE_ACTION_RANGE := 40.0


## Suppression: player shots passing within SUPPRESS_RADIUS of a bot's head add to its meter.
const SUPPRESS_RADIUS := 3.0
const SUPPRESS_RANGE := 150.0
const SUPPRESS_LOUD := 0.4
const SUPPRESS_QUIET := 0.25
const SUPPRESS_SPREAD := 1.2
const SUPPRESS_REACT := 0.5


## Squad comms: allies of the same faction within range hear callouts after a short delay.
const COMMS_RANGE := 50.0
const COMMS_DELAY := Vector2(0.8, 2.0)
const COMMS_ERROR := 3.0
const SHARE_COOLDOWN := 3.0
const FLANK_TIMEOUT := 45.0


## Noisy player actions: [hearing radius m, seconds the player counts as vulnerable].
const ACTIONS := {
	"reload": [20.0, 3.0],
	"insert": [12.0, 1.5],
	"ammocheck": [8.0, 2.0],
	"use": [15.0, 4.0],
	"charge": [12.0, 2.0],
	"load": [12.0, 3.0],
	"unload": [12.0, 3.0],
	"magazine": [20.0, 3.0],
	"craft": [15.0, 4.0],
}


const STEP_RUN := 28.0
const STEP_WALK := 12.0
const STEP_CROUCH := 4.0
const STEP_LAND := 18.0
const SHOT_LOUD := 220.0
const SHOT_SUPPRESSED := 45.0
const WALL_DAMPING := 0.7
const SURFACE_LOUDNESS := {"Metal": 1.4, "Wood": 1.2, "Concrete": 1.1, "Generic": 1.0, "Dirt": 0.9, "Grass": 0.8}


var _lib = null
var _bots := {}
var _debug := false
var _lastShotTime := -100.0
var _lastShotSuppressed := false
var _coverFrame := -1
var _coverSearches := 0
var _perf := {}
var _perfTimer := 0.0
var _grenades := []
var _nadeScanT := 0.0
var _lastBark := {}
var _tickIndex := 0
var _debugT := 0.0
var _containers := []
var _corpses := []
var _builtinLoot := true



func _ready():
	print(TAG + "v" + VERSION + " loaded")
	get_tree().node_added.connect(_on_node_added)

	if Engine.has_meta("RTVModLib"):
		var lib = Engine.get_meta("RTVModLib")
		if lib._is_ready: _on_lib_ready()
		else: lib.frameworks_ready.connect(_on_lib_ready)
	else:
		push_warning(TAG + "RTVModLib not found, is Metro Mod Loader installed?")

func _on_lib_ready():
	_lib = Engine.get_meta("RTVModLib")

	if _lib.hook("sensor-prioritylos", _on_priority_los) == -1:
		push_warning(TAG + "Sensor.PriorityLOS is already replaced by another mod; disable other AI mods")
	if _lib.hook("sensor-playerheardetection", _on_player_hear_detection) == -1:
		push_warning(TAG + "Sensor.PlayerHearDetection is already replaced by another mod; disable other AI mods")

	_lib.hook("controller-playfootstep-post", _on_footstep)
	_lib.hook("controller-playfootstepland-post", _on_land)
	_lib.hook("weaponrig-playfire-post", _on_player_fire)
	_lib.hook("ai-updatestatus-post", _on_update_status)
	_lib.hook("ai-weapondamage-post", _on_ai_damaged)
	_lib.hook("ai-death-post", _on_ai_death)
	# Built-in scavenging, unless the standalone "AI Actually Loots" mod is installed (it then does the looting).
	_builtinLoot = !Engine.has_meta("AIActuallyLoots")
	if _builtinLoot:
		_lib.hook("ai-weapondamage-pre", _on_ai_damage_pre)
		if _lib.hook("ai-loot", _on_loot) == -1:
			push_warning(TAG + "AI.Loot is already replaced by another mod; looting may resume combat bots into Wander")
	else:
		print(TAG + "AI Actually Loots found: using it for looting")

	_lib.hook("ai-parameters-post", _on_parameters)

	if _lib.hook("ai-decision", _on_decision) == -1:
		push_warning(TAG + "AI.Decision is already replaced by another mod; disable other AI mods")
	if _lib.hook("ai-cover", _on_cover) == -1:
		push_warning(TAG + "AI.Cover is already replaced by another mod; disable other AI mods")
	if _lib.hook("ai-defend", _on_defend) == -1:
		push_warning(TAG + "AI.Defend is already replaced by another mod; disable other AI mods")
	if _lib.hook("ai-attack", _on_attack) == -1:
		push_warning(TAG + "AI.Attack is already replaced by another mod; disable other AI mods")
	if _lib.hook("ai-hide", _on_hide) == -1:
		push_warning(TAG + "AI.Hide is already replaced by another mod; disable other AI mods")

	if _lib.hook("ai-hunt", _on_hunt) == -1:
		push_warning(TAG + "AI.Hunt is already replaced by another mod; searching disabled")
	if _lib.hook("ai-switch", _on_switch) == -1:
		push_warning(TAG + "AI.Switch is already replaced by another mod; flanking disabled")
	_lib.hook("ai-fireaccuracy-post", _on_fire_accuracy)
	_lib.hook("ai-firefrequency-post", _on_fire_frequency)
	if _lib.hook("ai-selector", _on_selector) == -1:
		push_warning(TAG + "AI.Selector is already replaced by another mod; vanilla full-auto rolls kept")

	_lib.hook("ai-changestate-post", _on_change_state)
	_lib.hook("ai-selectweapon-post", _on_select_weapon)


	# WeaponRig.Reload/Insert/AmmoCheck poll input every frame, so hook the sounds that only play on the action.
	_lib.hook("weaponrig-playreload-post", func(): _emit_action("reload"))
	_lib.hook("weaponrig-playreloadempty-post", func(): _emit_action("reload"))
	_lib.hook("weaponrig-playreloadtactical-post", func(): _emit_action("reload"))
	_lib.hook("weaponrig-playmagazineattachempty-post", func(): _emit_action("reload"))
	_lib.hook("weaponrig-playmagazineattachtactical-post", func(): _emit_action("reload"))
	_lib.hook("weaponrig-playmagazinedetach-post", func(): _emit_action("reload"))
	_lib.hook("weaponrig-playmalfunctionclear-post", func(): _emit_action("reload"))
	_lib.hook("weaponrig-playinsert-post", func(): _emit_action("insert"))
	_lib.hook("weaponrig-playammocheck-post", func(): _emit_action("ammocheck"))
	_lib.hook("interface-use-pre", func(_item, _grid): _emit_action("use"))
	_lib.hook("interface-charge-pre", func(_item, _source): _emit_action("charge"))
	_lib.hook("interface-load-pre", func(_item, _source): _emit_action("load"))
	_lib.hook("interface-unloadmagazine-pre", func(_item, _grid): _emit_action("unload"))
	_lib.hook("interface-unloadweapon-pre", func(_item, _grid): _emit_action("unload"))
	_lib.hook("interface-changemagazine-pre", func(_slot): _emit_action("magazine"))
	_lib.hook("interface-craft-pre", func(_recipe): _emit_action("craft"))

	print(TAG + "hooks registered")

func _input(event):
	if event is InputEventKey && event.pressed && !event.is_echo() && event.keycode == KEY_F9:
		_debug = !_debug
		for ai in _live_bots():
			ai.AISpawner.debug = _debug
			ai.Debug(_debug)
		Engine.set_meta("rtv_esp_f9", _debug)
		print(TAG + "debug " + ("on" if _debug else "off"))
		if _debug: _log_masks()



func _on_priority_los():
	var sensor = _lib._caller
	var ai = sensor.owner
	if !_affects(ai): return
	_lib.skip_super()

	var start := Time.get_ticks_usec()
	_priority_los(sensor, ai)
	_perf_add("los", Time.get_ticks_usec() - start)

func _priority_los(sensor, ai):
	_register(ai)
	# Near bots check often; far ones less (vanilla checks every 1 s).
	var cycle := LOS_CYCLE
	if sensor.PDistance > 90.0: cycle = 0.6
	elif sensor.PDistance > 40.0: cycle = 0.35
	if sensor.raycastCycle != cycle: sensor.raycastCycle = cycle


	var now := _now()
	var dt: float = clamp(now - float(sensor.get_meta("bs_t", now)), 0.0, 1.0)
	sensor.set_meta("bs_t", now)
	var aw: float = sensor.get_meta("bs_aw", 0.0)


	var target = sensor.priority
	if !is_instance_valid(target) || !target.is_inside_tree():
		sensor.PVisible = false
		sensor.set_meta("bs_aw", max(aw - AWARENESS_DECAY * dt, 0.0))
		sensor.set_meta("bs_vis", false)
		return


	# Dev Tools "AI ignores you": the player is invisible to our perception.
	if target.is_in_group("Player") && Engine.get_meta("rtv_ai_ignore_player", false):
		sensor.PVisible = false
		sensor.set_meta("bs_aw", max(aw - AWARENESS_DECAY * dt, 0.0))
		sensor.set_meta("bs_vis", false)
		return


	if !target.is_in_group("Player"):
		sensor.PVisible = _clear(sensor, sensor.global_position, target.global_position)
		sensor.set_meta("bs_vis", false)
		if sensor.PVisible && target.owner != null && "variant" in target.owner: _remember_target(ai, target.owner, target.global_position, now)
		return


	var dist: float = sensor.global_position.distance_to(target.global_position)
	var forward: Vector3 = sensor.global_transform.basis.z.normalized()
	var angle: float = rad_to_deg(forward.angle_to((target.global_position - sensor.global_position).normalized()))
	var engaged: bool = sensor.hot && (aw >= 1.0 || now - float(ai.get_meta("bs_seen_t", -100.0)) < ENGAGED_MEMORY)


	var exposure := 0.0
	if dist <= sensor.viewDistance && (engaged || angle <= PERIPHERAL_HALF || dist < PROXIMITY):
		if _clear(sensor, sensor.global_position, gameData.cameraPosition): exposure += 0.5
		if _clear(sensor, sensor.global_position, target.global_position): exposure += 0.5


	if exposure <= 0.0:
		sensor.PVisible = false
		aw = max(aw - (AWARENESS_DECAY_HOT if sensor.hot else AWARENESS_DECAY) * dt, 0.0)
	else:
		if dist < (NIGHT_CAP_NEAR_DIST if _dark(sensor, dist, angle) else POINT_BLANK): aw = max(aw, 0.5)
		aw = min(aw + dt / _spot_time(sensor, dist, angle, exposure), 1.0)
		sensor.PVisible = aw >= 1.0
		if sensor.PVisible:
			var lastSeen: float = ai.get_meta("bs_seen_t", -100.0)
			# Losing sight because we ducked ourselves doesn't count as a new contact.
			var ducked: bool = now - float(ai.get_meta("bs_duck_end", -100.0)) < REACQUIRE_GRACE
			if !sensor.get_meta("bs_vis", false) && now - lastSeen > REACQUIRE_GRACE && !ducked: _acquire(ai, now)
			_remember_sighting(ai, target.global_position, now)
			ai.set_meta("bs_revealed", now)
			_share_contact(ai, target.global_position)
			# Just spotted: vanilla only re-decides from calm states, so an investigating (Hunt) or idle-fighting
			# bot would keep creeping toward its old target. Pick a real response now (push, cover, ...).
			if !sensor.get_meta("bs_vis", false):
				var state: String = ai.State.find_key(ai.currentState)
				if state == "Hunt" || state == "Combat" || state == "Ambush": ai.Decision()
		elif aw >= SUSPICION:
			_investigate(ai, target.global_position, dist * 0.15, 1.0 - dist / max(sensor.viewDistance, 1.0))


	sensor.set_meta("bs_aw", aw)
	sensor.set_meta("bs_vis", sensor.PVisible)

func _spot_time(sensor, dist: float, angle: float, exposure: float) -> float:
	var t: float = lerp(SPOT_TIME_NEAR, SPOT_TIME_FAR, pow(clamp(dist / MAX_SIGHT, 0.0, 1.0), 1.4))

	if angle > 80.0:
		# Far periphery: still targets are hard to notice, moving ones much less so.
		if gameData.isRunning: t *= 1.2
		elif gameData.isMoving: t *= 1.8
		else: t *= 3.0
	elif angle > 50.0: t *= 2.0
	elif angle > 25.0: t *= 1.5

	if gameData.isCrouching: t *= 1.7
	if !gameData.isMoving: t *= 1.5
	elif gameData.isRunning: t *= 0.7

	var dark := _dark(sensor, dist, angle)
	if gameData.TOD == 4:
		var night: float = lerp(NIGHT_NEAR, NIGHT_FAR, clamp(dist / NIGHT_RANGE, 0.0, 1.0)) if dark else 0.6
		# Night Gear: night vision mostly cancels the dark; a weapon light does inside its beam.
		var ai = sensor.owner
		if ai.get_meta("ng_nvg", false): night = min(night, 1.2)
		elif ai.get_meta("ng_light", false) && dist <= NG_LIGHT_RANGE && angle <= NG_LIGHT_ANGLE: night = min(night, 0.8)
		t *= night
	elif gameData.fog: t *= 1.6

	if exposure < 1.0: t *= 1.8
	if sensor.hot: t *= 0.5
	# Expecting you there (fresh memory): reacquire fast.
	if _now() - float(sensor.owner.get_meta("bs_lsp_t", -100.0)) < MEMORY_FRESH: t *= 0.4
	if _now() - _lastShotTime < 2.0 && !_lastShotSuppressed: t *= 0.3


	if dist < PROXIMITY: t = min(t, PROXIMITY_CAP)
	elif dist < (NIGHT_CAP_NEAR_DIST if dark else SPOT_CAP_NEAR_DIST): t = min(t, SPOT_CAP_NEAR if angle <= 75.0 else PERIPHERAL_CAP)
	elif !(gameData.isCrouching && !gameData.isMoving): t = min(t, NIGHT_CAP if dark else SPOT_CAP_FAR)
	return t

## Night and nothing lights the player up for this bot: no player light, no night vision, not in the bot's own beam.
func _dark(sensor, dist: float, angle: float) -> bool:
	if gameData.TOD != 4 || gameData.flashlight: return false
	var ai = sensor.owner
	if ai.get_meta("ng_nvg", false): return false
	return !(ai.get_meta("ng_light", false) && dist <= NG_LIGHT_RANGE && angle <= NG_LIGHT_ANGLE)

func _on_player_hear_detection():
	if _affects(_lib._caller.owner): _lib.skip_super()



func _on_footstep():
	var radius := STEP_WALK
	if gameData.isRunning: radius = STEP_RUN
	elif gameData.isCrouching: radius = STEP_CROUCH
	radius *= SURFACE_LOUDNESS.get(str(gameData.get("surface")), 1.0)
	_emit_sound(gameData.playerPosition, radius, 0.25)

func _on_land():
	_emit_sound(gameData.playerPosition, STEP_LAND, 0.25)

func _on_player_fire():
	var rig = _lib._caller
	var data = rig.get("data")
	_lastShotSuppressed = rig.get("activeMuzzle") != null || (data != null && data.nativeSuppressor)
	_lastShotTime = _now()
	_emit_sound(gameData.playerPosition, SHOT_SUPPRESSED if _lastShotSuppressed else SHOT_LOUD, 0.12)
	_apply_suppression(_lastShotSuppressed)

func _emit_sound(pos: Vector3, radius: float, errorScale: float):
	if gameData.isFlying || gameData.isDead: return

	for ai in _live_bots():
		var sensor = ai.sensor
		if sensor.PVisible || !_player_hostile(ai): continue

		var dist: float = sensor.global_position.distance_to(pos)
		if dist > radius: continue
		if dist > radius * WALL_DAMPING && !_clear(sensor, sensor.global_position, pos + Vector3(0.0, 1.0, 0.0)): continue


		var aw: float = sensor.get_meta("bs_aw", 0.0)
		sensor.set_meta("bs_aw", min(aw + 0.35 * (1.0 - dist / radius), 0.95))


		# Every sound refreshes memory (not only the investigations, which have a cooldown).
		var e := dist * errorScale
		var guess := pos + Vector3(randf_range(-e, e), 1.5, randf_range(-e, e))
		var shift := INF
		if ai.has_meta("bs_lsp"): shift = guess.distance_to(_memory_pos(ai))
		_remember(ai, guess)
		_investigate(ai, guess, 0.0, 1.0 - dist / radius)


		# A bot holding a position re-thinks when you turn out to be somewhere else entirely.
		var now := _now()
		if shift > MEMORY_SHIFT && shift != INF && ai.currentState == ai.State.Defend \
				&& now - float(ai.get_meta("bs_shift", -100.0)) > MEMORY_SHIFT_COOLDOWN:
			ai.set_meta("bs_shift", now)
			ai.Decision()

## Whether an ambushing bot gives up its hiding spot for a stimulus. closeness: 1 = right next to it, 0 = edge of range.
func _leaves_ambush(ai, closeness: float) -> bool:
	match str(ai.get_meta("bs_pers", "Normal")):
		"Rat", "Timid": return false
		"Rusher", "Berserker": return true
		_: return closeness > 0.5

func _investigate(ai, pos: Vector3, error: float, closeness: float = 1.0):
	var now := _now()
	if now - float(ai.get_meta("bs_inv", -100.0)) < INVESTIGATE_COOLDOWN: return

	var state: String = ai.State.find_key(ai.currentState)
	if state == "Ambush" && !_leaves_ambush(ai, closeness): return
	ai.set_meta("bs_inv", now)


	ai.LKL.global_position = pos + Vector3(randf_range(-error, error), 1.5 if error > 0.0 else 0.0, randf_range(-error, error))
	_remember(ai, ai.LKL.global_position)
	ai.sensor.hot = true
	ai.sensor.hotTimer = max(ai.sensor.hotTimer, INVESTIGATE_HOT)


	# Hiders and Rats out looting or wandering: back into ambush, don't go looking.
	if (state == "Wander" || state == "Loot") && (ai.has_meta("bs_home") || ai.get_meta("bs_pers", "") == "Rat"):
		_ambush_now(ai)
		return
	# Hiders looting for AI Actually Loots: let it take them back into ambush.
	if (state == "Wander" || state == "Loot") && ai.has_meta("aal_home") && Engine.has_meta("AIActuallyLoots"):
		Engine.get_meta("AIActuallyLoots").ambush(ai)
		return
	# Calm bots go and look (sneaking if unseen). Bots already fighting re-decide instead of being forced into a creep.
	if state in CALM_STATES || state == "Ambush":
		ai.ChangeState("Hunt")
		if _debug: print(TAG + ai.name + " investigating (" + state + " -> Hunt), error " + str(snapped(error, 0.1)) + " m")
	elif state == "Combat":
		ai.Decision()



func _on_decision():
	var ai = _lib._caller
	if !_affects(ai): return
	_lib.skip_super()
	_register(ai)


	# Rate limit: vanilla Combat()/Defend() call Decision() every frame while their exit condition holds
	# (e.g. no path), which would run the cover search every frame.
	# Mid-reload or rate-limited: defer (run from _on_parameters as soon as allowed) instead of dropping it.
	var now := _now()
	if ai.reload || now - float(ai.get_meta("bs_decided", -100.0)) < MIN_DECISION_INTERVAL \
			|| now < float(ai.get_meta("bs_evade_until", -100.0)):
		ai.set_meta("bs_pending", true)
		return
	ai.set_meta("bs_decided", now)
	ai.remove_meta("bs_pending")

	var start := Time.get_ticks_usec()
	_decide(ai)
	_perf_add("decision", Time.get_ticks_usec() - start)

func _decide(ai):
	var before: String = ai.State.find_key(ai.currentState)
	var threat := _threat_position(ai)
	var tm := _ai_memory(ai)
	var memory: bool = _memory_valid(ai) || !tm.is_empty()
	var allies := _engaged_allies(ai)
	var flanker := _squad_has_flanker(ai)
	# The flank point costs two navmesh queries: only look for one when Brain could actually pick Flank.
	var hp: float = ai.health / max(ai.variant.health, 1.0)
	var flankable: bool = memory && allies > 0 && !flanker && hp > 0.5 && Brain.suppression(ai, _now()) < 0.4
	var ctx := {
		"cover": _find_cover(ai, threat),
		"allies": allies,
		"flanker": flanker,
		"flank": _flank_point(ai, threat) if flankable else null,
		"nade": memory && _can_throw_now(ai) && _grenade_ok(ai, threat),
		"memory": memory,
		"morale": _morale(ai, _now()),
		"broken": _now() - float(ai.get_meta("bs_break_t", -100.0)) < BREAK_TIME,
		"seen_age": min(_now() - float(ai.get_meta("bs_seen_t", -100.0)), _now() - float(tm.get("t", -100.0))),
		"threat_dist": ai.global_position.distance_to(threat),
		"memory_age": _now() - float(tm["t"]) if !tm.is_empty() else _now() - float(ai.get_meta("bs_lsp_t", -100.0)),
		"squad_nade_t": _squad_nade_time(ai),
		"ally_hunting": _ally_hunting(ai),
	}
	var cover: Dictionary = ctx["cover"]
	var choice: String = Brain.decide(ai, _now(), ctx)


	if choice == "Flank":
		_start_flank(ai, ctx["flank"])
		if _debug: print(TAG + ai.name + " [" + ai.get_meta("bs_pers") + "] " + before + " -> Flank (" + str(ctx["allies"]) + " allies engaged)")
		return


	if choice == "Cover" || choice == "Hide":
		var entry: Dictionary = cover["fire"] if choice == "Cover" else cover["full"]
		_run_to_cover(ai, entry, choice)
		if _debug: print(TAG + ai.name + " [" + ai.get_meta("bs_pers") + "] " + before + " -> " + choice + " (" + ("full" if entry["full"] else "low") + " cover " + str(snapped(entry["dist"], 0.1)) + " m)")
		return


	if (choice == "Hunt" || choice == "Attack" || choice == "Grenade") && !ai.sensor.PVisible && memory:
		ai.LKL.global_position = threat
	if choice == "Grenade":
		ai.set_meta("bs_nades", int(ai.get_meta("bs_nades", 0)) - 1)
		ai.set_meta("bs_nade_t", _now())
		_bark(ai)


	ai.set_meta("bs_choice", choice)
	ai.ChangeState(choice)
	# Holding where we stand and it's a firing position: peek over it instead of standing exposed.
	var fire: Dictionary = cover.get("fire", {})
	if choice == "Defend" && !fire.is_empty() && fire["dist"] < 1.5 && !ctx["broken"]:
		_peek_phase(ai, false)


	# Sprint only while the target can't be seen; in sight, push at a jog firing full auto.
	# Berserkers sprint in sight too and stop at BERSERK_STOP to dump the magazine.
	if choice == "Attack":
		var berserk := _berserk(ai)
		if _push_should_stop(ai):
			if berserk: _push_stop(ai)
			else: _snap_fire(ai)
		elif ai.sensor.PVisible && !berserk:
			_snap_fire(ai)
		elif Brain.push_sprints(ai, _now()):
			ai.speed = PUSH_SPRINT
			if berserk: ai.set_meta("bs_rush", true)
			ai.set_meta("bs_choice", "Attack!")
			_request_cover_fire(ai)


	if _debug: print(TAG + ai.name + " [" + ai.get_meta("bs_pers") + "] " + before + " -> " + choice)

func _on_ai_damage_pre(_hitbox, _damage, _vector, id):
	var ai = _lib._caller
	if _affects(ai) && !ai.dead && is_instance_valid(id): ai.set_meta("bs_last_attacker", id)

func _on_ai_damaged(_hitbox, damage, _vector, id):
	var ai = _lib._caller
	if !_affects(ai) || ai.dead: return
	_register(ai)

	var now := _now()
	ai.set_meta("bs_hit", now)
	var freshFlinch: bool = now - float(ai.get_meta("bs_flinch_t", -100.0)) > FLINCH_SPREAD_TIME
	ai.set_meta("bs_flinch_t", now)
	_stop_heal(ai)
	_morale_hit(ai, 0.08 + float(damage) / max(ai.variant.health, 1.0) * 0.35, now, "hit")


	var sensor = ai.sensor
	if is_instance_valid(id) && id.is_in_group("Player") && !_player_hostile(ai): return
	if is_instance_valid(id) && id.is_in_group("Player"): ai.set_meta("bs_revealed", now)
	if is_instance_valid(id) && !sensor.PVisible:
		var e := HIT_GUESS_ERROR
		var guess: Vector3 = id.global_position + Vector3(randf_range(-e, e), 0.0, randf_range(-e, e))
		if id.is_in_group("Player"): _remember(ai, guess)
		elif id.owner != null && "variant" in id.owner: _remember_target(ai, id.owner, guess, now)
		sensor.set_meta("bs_aw", min(float(sensor.get_meta("bs_aw", 0.0)) + 0.5, 0.95))
		sensor.hot = true
		sensor.hotTimer = max(sensor.hotTimer, INVESTIGATE_HOT)
	if is_instance_valid(id) && id.is_in_group("Player"):
		_share_contact(ai, ai.get_meta("bs_lsp", id.global_position))


	var state: String = ai.State.find_key(ai.currentState)
	if state in CALM_STATES || state == "Cover" || state == "Hide" || state == "Grenade" || state == "Ambush": return
	# Shooter in sight and not badly hurt: keep fighting (return fire now) instead of breaking off. Vanilla never
	# interrupted firing on a hit; turning away from a visible shooter is the worst option.
	var hp: float = ai.health / max(ai.variant.health, 1.0)
	if sensor.PVisible && hp >= 0.4 && !ai.has_meta("bs_dyncover"):
		# Flinch once, then return fire (wide for a moment, see _on_fire_accuracy).
		if freshFlinch: ai.fireTime = randf_range(FLINCH_DELAY.x, FLINCH_DELAY.y)
		else: _snap_fire(ai)
		return
	if now - float(ai.get_meta("bs_react", -100.0)) < HIT_REACT_COOLDOWN: return
	ai.set_meta("bs_react", now)
	ai.Decision()

func _emit_action(kind: String):
	if gameData.isFlying || gameData.isDead: return

	var radius: float = ACTIONS[kind][0]
	var now := _now()
	var pos: Vector3 = gameData.playerPosition


	for ai in _live_bots():
		var sensor = ai.sensor
		if !_player_hostile(ai): continue
		var dist: float = sensor.global_position.distance_to(pos)
		var heard: bool = dist <= radius && (dist <= radius * WALL_DAMPING || _clear(sensor, sensor.global_position, pos + Vector3(0.0, 1.0, 0.0)))
		var seen: bool = sensor.PVisible && dist <= VISIBLE_ACTION_RANGE
		if !heard && !seen: continue


		ai.set_meta("bs_vuln", now + ACTIONS[kind][1])


		if !sensor.PVisible:
			var e := dist * 0.08
			_remember(ai, pos + Vector3(randf_range(-e, e), 1.5, randf_range(-e, e)))
			sensor.set_meta("bs_aw", min(float(sensor.get_meta("bs_aw", 0.0)) + 0.5, 0.95))
			sensor.hot = true
			sensor.hotTimer = max(sensor.hotTimer, INVESTIGATE_HOT)


		if _debug: print(TAG + ai.name + " heard " + kind + " at " + str(snapped(dist, 0.1)) + " m")


		var state: String = ai.State.find_key(ai.currentState)
		if state == "Grenade": continue
		if state == "Ambush" && !sensor.PVisible && !_leaves_ambush(ai, 1.0 - dist / radius): continue
		if now - float(ai.get_meta("bs_act", -100.0)) < ACTION_REACT_COOLDOWN: continue
		ai.set_meta("bs_act", now)
		ai.Decision()



## Vanilla Hunt/Switch/Ambush use the crouched animation. Creep only while sneaking up close; otherwise move
## upright with the Move animation at a jog. Re-checked every GAIT_CHECK seconds.
func _update_gait(ai, force := false):
	var now := _now()
	if ai.reload: return
	if !force && now - float(ai.get_meta("bs_gait_t", -100.0)) < GAIT_CHECK: return
	ai.set_meta("bs_gait_t", now)


	var creep: bool = ai.global_position.distance_to(ai.agent.target_position) < CREEP_RANGE && _may_sneak(ai, now)
	if !force && ai.has_meta("bs_creep") && bool(ai.get_meta("bs_creep")) == creep: return
	ai.set_meta("bs_creep", creep)


	ai.ResetAnimator()
	if creep:
		ai.animator["parameters/conditions/Hunt"] = true
		ai.speed = 1.0
	else:
		ai.animator["parameters/conditions/Move"] = true
		ai.speed = TRAVEL_SPEED

## Sneaking = the player hasn't seen this bot (or been shot by it, or shot at it) for SNEAK_FORGET seconds.
func _may_sneak(ai, now: float) -> bool:
	if ai.get_meta("bs_pers", "") in NEVER_SNEAK || ai.sensor.PVisible: return false
	if now - float(ai.get_meta("bs_hit", -100.0)) < SNEAK_FORGET: return false
	if _player_sees(ai): ai.set_meta("bs_revealed", now)
	return now - float(ai.get_meta("bs_revealed", -100.0)) > SNEAK_FORGET

## Whether this bot is inside the player's view cone with a clear line from the camera (one ray, only for
## bots that are creeping or about to).
func _player_sees(ai) -> bool:
	var head: Vector3 = ai.sensor.global_position
	var offset: Vector3 = head - gameData.cameraPosition
	var dist := offset.length()
	if dist > MAX_SIGHT || dist < 0.1: return false
	if gameData.playerVector.normalized().dot(offset / dist) < PLAYER_VIEW_DOT: return false
	return _clear(ai.sensor, gameData.cameraPosition, head)

func _on_parameters(delta):
	var ai = _lib._caller
	if !_affects(ai): return
	var start := Time.get_ticks_usec()
	_tick(ai, delta)
	_perf_add("tick", Time.get_ticks_usec() - start)

## Per physics frame, per bot (after vanilla Parameters): pending decisions, watchdogs, gait, aim, suppressive fire.
func _tick(ai, _delta: float):
	var sensor = ai.sensor
	var now := _now()
	_reload_watchdog(ai, now)
	_grenade_watchdog(ai, now)
	if ai.has_meta("bs_pending") && !ai.reload && now - float(ai.get_meta("bs_decided", -100.0)) >= MIN_DECISION_INTERVAL:
		ai.Decision()
	if (ai.currentState == ai.State.Hunt || ai.currentState == ai.State.Switch) && !ai.has_meta("bs_corner"): _update_gait(ai)


	# In sight: aim exactly at the target. Vanilla lerps LKL behind a moving target and Fire() refuses to shoot
	# when LKL is more than 1 m off, so sprinting players were barely shot at.
	if sensor.PVisible:
		ai.LKL.global_position = sensor.PLocation
		ai.remove_meta("bs_supaim")
		return
	if sensor.force: return


	# Out of sight of an AI target: keep aiming where it was last seen (vanilla drifts LKL in front of the bot).
	var tm := _ai_memory(ai)
	if !tm.is_empty():
		if !ai.has_meta("bs_search") && !ai.has_meta("bs_corner"): ai.LKL.global_position = tm["pos"]
		elif ai.has_meta("bs_corner"): ai.LKL.global_position = ai.get_meta("bs_corner")["aim"]
		else: ai.LKL.global_position = ai.agent.target_position + Vector3.UP * 1.4
		return


	# Out of sight: aim at our memory of the player, never at the true position. (Vanilla Parameters lerps LKL to the
	# real PLocation while threatPriority is set, i.e. for 5 s after every aimed player shot: a wallhack.)
	if !_memory_valid(ai):
		if ai.has_meta("bs_lsp") && (!sensor.hot || now - float(ai.get_meta("bs_lsp_t", -100.0)) > MEMORY_MAX):
			ai.remove_meta("bs_lsp")
		return


	ai.LKL.global_position = _memory_pos(ai)
	# Searching or checking a corner: aim where we're looking, not at the old memory.
	if ai.has_meta("bs_corner"): ai.LKL.global_position = ai.get_meta("bs_corner")["aim"]
	elif ai.has_meta("bs_search"): ai.LKL.global_position = ai.agent.target_position + Vector3.UP * 1.4
	_suppressive_fire(ai, _delta)

func _on_cover(_delta):
	var ai = _lib._caller
	if !_affects(ai): return
	_lib.skip_super()

	var toCover: float = ai.global_position.distance_to(ai.agent.target_position)
	if toCover < 2.0: ai.speed = 1.0
	elif toCover < 4.0: ai.speed = 3.0


	if ai.agent.is_target_reached() || ai.agent.is_navigation_finished():
		_hold_cover(ai)
	elif ai.sensor.hot && ai.sensor.PDistance < 10.0 && _now() > float(ai.get_meta("bs_evade_until", -100.0)):
		ai.ChangeState("Combat")

## Cover.find() with a per-bot cache and a per-frame budget across all bots.
func _find_cover(ai, threat: Vector3) -> Dictionary:
	var now := _now()
	var cached = ai.get_meta("bs_cov") if ai.has_meta("bs_cov") else null
	if cached != null && now - cached["t"] < COVER_CACHE_TIME \
			&& cached["from"].distance_to(ai.global_position) < 2.0 && cached["threat"].distance_to(threat) < 3.0:
		return cached["result"]


	var frame := Engine.get_physics_frames()
	if frame != _coverFrame:
		_coverFrame = frame
		_coverSearches = 0
	if _coverSearches >= COVER_SEARCHES_PER_FRAME:
		return cached["result"] if cached != null else {}
	_coverSearches += 1


	var start := Time.get_ticks_usec()
	var result: Dictionary = Cover.find(ai, threat, COVER_SEARCH)
	_perf_add("cover", Time.get_ticks_usec() - start)
	_perf["rays"] = int(_perf.get("rays", 0)) + int(result.get("rays", 0))
	_perf["snaps"] = int(_perf.get("snaps", 0)) + int(result.get("snaps", 0))


	ai.set_meta("bs_cov", {"t": now, "from": ai.global_position, "threat": threat, "result": result})
	return result

func _threat_position(ai) -> Vector3:
	if ai.sensor.PVisible: return ai.sensor.PLocation
	if _memory_valid(ai): return _memory_pos(ai)
	var tm := _ai_memory(ai)
	if !tm.is_empty(): return tm["pos"]
	return ai.sensor.PLocation

## Remember where an AI target (by its AI root) was seen or shot from.
func _remember_target(ai, root, pos: Vector3, now: float):
	ai.set_meta("bs_tmem", {"root": root, "pos": pos, "t": now})

## Memory of the current AI target, or {} (no memory, target changed or dead, cooled down, or too old).
func _ai_memory(ai) -> Dictionary:
	if !ai.has_meta("bs_tmem"): return {}
	var tm: Dictionary = ai.get_meta("bs_tmem")
	var target = ai.sensor.priority
	var root = tm["root"]
	if !is_instance_valid(root) || ("dead" in root && root.dead) || !ai.sensor.hot || _now() - float(tm["t"]) > AI_MEMORY \
			|| !is_instance_valid(target) || target.is_in_group("Player") || target.owner != root:
		return {}
	return tm

## Memory of the player: position, when it was learned, and movement when last seen (zero for sound guesses).
func _remember(ai, pos: Vector3, vel := Vector3.ZERO):
	ai.set_meta("bs_lsp", pos)
	ai.set_meta("bs_lsp_t", _now())
	ai.set_meta("bs_lsv", vel)

## A real sighting: also estimate the player's movement from the previous sighting (smoothed).
func _remember_sighting(ai, pos: Vector3, now: float):
	var vel := Vector3.ZERO
	var lastT: float = ai.get_meta("bs_lsp_t", -100.0)
	if ai.has_meta("bs_lsp") && now - lastT < 1.0 && now > lastT:
		vel = (pos - ai.get_meta("bs_lsp")) / (now - lastT)
		vel.y = 0.0
		vel = vel.lerp(ai.get_meta("bs_lsv", vel), 0.5).limit_length(7.0)
	_remember(ai, pos, vel)
	ai.set_meta("bs_seen_t", now)

## Where the player probably is now: the last known position pushed along their last seen movement.
func _memory_pos(ai) -> Vector3:
	var pos: Vector3 = ai.get_meta("bs_lsp")
	var vel: Vector3 = ai.get_meta("bs_lsv", Vector3.ZERO)
	if vel == Vector3.ZERO: return pos
	var age: float = clamp(_now() - float(ai.get_meta("bs_lsp_t", 0.0)), 0.0, PREDICT_TIME)
	return pos + (vel * age).limit_length(PREDICT_MAX)

## The bot's current target is the player (or it has no target yet, e.g. it only heard them), not another AI.
func _tracks_player(ai) -> bool:
	var target = ai.sensor.priority
	return !is_instance_valid(target) || target.is_in_group("Player")

## Memory of the player is usable: exists, the bot is still hot, the target is the player, and it isn't stale.
func _memory_valid(ai) -> bool:
	return ai.has_meta("bs_lsp") && ai.sensor.hot && _tracks_player(ai) \
		&& _now() - float(ai.get_meta("bs_lsp_t", -100.0)) < MEMORY_MAX

## Last grenade thrown by this bot or a same-faction ally within comms range.
func _squad_nade_time(ai) -> float:
	var latest: float = ai.get_meta("bs_nade_t", -100.0)
	for ally in _live_bots():
		if ally == ai || ally.variant.faction != ai.variant.faction: continue
		if ally.global_position.distance_to(ai.global_position) < COMMS_RANGE:
			latest = max(latest, float(ally.get_meta("bs_nade_t", -100.0)))
	return latest

## Vanilla clears `reload` from an animation callback; if a state change ever skips it the bot never fires again.
func _reload_watchdog(ai, now: float):
	if !ai.reload:
		if ai.has_meta("bs_reload_t"): ai.remove_meta("bs_reload_t")
		return
	if !ai.has_meta("bs_reload_t"):
		ai.set_meta("bs_reload_t", now)
	elif now - float(ai.get_meta("bs_reload_t")) > RELOAD_WATCHDOG:
		ai.reload = false
		ai.remove_meta("bs_reload_t")
		if _debug: print(TAG + ai.name + " reload watchdog cleared a stuck reload")

## The throw animation only starts from the Combat or Defend animation states (vanilla only throws from those).
## From anything else (moving, crouched peek/heal) nothing plays, Grenade(phase) never runs and the bot freezes.
func _can_throw_now(ai) -> bool:
	if ai.reload || ai.has_meta("bs_heal_until"): return false
	if ai.has_meta("bs_peek") && bool(ai.get_meta("bs_peek")["down"]): return false
	if _now() - float(ai.get_meta("bs_pose_t", -100.0)) < 0.6: return false
	return ai.currentState == ai.State.Combat || ai.currentState == ai.State.Defend

## Safety net: a bot stuck in Grenade (throw animation never ran) is put back in the fight with its weapon out.
func _grenade_watchdog(ai, now: float):
	if ai.currentState != ai.State.Grenade:
		if ai.has_meta("bs_nade_state_t"): ai.remove_meta("bs_nade_state_t")
		return
	if !ai.has_meta("bs_nade_state_t"):
		ai.set_meta("bs_nade_state_t", now)
	elif now - float(ai.get_meta("bs_nade_state_t")) > 4.0:
		# Grenade in hand = the throw animation started (phase 1); let vanilla finish it.
		var held = ai.get("throwGrenade")
		if is_instance_valid(held) && held.process_mode == Node.PROCESS_MODE_DISABLED && held.get_parent() == ai.get("grabR"):
			return
		ai.remove_meta("bs_nade_state_t")
		if ai.weapon: ai.weapon.show()
		ai.ChangeState("Combat")
		if _debug: print(TAG + ai.name + " grenade watchdog: throw never happened, back to Combat")

## Can this bot throw a grenade at the threat now: has one, outdoors, in range, off cooldown, no squadmate threw
## one just now, and the first few metres of the throw aren't blocked.
func _grenade_ok(ai, threat: Vector3) -> bool:
	if ai.grenade == null || int(ai.get_meta("bs_nades", 0)) <= 0 || ai.indoor: return false
	var now := _now()
	if now - float(ai.get_meta("bs_nade_t", -100.0)) < NADE_COOLDOWN: return false
	var dist: float = ai.global_position.distance_to(threat)
	if dist < NADE_RANGE.x || dist > NADE_RANGE.y: return false


	for ally in _live_bots():
		if ally == ai || ally.variant.faction != ai.variant.faction: continue
		if now - float(ally.get_meta("bs_nade_t", -100.0)) < SQUAD_NADE_COOLDOWN \
				&& ally.global_position.distance_to(ai.global_position) < COMMS_RANGE:
			return false


	var head: Vector3 = ai.sensor.global_position
	var flat := Vector3(threat.x - head.x, 0.0, threat.z - head.z).normalized()
	return _clear(ai.sensor, head, head + flat * 5.0 + Vector3(0.0, 2.0, 0.0))

## Sprint (no firing) to a dynamic cover spot found by Cover.find().
func _run_to_cover(ai, entry: Dictionary, choice: String):
	_release_hide_point(ai)
	for key in ["bs_peek", "bs_search", "bs_corner", "bs_flank", "bs_supaim", "bs_heal_until"]: ai.remove_meta(key)
	ai.set_meta("bs_pose_t", _now())
	ai.speed = PUSH_SPRINT
	ai.rotationSpeed = 5.0
	ai.agent.target_desired_distance = 0.5
	ai.currentState = ai.State.Cover if choice == "Cover" else ai.State.Hide
	ai.ResetAnimator()
	ai.animator["parameters/conditions/Move"] = true
	ai.MoveToPoint(entry["pos"])
	ai.set_meta("bs_dyncover", true)
	ai.set_meta("bs_cover_full", bool(entry["full"]))
	if choice == "Cover": _request_cover_fire(ai)
	ai.set_meta("bs_choice", choice + ">" + ("Full" if entry["full"] else "Low"))

## Arrived in cover: hold, aim at the last known position and return fire. Campers dig in longer.
func _hold_cover(ai):
	ai.remove_meta("bs_dyncover")
	ai.ChangeState("Defend")
	ai.set_meta("bs_settled", _now())
	if ai.get_meta("bs_pers", "") in ["Rat", "Timid"]: ai.defendCycle = randf_range(12.0, 25.0)
	ai.set_meta("bs_choice", "Cover>Hold")
	if _now() - float(ai.get_meta("bs_break_t", -100.0)) < BREAK_TIME:
		ai.defendCycle = randf_range(12.0, 22.0)
		ai.set_meta("bs_choice", "Broken>Hold")
	# Low cover = firing position: start the peek cycle (up if the target is in sight, else down).
	elif !bool(ai.get_meta("bs_cover_full", true)):
		_peek_phase(ai, false)

func _on_defend(delta):
	var ai = _lib._caller
	if !_affects(ai): return
	_lib.skip_super()

	if ai.reload: return


	ai.defendTimer += delta
	if _now() < float(ai.get_meta("bs_pushfire", -100.0)): _keep_full_auto(ai)
	var down: bool = ai.has_meta("bs_peek") && bool(ai.get_meta("bs_peek")["down"])
	if ai.sensor.PVisible && !down: ai.Fire(delta)
	if ai.has_meta("bs_peek"): _peek_cycle(ai)


	if ai.weaponSlot.amount == 0 && ai.weaponData.weaponAction != "Manual":
		ai.Reload()
		ai.PlayReload()
	elif ai.defendTimer > ai.defendCycle && !down:
		ai.Decision()

## Peek cycle: alternate crouched (hidden) and standing (firing) behind low cover. Never switches pose mid-reload.
func _peek_cycle(ai):
	if ai.has_meta("bs_heal_until"): return
	var peek: Dictionary = ai.get_meta("bs_peek")
	if _now() < float(peek["until"]) || ai.reload: return
	if peek["down"]:
		_peek_phase(ai, false)
	else:
		_peek_phase(ai, true)
		# Top up the magazine while hidden.
		if ai.weaponData.magazineSize > 0 && ai.weaponSlot.amount < ai.weaponData.magazineSize * 0.2 && ai.weaponData.weaponAction != "Manual":
			ai.Reload()
			ai.PlayReload()

func _peek_phase(ai, down: bool):
	var now := _now()
	var t: float
	if down:
		t = randf_range(PEEK_DOWN.x, PEEK_DOWN.y) + Brain.suppression(ai, now) * 3.0
		match str(ai.get_meta("bs_pers", "Normal")):
			"Rat", "Timid": t *= 1.4
			"Rusher", "Berserker": t *= 0.6
	else:
		t = randf_range(PEEK_UP.x, PEEK_UP.y)
	ai.set_meta("bs_peek", {"down": down, "until": now + t})
	ai.set_meta("bs_pose_t", now)
	if !down: ai.set_meta("bs_duck_end", now)
	ai.ResetAnimator()
	ai.animator["parameters/conditions/Hunt" if down else "parameters/conditions/Defend"] = true
	if down: _crouch_still(ai)
	if !down: ai.set_meta("bs_choice", "Peek")
	else: ai.set_meta("bs_choice", "Duck")
	# Never re-decide while ducked; re-deciding happens after a peek once the hold time is up.
	if down: ai.defendCycle = max(ai.defendCycle, ai.defendTimer + t + 0.5)



## Push fire: aim straight at the target, fire almost at once, full auto where the weapon allows.
func _snap_fire(ai):
	if ai.sensor.PVisible: ai.LKL.global_position = ai.sensor.PLocation
	var wait: float = float(ai.get_meta("bs_ready_t", 0.0)) - _now()
	ai.fireTime = max(min(ai.fireTime, randf_range(0.05, 0.2)), wait)
	ai.aim.influence = max(ai.aim.influence, 0.8)
	_keep_full_auto(ai)

func _keep_full_auto(ai):
	if ai.weaponData.weaponAction != "Semi-Auto" || ai.sensor.PDistance > LONG_RANGE: return
	ai.fullAuto = true
	ai.selectorTime = max(ai.selectorTime, 0.5)

func _berserk(ai) -> bool:
	return ai.get_meta("bs_pers", "") == "Berserker"

func _push_should_stop(ai) -> bool:
	var sensor = ai.sensor
	if _berserk(ai):
		var target: Vector3 = sensor.PLocation if sensor.PVisible else ai.LKL.global_position
		return Vector2(target.x - ai.global_position.x, target.z - ai.global_position.z).length() < BERSERK_STOP
	if sensor.PVisible && sensor.PDistance < PUSH_STOP_VISIBLE: return true
	return ai.global_position.distance_to(ai.LKL.global_position) < PUSH_STOP_NEAR

## End of a push: plant, aim at the target and fire full auto for a moment, then re-decide.
func _push_stop(ai):
	ai.ChangeState("Defend")
	ai.defendCycle = randf_range(BERSERK_HOLD.x, BERSERK_HOLD.y) if _berserk(ai) else randf_range(1.5, 3.0)
	ai.set_meta("bs_pushfire", _now() + ai.defendCycle)
	_snap_fire(ai)
	ai.set_meta("bs_choice", "Push>Fire")

func _on_attack(delta):
	var ai = _lib._caller
	if !_affects(ai): return
	_lib.skip_super()

	var sensor = ai.sensor
	var frame := Engine.get_physics_frames()
	var toTarget: float = ai.global_position.distance_to(ai.agent.target_position)


	if ai.speed > 3.0 || ai.get_meta("bs_rush", false):
		var berserk := _berserk(ai)
		var near := BERSERK_STOP if berserk else PUSH_STOP_NEAR
		if !ai.reload && (_push_should_stop(ai) || toTarget < near || ai.agent.is_navigation_finished()):
			_push_stop(ai)
			return
		# Target came into view mid-sprint: drop to a jog and open fire right away. Berserkers keep running.
		if sensor.PVisible && !berserk:
			ai.speed = 3.0
			_snap_fire(ai)
			ai.set_meta("bs_choice", "Push>Shoot")
			return
		# Berserkers keep coming and spray, at an aimed run while they can see the target, sprinting otherwise.
		if berserk:
			ai.speed = PUSH_RUN_FIRE if sensor.PVisible else PUSH_SPRINT
			if sensor.PVisible:
				_keep_full_auto(ai)
				ai.Fire(delta)
		# Re-path often while closing on a target in sight (it moves); LKL tracks the player while visible.
		if frame % (15 if sensor.PVisible else 50) == 0: ai.GetLKLPoint()
		if ai.weaponSlot.amount == 0 && ai.weaponData.weaponAction != "Manual" && !ai.reload:
			ai.Reload()
			ai.PlayReload()
		return


	if ai.reload:
		if frame % 50 == 0: ai.GetLKLPoint()
		if ai.agent.is_target_reached() || ai.agent.is_navigation_finished(): ai.ChangeState("Combat")
		return


	if toTarget < 2.0: ai.speed = 1.0
	elif toTarget < 4.0: ai.speed = 3.0

	if sensor.PVisible: ai.Fire(delta)
	if frame % 50 == 0: ai.GetLKLPoint()


	if ai.agent.is_target_reached() || ai.agent.is_navigation_finished() || gameData.isTrading:
		ai.ChangeState("Combat")
	elif ai.weaponSlot.amount == 0 && ai.weaponData.weaponAction != "Manual":
		ai.Reload()
		ai.PlayReload()



func _on_change_state(state):
	var ai = _lib._caller
	if !_affects(ai): return
	_register(ai)
	ai.set_meta("bs_pose_t", _now())
	ai.remove_meta("bs_rush")
	if ai.has_meta("bs_loot_starting") || ai.has_meta("aal_starting"): return
	if ai.has_meta("bs_loot"):
		if state == "Wander":
			if _continue_loot(ai): return
		elif state != "Loot":
			_end_loot(ai, false)

	if state != "Hide" && state != "Ambush": _release_hide_point(ai)
	if state == "Hunt" || state == "Switch": _update_gait(ai, true)
	else: ai.remove_meta("bs_creep")
	if state != "Cover" && state != "Hide": ai.remove_meta("bs_dyncover")
	if state != "Switch": ai.remove_meta("bs_flank")
	ai.remove_meta("bs_supaim")
	ai.remove_meta("bs_heal_until")
	# Peek cycles and searches set themselves up after their own ChangeState call; anything else ends them.
	ai.remove_meta("bs_peek")
	ai.remove_meta("bs_search")
	ai.remove_meta("bs_corner")
	if ai.get_meta("bs_pers", "") != "Rat": return


	if state == "Ambush":
		ai.ambushCycle = randf_range(RAT_CAMP_TIME.x, RAT_CAMP_TIME.y)
	elif state == "Wander" && !ai.sensor.hot && !ai.has_meta("aal_loot"):
		_rat_go_to_ground(ai)

func _rat_go_to_ground(ai):
	var candidates := []
	for point in ai.AISpawner.hides:
		if !is_instance_valid(point) || point.get("occupied"): continue
		if ai.global_position.distance_to(point.global_position) < RAT_HIDE_RANGE:
			candidates.append(point)


	# Walk there normally (the Wander animation ChangeState just set); crouching is only for creeping up
	# on a nearby enemy. No hide point nearby: keep wandering.
	if candidates.is_empty(): return


	var point = candidates.pick_random()
	point.set("occupied", true)
	ai.set_meta("bs_hidept", point)
	ai.currentPoint = point
	ai.MoveToPoint(point.global_position)


	ai.speed = 1.0
	ai.rotationSpeed = 5.0
	ai.agent.target_desired_distance = 0.5
	ai.currentState = ai.State.Hide
	ai.set_meta("bs_choice", "Rat>Hide")

func _release_hide_point(ai):
	if !ai.has_meta("bs_hidept"): return
	var point = ai.get_meta("bs_hidept")
	if is_instance_valid(point): point.set("occupied", false)
	ai.remove_meta("bs_hidept")

func _on_hide(_delta):
	var ai = _lib._caller
	if !_affects(ai): return
	_lib.skip_super()

	var sneaking: bool = ai.has_meta("bs_hidept") && !ai.sensor.hot
	var toPoint: float = ai.global_position.distance_to(ai.agent.target_position)


	# Vanilla Alert() ignores the Hide state, so a sneaking bot that spots the player must react itself.
	if ai.has_meta("bs_hidept") && ai.sensor.PVisible:
		_release_hide_point(ai)
		ai.Decision()
		return


	if sneaking: ai.speed = 1.0
	elif toPoint < 2.0: ai.speed = 1.0
	elif toPoint < 4.0: ai.speed = 3.0


	if ai.agent.is_target_reached() || ai.agent.is_navigation_finished():
		var camper: bool = ai.get_meta("bs_pers", "") in ["Rat", "Timid"]
		var homerun: bool = ai.has_meta("bs_homerun")
		ai.remove_meta("bs_homerun")
		if ai.has_meta("bs_dyncover"): _hold_cover(ai)
		elif sneaking || camper || homerun || randi_range(0, 100) < 25: ai.ChangeState("Ambush")
		else: ai.ChangeState("Combat")
	elif ai.sensor.hot && ai.sensor.PDistance < 10.0:
		ai.ChangeState("Combat")



func _on_select_weapon():
	var ai = _lib._caller
	if !_affects(ai) || ai.weapon == null || ai.weaponData == null: return

	var wantOptic: bool = randf() < float(opticChance.get(ai.variant.faction, 0.05))
	if ai.optic && !wantOptic: _set_optic(ai, false)
	elif !ai.optic && wantOptic: _set_optic(ai, true)

func _set_optic(ai, on: bool):
	var attachments = ai.weapon.get_node_or_null("Attachments")
	if attachments == null: return
	var mount = attachments.get_node_or_null("Mount")


	if on:
		var choices := []
		for data in ai.weaponData.compatible:
			if data.subtype == "Optic" && attachments.get_node_or_null(data.file): choices.append(data)
		if choices.is_empty(): return

		var opticData = choices.pick_random()
		var optic = attachments.get_node(opticData.file)
		var LOD0 = optic.get_node_or_null("LOD0")
		var LOD1 = optic.get_node_or_null("LOD1")
		if LOD0: LOD0.visibility_range_end = 10.0
		if LOD1:
			LOD1.visibility_range_begin = 9.0
			LOD1.visibility_range_end = 200.0
		optic.show()

		if ai.weaponData.useMount && mount:
			var mountMesh = mount.get_node_or_null("Mesh")
			if mountMesh: mountMesh.visibility_range_end = 200.0
			mount.show()

		ai.weapon.slotData.nested.append(opticData)
		ai.optic = true


	else:
		for data in ai.weapon.slotData.nested.duplicate():
			if data.subtype != "Optic": continue
			var optic = attachments.get_node_or_null(data.file)
			if optic: optic.hide()
			ai.weapon.slotData.nested.erase(data)

		if mount: mount.hide()
		ai.optic = false



func _apply_suppression(quiet: bool):
	if gameData.isFlying || gameData.isDead: return

	var now := _now()
	var origin: Vector3 = gameData.cameraPosition
	var dir: Vector3 = gameData.playerVector.normalized()


	for ai in _live_bots():
		if !_player_hostile(ai): continue
		var rel: Vector3 = ai.sensor.global_position - origin
		var along := rel.dot(dir)
		if along <= 0.0 || along > SUPPRESS_RANGE: continue
		var miss := (rel - dir * along).length()
		if miss > SUPPRESS_RADIUS: continue


		var amount := (1.0 - miss / SUPPRESS_RADIUS) * (SUPPRESS_QUIET if quiet else SUPPRESS_LOUD)
		var level: float = min(Brain.suppression(ai, now) + amount, 1.0)
		ai.set_meta("bs_sup", level)
		ai.set_meta("bs_sup_t", now)


		# Shot at = the player has seen this bot.
		ai.set_meta("bs_revealed", now)
		if amount >= 0.2:
			if now - float(ai.get_meta("bs_flinch_t", -100.0)) > FLINCH_SPREAD_TIME:
				ai.fireTime = randf_range(FLINCH_DELAY.x, FLINCH_DELAY.y) * 0.5
			ai.set_meta("bs_flinch_t", now)
		# Pinned (not every near miss) wears morale down; hits are charged in _on_ai_damaged already.
		if level > 0.5 && now - float(ai.get_meta("bs_supmor_t", -100.0)) >= 1.0 && now - float(ai.get_meta("bs_hit", -100.0)) > 0.1:
			ai.set_meta("bs_supmor_t", now)
			_morale_hit(ai, 0.08, now, "suppressed")
		if ai.dead || now - float(ai.get_meta("bs_break_t", -100.0)) < 0.1: continue
		var sensor = ai.sensor
		if !sensor.PVisible:
			var e := along * 0.1
			_remember(ai, origin + Vector3(randf_range(-e, e), 0.0, randf_range(-e, e)))
			sensor.set_meta("bs_aw", min(float(sensor.get_meta("bs_aw", 0.0)) + 0.3, 0.95))
			sensor.hot = true
			sensor.hotTimer = max(sensor.hotTimer, INVESTIGATE_HOT)


		var state: String = ai.State.find_key(ai.currentState)
		if level < SUPPRESS_REACT || state in ["Cover", "Hide", "Grenade"]: continue
		# Seeing the shooter: keep trading fire unless really pinned.
		if sensor.PVisible && level < 0.8: continue
		if now - float(ai.get_meta("bs_react", -100.0)) < HIT_REACT_COOLDOWN: continue
		ai.set_meta("bs_react", now)
		ai.Decision()

func _on_fire_accuracy(_result):
	var ai = _lib._caller
	if !_affects(ai): return null

	var result: Vector3 = _result
	var now := _now()
	# Re-roll vanilla's spread from our distance curve (same full-auto / optic factors as vanilla).
	if ai.sensor.PVisible && AIM_CURVE.has(ai.variant.faction):
		var s: float = _aim_spread(AIM_CURVE[ai.variant.faction], ai.sensor.PDistance) 			* ((2.0 if ai.fullAuto else 1.0) - (0.1 if ai.optic else 0.0))
		var basis: Basis = ai.fire.global_transform.basis
		result = ai.sensor.PLocation - Vector3(0.0, 0.5, 0.0) + basis.x * randf_range(-s, s) + basis.y * randf_range(-s, s)
	# Ramp: wide and high right after acquiring the target, normal after the faction's ramp time; wider after a flinch.
	if ai.sensor.PVisible:
		var k: float = clamp((now - float(ai.get_meta("bs_acq_t", -100.0))) / float(_fire_style(ai)["ramp"]), 0.0, 1.0)
		var mult: float = lerp(ACC_START, 1.0, k)
		if now - float(ai.get_meta("bs_flinch_t", -100.0)) < FLINCH_SPREAD_TIME: mult += FLINCH_SPREAD
		if mult > 1.0:
			var center: Vector3 = ai.sensor.PLocation - Vector3(0.0, 0.5, 0.0)
			result = center + (result - center) * mult + Vector3(0.0, HIGH_MISS * (1.0 - k), 0.0)
	# Suppressive fire: vanilla aims at the true player position; aim at the remembered one instead.
	if !ai.sensor.PVisible && ai.has_meta("bs_supaim"):
		var s: float = SUPFIRE_SPREAD * clamp(ai.global_position.distance_to(ai.get_meta("bs_supaim")) / 25.0, 0.5, 2.5)
		result = ai.get_meta("bs_supaim") + Vector3(randf_range(-s, s), randf_range(-s, s) * 0.4, randf_range(-s, s))


	var level := Brain.suppression(ai, now)
	if level < 0.05: return result


	var spread: float = level * SUPPRESS_SPREAD * clamp(ai.sensor.PDistance / 20.0, 0.5, 3.0)
	return result + Vector3(randf_range(-spread, spread), randf_range(-spread, spread) * 0.5, randf_range(-spread, spread))

## Linear between the curve's points, flat past the last one.
func _aim_spread(curve: Array, d: float) -> float:
	for i in range(1, curve.size()):
		if d <= curve[i].x:
			return lerp(curve[i - 1].y, curve[i].y, (d - curve[i - 1].x) / (curve[i].x - curve[i - 1].x))
	return curve[-1].y

func _fire_style(ai) -> Dictionary:
	return FIRE_STYLE.get(ai.variant.faction, FIRE_STYLE[AIData.Faction.Guard])

## The player is moving toward this bot (from the last sighting's movement estimate).
func _player_closing(ai) -> bool:
	if !ai.has_meta("bs_lsp") || _now() - float(ai.get_meta("bs_lsp_t", -100.0)) > 2.0: return false
	var vel: Vector3 = ai.get_meta("bs_lsv", Vector3.ZERO)
	var toBot: Vector3 = ai.global_position - ai.get_meta("bs_lsp")
	toBot.y = 0.0
	return toBot.length() > 0.1 && vel.dot(toBot.normalized()) > CLOSING_SPEED

## Faster trigger than vanilla (semi 0.1-1.0 s at 10-50 m, up to 4 s beyond), faster still when the player
## closes in or the bot is suppressing. Full auto keeps the weapon's own fire rate.
func _on_fire_frequency():
	var ai = _lib._caller
	if !_affects(ai) || ai.weaponData == null: return

	var action: String = ai.weaponData.weaponAction
	if action == "Semi-Auto" && ai.fullAuto: return


	var d: float = ai.sensor.PDistance
	var gap: float = _fire_style(ai)["gap"]
	if _player_closing(ai) || ai.has_meta("bs_supaim"): gap *= 0.7
	if ai.get_meta("bs_pers", "") in ["Rusher", "Berserker"]: gap *= 0.85


	if action == "Semi-Auto" || action == "Semi":
		if d < 15.0: ai.fireTime = randf_range(0.08, 0.25) * gap
		elif d < MID_RANGE: ai.fireTime = randf_range(0.12, 0.45) * gap
		elif d < LONG_RANGE: ai.fireTime = randf_range(0.4, 1.2) * gap
		# Long range: aimed single shots. Untrained bandits sometimes snap off a quick follow-up.
		elif ai.variant.faction == AIData.Faction.Bandit && randf() < BANDIT_FOLLOWUP: ai.fireTime = randf_range(0.25, 0.5)
		else: ai.fireTime = randf_range(LONG_GAP.x, LONG_GAP.y) * gap
	elif action == "Pump":
		ai.fireTime = randf_range(0.6, 1.1) * max(gap, 0.85)
	elif action == "Bolt":
		ai.fireTime = randf_range(0.9, 1.6) * max(gap, 0.9)

## Vanilla rolls full auto 10% of the time (always in Attack). Roll by faction, more when the player is close,
## closing in, or the bot is laying down suppression; bursts last by faction.
func _on_selector(delta):
	var ai = _lib._caller
	if !_affects(ai): return
	_lib.skip_super()

	ai.selectorTime -= delta
	if ai.selectorTime > 0.0: return


	# Long range: single shots only, whatever the situation.
	if ai.sensor.PDistance > LONG_RANGE:
		ai.fullAuto = false
		ai.selectorTime = randf_range(0.6, 2.0)
		return


	var style := _fire_style(ai)
	var chance: float = style["auto"]
	if ai.currentState == ai.State.Attack || _now() < float(ai.get_meta("bs_pushfire", -100.0)): chance = 1.0
	if ai.sensor.PDistance < 15.0 || _player_closing(ai): chance += 0.35
	if ai.has_meta("bs_supaim"): chance += 0.3
	if ai.get_meta("bs_pers", "") in ["Rusher", "Berserker"]: chance += 0.2
	# Full auto doubles spread: past MID_RANGE it's rare and short (suppressing included).
	var mid: bool = ai.sensor.PDistance > MID_RANGE
	if mid: chance = min(chance * 0.4, MID_AUTO_CAP)


	if randf() < chance:
		ai.fullAuto = true
		ai.selectorTime = randf_range(style["burst"].x, style["burst"].y) * (MID_BURST if mid else 1.0)
	else:
		ai.fullAuto = false
		ai.selectorTime = randf_range(0.6, 2.0)

## Out of sight but recently seen: keep shooting at where the player is believed to be, in bursts, so cover gets
## hammered and pushing in costs something. Only when the shot lane isn't blocked near the bot itself.
func _suppressive_fire(ai, delta):
	var sensor = ai.sensor
	var now := _now()
	var state: int = ai.currentState
	var states = ai.State
	var fireState: bool = state == states.Defend || state == states.Combat || state == states.Lurk || state == states.Attack
	var style := _fire_style(ai)
	var covering: bool = now < float(ai.get_meta("bs_coverfire_until", -100.0))
	var ducked: bool = ai.has_meta("bs_peek") && bool(ai.get_meta("bs_peek")["down"])
	var ok: bool = !ai.reload && !ducked && ai.weaponSlot.amount > 0 && fireState && ai.speed <= 3.0 \
		&& is_instance_valid(sensor.priority) && sensor.priority.is_in_group("Player") && _player_hostile(ai) \
		&& now - float(ai.get_meta("bs_lsp_t", -100.0)) < (COVER_FIRE_MEMORY if covering else float(style["memory"]))
	var target: Vector3 = ai.LKL.global_position
	if ok: ok = ai.global_position.distance_to(target) < SUPFIRE_RANGE && _supfire_lane(ai, target, now)
	if !ok:
		ai.remove_meta("bs_supaim")
		return


	# Bursts with pauses (bandits: long bursts, short pauses).
	if now > float(ai.get_meta("bs_burst_end", -100.0)):
		if now < float(ai.get_meta("bs_burst_next", -100.0)):
			ai.remove_meta("bs_supaim")
			return
		var end: float = now + randf_range(style["burst"].x, style["burst"].y)
		ai.set_meta("bs_burst_end", end)
		var pause: float = randf_range(style["pause"].x, style["pause"].y) * (0.4 if covering else 1.0)
		ai.set_meta("bs_burst_next", end + pause)
		ai.set_meta("bs_choice", "Cover fire" if covering else "Suppress")
	ai.set_meta("bs_supaim", target)


	# Same steps as vanilla Fire() minus its "LKL must be on the visible player" check.
	if ai.weaponData.weaponAction == "Semi-Auto": ai.Selector(delta)
	ai.fireTime -= delta
	if ai.fireTime > 0.0: return

	ai.Raycast()
	ai.PlayFire()
	ai.PlayTail()
	ai.MuzzleVFX()
	ai.impulse.RecoilImpulse(-5.0 if ai.fullAuto else -10.0)
	ai.weaponSlot.amount -= 1
	ai.FireFrequency()

## Lane check (cached 0.5 s): fire unless something blocks the shot in the first half of the distance,
## i.e. only the player's own cover may stop the bullets.
func _supfire_lane(ai, target: Vector3, now: float) -> bool:
	if now - float(ai.get_meta("bs_lane_t", -100.0)) < 0.5: return ai.get_meta("bs_lane", false)

	var from: Vector3 = ai.sensor.global_position
	var query = PhysicsRayQueryParameters3D.create(from, target)
	query.collision_mask = ai.sensor.obstruction
	var hit: Dictionary = ai.sensor.get_world_3d().direct_space_state.intersect_ray(query)
	var clear: bool = hit.is_empty() || from.distance_to(hit["position"]) > from.distance_to(target) * 0.5
	ai.set_meta("bs_lane_t", now)
	ai.set_meta("bs_lane", clear)
	return clear



## Tell nearby allies of the same faction where the player is (callout, delivered after a short delay).
func _share_contact(ai, pos: Vector3):
	var now := _now()
	if now - float(ai.get_meta("bs_share", -100.0)) < SHARE_COOLDOWN: return
	ai.set_meta("bs_share", now)


	var told := 0
	for ally in _live_bots():
		if ally == ai || ally.variant.faction != ai.variant.faction: continue
		if ally.global_position.distance_to(ai.global_position) > COMMS_RANGE: continue
		if ally.sensor.PVisible: continue
		told += 1
		get_tree().create_timer(randf_range(COMMS_DELAY.x, COMMS_DELAY.y), false).timeout.connect(_receive_contact.bind(ally, pos, ai.name))


	if told > 0: _bark(ai)

func _receive_contact(ally, pos: Vector3, from: String):
	if !is_instance_valid(ally) || ally.dead || !ally.active || ally.sensor.PVisible: return

	var e := COMMS_ERROR
	_remember(ally, pos + Vector3(randf_range(-e, e), 0.0, randf_range(-e, e)))
	ally.set_meta("bs_squad", _now())
	var sensor = ally.sensor
	sensor.set_meta("bs_aw", max(float(sensor.get_meta("bs_aw", 0.0)), 0.6))
	sensor.hot = true
	sensor.hotTimer = max(sensor.hotTimer, INVESTIGATE_HOT)


	var state: String = ally.State.find_key(ally.currentState)
	if _debug: print(TAG + ally.name + " got callout from " + from + " (" + state + ")")
	if state in CALM_STATES || (state == "Ambush" && _leaves_ambush(ally, 0.6)):
		ally.Decision()

func _engaged_allies(ai) -> int:
	var count := 0
	for ally in _live_bots():
		if ally == ai || ally.variant.faction != ai.variant.faction: continue
		if !ally.sensor.hot || ally.global_position.distance_to(ai.global_position) > COMMS_RANGE * 1.2: continue
		if ally.State.find_key(ally.currentState) in ["Combat", "Defend", "Attack", "Hunt", "Cover", "Vantage", "Lurk"]:
			count += 1
	return count

func _squad_has_flanker(ai) -> bool:
	var now := _now()
	for ally in _live_bots():
		if ally == ai || ally.variant.faction != ai.variant.faction: continue
		if ally.global_position.distance_to(ai.global_position) > COMMS_RANGE * 1.2: continue
		if now - float(ally.get_meta("bs_flank", -100.0)) < FLANK_TIMEOUT: return true
	return false

## A navmesh point ~70 degrees around the threat at a similar distance, or null.
func _flank_point(ai, threat: Vector3):
	var away: Vector3 = ai.global_position - threat
	away.y = 0.0
	var dist := away.length()
	if dist < 12.0 || dist > 90.0: return null


	var first := 1.0 if randf() < 0.5 else -1.0
	for side in [first, -first]:
		var wanted: Vector3 = threat + away.normalized().rotated(Vector3.UP, side * deg_to_rad(70.0)) * max(dist * 0.8, 15.0)
		var spot: Vector3 = NavigationServer3D.map_get_closest_point(ai.navmesh, wanted)
		if Vector2(spot.x - wanted.x, spot.z - wanted.z).length() < 4.0: return spot
	return null

func _start_flank(ai, spot: Vector3):
	ai.ChangeState("Switch")
	ai.MoveToPoint(spot)
	_update_gait(ai, true)
	ai.set_meta("bs_flank", _now())
	ai.set_meta("bs_choice", "Flank")
	_request_cover_fire(ai)

func _on_switch(delta):
	var ai = _lib._caller
	if !_affects(ai): return
	_lib.skip_super()
	# Only flanks use Switch here. Without a flank (its exit decision was deferred) just ask again.
	if !ai.has_meta("bs_flank"):
		ai.Decision()
		return

	var sensor = ai.sensor
	if sensor.PVisible: ai.Fire(delta)


	if ai.agent.is_target_reached() || ai.agent.is_navigation_finished() || _now() - float(ai.get_meta("bs_flank")) > FLANK_TIMEOUT:
		ai.remove_meta("bs_flank")
		ai.Decision()
	elif sensor.PVisible && sensor.PDistance < 10.0:
		ai.remove_meta("bs_flank")
		ai.ChangeState("Combat")



func _on_update_status():
	var ai = _lib._caller
	if !_affects(ai): return
	var personality := str(ai.get_meta("bs_pers", "?")).to_upper()
	var awareness := "AW " + str(snapped(float(ai.sensor.get_meta("bs_aw", 0.0)), 0.01))
	var level := Brain.suppression(ai, _now())
	if level >= 0.05: awareness += "  SUP " + str(snapped(level, 0.01))
	var morale := _morale(ai, _now())
	if morale < 0.99: awareness += "  MOR " + str(snapped(morale, 0.01))
	ai.status.text = personality + " > " + str(ai.get_meta("bs_choice", "-")) + "\n" + ai.status.text + "\n" + awareness
	ai.status.no_depth_test = true



## ------------------------------------------------------------------------------------------------ hunting / search

## Vanilla Hunt, except: arriving at a remembered spot with nobody there starts a search (instead of vanilla's random
## Combat stroll); creeping bots pause at corners; searching bots walk a list of nearby hiding spots.
func _on_hunt(delta):
	var ai = _lib._caller
	if !_affects(ai): return
	_lib.skip_super()


	var sensor = ai.sensor
	var arrived: bool = ai.agent.is_target_reached() || ai.agent.is_navigation_finished()
	if ai.reload:
		if arrived && !ai.has_meta("bs_search"): ai.GetWanderPoint()
		return


	if sensor.PVisible:
		ai.remove_meta("bs_search")
		_end_corner(ai)
		ai.Fire(delta)
	else:
		_check_corner(ai)
	if !ai.has_meta("bs_search") && !ai.has_meta("bs_corner") && Engine.get_physics_frames() % 100 == 0: ai.GetLKLPoint()


	if arrived || gameData.isTrading:
		if ai.has_meta("bs_search"): _next_search_point(ai)
		elif !sensor.PVisible && !gameData.isTrading && (_memory_valid(ai) || !_ai_memory(ai).is_empty()): _start_search(ai)
		else: ai.ChangeState("Combat")
	elif ai.weaponSlot.amount == 0 && ai.weaponData.weaponAction != "Manual":
		ai.Reload()
		ai.PlayReload()

## Nobody at the remembered spot: check the hiding spots around it. If a squadmate already searches here, hold the
## angle instead (one approacher, the rest cover).
func _start_search(ai):
	var center := _threat_position(ai)
	for ally in _live_bots():
		if ally == ai || ally.variant.faction != ai.variant.faction || !ally.has_meta("bs_search"): continue
		if Vector3(ally.get_meta("bs_search_c")).distance_to(center) < 15.0:
			ai.ChangeState("Defend")
			ai.defendCycle = randf_range(8.0, 15.0)
			ai.set_meta("bs_choice", "Hold angle")
			return


	var candidates := []
	for point in ai.AISpawner.hides:
		if is_instance_valid(point) && point.global_position.distance_to(center) < SEARCH_RADIUS: candidates.append(point.global_position)
	for point in ai.AISpawner.covers:
		if is_instance_valid(point) && point.global_position.distance_to(center) < SEARCH_RADIUS: candidates.append(point.global_position)
	candidates.shuffle()
	var points: Array = candidates.slice(0, SEARCH_POINTS - 1)
	var wanted := center + Vector3(randf_range(-8.0, 8.0), 0.0, randf_range(-8.0, 8.0))
	var spot: Vector3 = NavigationServer3D.map_get_closest_point(ai.navmesh, wanted)
	if spot.distance_to(wanted) < 4.0: points.append(spot)
	if points.is_empty():
		_give_up(ai)
		return


	# Visit nearest-first from where we stand.
	var ordered := []
	var from: Vector3 = ai.global_position
	while !points.is_empty():
		var best := 0
		for i in points.size():
			if from.distance_to(points[i]) < from.distance_to(points[best]): best = i
		from = points[best]
		ordered.append(points[best])
		points.remove_at(best)


	ai.set_meta("bs_search", ordered)
	ai.set_meta("bs_search_c", center)
	ai.MoveToPoint(ordered[0])
	ai.set_meta("bs_choice", "Search")
	if _debug: print(TAG + ai.name + " [" + ai.get_meta("bs_pers") + "] searching " + str(ordered.size()) + " spots")

func _next_search_point(ai):
	var points: Array = ai.get_meta("bs_search")
	points.pop_front()
	if points.is_empty():
		_give_up(ai)
		return
	ai.set_meta("bs_search", points)
	ai.MoveToPoint(points[0])

## Searched everywhere: forget the old position and go back to patrolling (vanilla cools down from there).
func _give_up(ai):
	ai.remove_meta("bs_search")
	ai.remove_meta("bs_lsp")
	ai.remove_meta("bs_tmem")
	ai.set_meta("bs_choice", "Lost him")
	if _debug: print(TAG + ai.name + " lost the target")
	ai.ChangeState("Combat")

## Creeping: at a sharp turn in the path, stop briefly and aim around the corner before going on.
func _check_corner(ai):
	var now := _now()
	if ai.has_meta("bs_corner"):
		if now >= float(ai.get_meta("bs_corner")["until"]): _end_corner(ai)
		return
	if !bool(ai.get_meta("bs_creep", false)) || now - float(ai.get_meta("bs_corner_t", -100.0)) < 0.2: return
	ai.set_meta("bs_corner_t", now)


	var path: PackedVector3Array = ai.agent.get_current_navigation_path()
	var i: int = ai.agent.get_current_navigation_path_index()
	if i + 1 >= path.size(): return
	var corner: Vector3 = path[i]
	if ai.global_position.distance_to(corner) > CORNER_NEAR: return
	if ai.has_meta("bs_corner_p") && Vector3(ai.get_meta("bs_corner_p")).distance_to(corner) < 1.0: return
	var into: Vector3 = corner - ai.global_position
	var out: Vector3 = path[i + 1] - corner
	into.y = 0.0
	out.y = 0.0
	if into.length() < 0.3 || out.length() < 0.5 || rad_to_deg(into.angle_to(out)) < CORNER_ANGLE: return


	ai.set_meta("bs_corner_p", corner)
	ai.set_meta("bs_corner", {"until": now + randf_range(CORNER_PAUSE.x, CORNER_PAUSE.y),
		"aim": corner + out.normalized() * 4.0 + Vector3.UP * 1.4})
	ai.speed = 0.4
	ai.set_meta("bs_choice", "Check corner")

func _end_corner(ai):
	if !ai.has_meta("bs_corner"): return
	ai.remove_meta("bs_corner")
	_update_gait(ai, true)

## An ally of the same faction nearby is already hunting or searching.
func _ally_hunting(ai) -> bool:
	for ally in _live_bots():
		if ally == ai || ally.variant.faction != ai.variant.faction: continue
		if ally.global_position.distance_to(ai.global_position) > SEARCH_SQUAD: continue
		if ally.currentState == ally.State.Hunt || ally.has_meta("bs_search"): return true
	return false

## A bot is about to move (flank, push, relocate): the nearest holding squadmate lays down fire to cover it.
func _request_cover_fire(mover):
	if !mover.sensor.PVisible && !_memory_valid(mover): return
	var best = null
	var bestDist := COVER_FIRE_RANGE
	for ally in _live_bots():
		if ally == mover || ally.variant.faction != mover.variant.faction || ally.reload: continue
		if ally.has_meta("bs_peek") && bool(ally.get_meta("bs_peek")["down"]): continue
		if !(ally.currentState == ally.State.Defend || ally.currentState == ally.State.Combat): continue
		if !ally.sensor.PVisible && !_memory_valid(ally): continue
		var d: float = ally.global_position.distance_to(mover.global_position)
		if d < bestDist:
			best = ally
			bestDist = d
	if best == null: return
	best.set_meta("bs_coverfire_until", _now() + COVER_FIRE_TIME)
	best.set_meta("bs_burst_next", 0.0)
	_bark(mover)
	if _debug: print(TAG + best.name + " covering " + mover.name)



## ------------------------------------------------------------------------------------------------ reflexes

## First sight of the target after a while: human reaction time before the first shot, accuracy ramp starts.
func _acquire(ai, now: float):
	ai.set_meta("bs_acq_t", now)
	var reaction := randf_range(REACTION.x, REACTION.y)
	if ai.State.find_key(ai.currentState) in CALM_STATES: reaction *= 1.3
	match str(ai.get_meta("bs_pers", "Normal")):
		"Rusher", "Berserker": reaction *= 0.8
		"Timid": reaction *= 1.2
	ai.set_meta("bs_ready_t", now + reaction)
	ai.fireTime = max(ai.fireTime, reaction)

## Squad-rate-limited combat callout through the existing combat voice.
func _bark(ai) -> bool:
	if ai.variant.silent || is_instance_valid(ai.activeVoice): return false
	var now := _now()
	if now - float(_lastBark.get(ai.variant.faction, -100.0)) < BARK_COOLDOWN: return false
	_lastBark[ai.variant.faction] = now
	ai.PlayCombat()
	return true



## ------------------------------------------------------------------------------------------------ morale

## Current morale, recovering after MORALE_CALM s without stress.
func _morale(ai, now: float) -> float:
	var m: float = ai.get_meta("bs_morale", 1.0)
	var calmSince: float = float(ai.get_meta("bs_stress_t", -100.0)) + MORALE_CALM
	var from: float = max(float(ai.get_meta("bs_morale_t", now)), calmSince)
	if now > from && m < 1.0:
		m = min(m + (now - from) * MORALE_RECOVER, 1.0)
		ai.set_meta("bs_morale", m)
		ai.set_meta("bs_morale_t", now)
	return m

func _morale_hit(ai, amount: float, now: float, reason: String):
	var m := _morale(ai, now) - amount
	ai.set_meta("bs_morale", m)
	ai.set_meta("bs_morale_t", now)
	ai.set_meta("bs_stress_t", now)
	var threshold: float = MORALE_BREAK.get(str(ai.get_meta("bs_pers", "Normal")), 0.3)
	if m < threshold && now - float(ai.get_meta("bs_break_t", -100.0)) > BREAK_TIME:
		# Retreat is the default. Flee only when Timid and clearly past it, or morale collapsed while badly hurt.
		var hp: float = ai.health / max(ai.variant.health, 1.0)
		var timid: bool = ai.get_meta("bs_pers", "") == "Timid"
		_break(ai, now, (timid && m < threshold - 0.1) || (m < threshold - 0.4 && hp < 0.5), reason)

## Losing: retreat to full cover farther from the threat, or flee outright. No firing on the way.
func _break(ai, now: float, flee: bool, reason: String):
	if ai.dead || !ai.active: return
	ai.set_meta("bs_break_t", now)
	_stop_heal(ai)
	var threat := _threat_position(ai)
	_bark(ai)


	if !flee:
		var cover: Dictionary = Cover.find(ai, threat, RETREAT_SEARCH, RETREAT_GAIN)
		if !cover["full"].is_empty():
			_run_to_cover(ai, cover["full"], "Hide")
			ai.set_meta("bs_choice", "Retreat")
			if _debug: print(TAG + ai.name + " [" + ai.get_meta("bs_pers") + "] breaks (" + reason + ") -> retreat")
			return
		# No cover farther back: take the nearest full cover rather than running.
		var near: Dictionary = Cover.find(ai, threat, COVER_SEARCH)
		if !near["full"].is_empty():
			_run_to_cover(ai, near["full"], "Hide")
			ai.set_meta("bs_choice", "Retreat")
			if _debug: print(TAG + ai.name + " [" + ai.get_meta("bs_pers") + "] breaks (" + reason + ") -> nearest cover")
			return


	var spot = _flee_point(ai, threat)
	if spot == null: return
	_run_to_cover(ai, {"pos": spot, "dist": ai.global_position.distance_to(spot), "full": true}, "Hide")
	ai.set_meta("bs_choice", "Flee")
	if _debug: print(TAG + ai.name + " [" + ai.get_meta("bs_pers") + "] breaks (" + reason + ") -> flee")

## A navmesh point FLEE_DIST away from the threat (tries straight away, then +-35 degrees), or null.
func _flee_point(ai, threat: Vector3):
	var away: Vector3 = ai.global_position - threat
	away.y = 0.0
	if away.length() < 0.1: away = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	away = away.normalized()
	for angle in [0.0, 35.0, -35.0]:
		var wanted: Vector3 = ai.global_position + away.rotated(Vector3.UP, deg_to_rad(angle)) * randf_range(FLEE_DIST.x, FLEE_DIST.y)
		var spot: Vector3 = NavigationServer3D.map_get_closest_point(ai.navmesh, wanted)
		if Vector2(spot.x - wanted.x, spot.z - wanted.z).length() < 6.0 && spot.distance_to(threat) > ai.global_position.distance_to(threat):
			return spot
	return null

## A squadmate died: nearby allies lose morale (more if close); one calls it out.
func _on_ai_death(_direction, _force):
	var dead = _lib._caller
	if !_affects(dead): return
	var now := _now()
	_end_loot(dead, false)
	for key in ["bs_home", "bs_kill_loot", "bs_visited"]: dead.remove_meta(key)
	if dead.container != null:
		for i in range(_corpses.size() - 1, -1, -1):
			if !is_instance_valid(_corpses[i]["c"]) || now - float(_corpses[i]["t"]) > CORPSE_FRESH: _corpses.remove_at(i)
		_corpses.append({"c": dead.container, "t": now, "faction": dead.variant.faction})
		# The shooter (an AI) loots its kill once things calm down.
		if dead.has_meta("bs_last_attacker"):
			var shooter = dead.get_meta("bs_last_attacker")
			var killer = shooter.owner if is_instance_valid(shooter) else null
			if killer != null && killer != dead && _affects(killer) && !killer.dead: killer.set_meta("bs_kill_loot", dead.container)
	dead.remove_meta("bs_last_attacker")
	var called := false
	for ally in _live_bots():
		if ally == dead || ally.variant.faction != dead.variant.faction: continue
		var dist: float = ally.global_position.distance_to(dead.global_position)
		if dist > ALLY_DEATH_RANGE: continue
		if !called: called = _bark(ally)
		if _debug: print(TAG + ally.name + " saw " + dead.name + " go down (" + str(snapped(dist, 0.1)) + " m)")
		_morale_hit(ally, 0.35 if dist < 15.0 else 0.2, now, "ally down")



## ------------------------------------------------------------------------------------------------ healing

func _try_heal(ai, now: float):
	if ai.has_meta("bs_heal_until"):
		if ai.sensor.PVisible:
			_stop_heal(ai)
		elif now >= float(ai.get_meta("bs_heal_until")):
			ai.health = min(ai.health + ai.variant.health * HEAL_AMOUNT, ai.variant.health)
			ai.set_meta("bs_meds", int(ai.get_meta("bs_meds", 0)) - 1)
			_stop_heal(ai)
			ai.set_meta("bs_choice", "Healed")
			if _debug: print(TAG + ai.name + " healed to " + str(int(ai.health)))
		return


	if int(ai.get_meta("bs_meds", 0)) <= 0 || ai.reload || ai.currentState != ai.State.Defend: return
	if ai.health / max(ai.variant.health, 1.0) >= HEAL_BELOW || ai.sensor.PVisible: return
	if now - float(ai.get_meta("bs_seen_t", -100.0)) < 4.0 || now - float(ai.get_meta("bs_hit", -100.0)) < 6.0: return
	if Brain.suppression(ai, now) > 0.1: return


	ai.set_meta("bs_heal_until", now + HEAL_TIME)
	ai.defendTimer = 0.0
	ai.defendCycle = max(ai.defendCycle, HEAL_TIME + 1.0)
	ai.ResetAnimator()
	ai.animator["parameters/conditions/Hunt"] = true
	_crouch_still(ai)
	ai.set_meta("bs_choice", "Heal")

## The crouched (Hunt) animation stays a walk unless its direction blend is zeroed (vanilla only does that for
## Ambush/Guard), so a stationary crouch in Defend would march in place.
func _crouch_still(ai):
	ai.animator["parameters/Hunt/P_Direction/blend_position"] = 0.0
	ai.animator["parameters/Hunt/R_Direction/blend_position"] = 0.0

func _stop_heal(ai):
	if !ai.has_meta("bs_heal_until"): return
	ai.remove_meta("bs_heal_until")
	ai.set_meta("bs_pose_t", _now())
	if ai.currentState == ai.State.Defend:
		ai.ResetAnimator()
		ai.animator["parameters/conditions/Defend"] = true



## ------------------------------------------------------------------------------------------------ grenade evasion

func _on_node_added(node):
	if node is RigidBody3D && "fuseTime" in node && "frag" in node && !_grenades.has(node): _grenades.append(node)
	elif node is LootContainer: _containers.append(node)



## ------------------------------------------------------------------------------------------------ scavenging

## Vanilla looting never fires: the bots' $Tools/Loot Area3D has no collision mask and containers have no areas, so
## GetLootPoint() never finds anything. This replaces the search with our own: calm bots pick a nearby container
## (or a fresh corpse) that still has items, walk there in Wander, and vanilla's Wander -> Loot path does the rest.
## Hiders/Rats loot their house and go back into ambush the moment something approaches.
func _loot_tick(ai, now: float):
	if ai.has_meta("bs_loot"):
		var task: Dictionary = ai.get_meta("bs_loot")
		# Stuck or interrupted (state changed without us noticing): give up after a while.
		if now - float(task["t"]) > LOOT_TASK_TIMEOUT: _end_loot(ai, false)
		return
	if now < float(ai.get_meta("bs_loot_next", 0.0)): return
	ai.set_meta("bs_loot_next", now + randf_range(LOOT_CHECK.x, LOOT_CHECK.y))


	# Nomads never loot (houses, bodies or their own kills).
	if ai.variant.faction == AIData.Faction.Nomad: return
	if !_calm(ai) || ai.reload || ai.container == null || ai.container.loot.size() >= LOOT_CAP: return
	var states = ai.State
	var state: int = ai.currentState
	var hider: bool = state == states.Ambush
	if !(state == states.Wander || state == states.Guard || state == states.Patrol || state == states.Idle || hider): return
	var searching: bool = now < float(ai.get_meta("bs_search_until", 0.0))
	var will: float = LOOT_WILL.get(ai.variant.faction, 0.2)
	if ai.get_meta("bs_pers", "") == "Rat" || hider: will = max(will, 0.6) * 1.4
	if ai.has_meta("bs_kill_loot") || searching: will = 1.0
	if randf() > will: return


	var reach: float = LOOT_RANGE
	if hider || ai.has_meta("bs_home"): reach = HOUSE_RANGE
	if searching: reach = SEARCH_ON
	var target = _pick_loot(ai, now, reach)
	if target == null: return
	var point = _approach(ai, target)
	if point == null:
		_visited(ai)[target.get_instance_id()] = now
		return
	_start_loot(ai, target, hider, now, point)

## Nearest lootable target: the bot's own kill first, then fresh corpses, then map containers.
func _pick_loot(ai, now: float, reach: float):
	var origin: Vector3 = ai.global_position
	var visited := _visited(ai)
	var best = null
	var bestDist := reach


	if ai.has_meta("bs_kill_loot"):
		var kill = ai.get_meta("bs_kill_loot")
		ai.remove_meta("bs_kill_loot")
		if is_instance_valid(kill) && kill.is_inside_tree() && kill.global_position.distance_to(origin) < CORPSE_RANGE: return kill


	for entry in _corpses:
		var c = entry["c"]
		if !is_instance_valid(c) || !c.is_inside_tree() || now - float(entry["t"]) > CORPSE_FRESH || _reserved(c, ai, now): continue
		if now - float(visited.get(c.get_instance_id(), -INF)) < VISIT_FORGET: continue
		# Bandits strip anyone; the others only loot enemies.
		if entry["faction"] == ai.variant.faction && ai.variant.faction != AIData.Faction.Bandit: continue
		var d: float = c.global_position.distance_to(origin)
		if d < min(bestDist, CORPSE_RANGE):
			best = c
			bestDist = d
	if best != null: return best


	for c in _containers:
		# Checked whether or not it holds anything: the bot can't know until it looks.
		if !_is_map_container(c) || _reserved(c, ai, now): continue
		if now - float(visited.get(c.get_instance_id(), -INF)) < VISIT_FORGET: continue
		var d: float = c.global_position.distance_to(origin)
		if d < bestDist:
			best = c
			bestDist = d
	return best

## Where to stand to loot `c`: a walkable spot about APPROACH_DIST from it, on its side, with a clear line from chest
## height to it (the nearest navmesh point can be in the next room, behind the wall). Tries the side facing the AI
## first, then the others. null = no such spot (treated as unreachable).
func _approach(ai, c):
	var base: Vector3 = c.global_position
	var center: Vector3 = base + Vector3.UP * 0.5
	var toward: Vector3 = ai.global_position - base
	toward.y = 0.0
	toward = toward.normalized() if toward.length() > 0.01 else Vector3.FORWARD
	var world = ai.get_world_3d() if ai.is_inside_tree() else null
	if world == null: return null
	var space = world.direct_space_state
	for angle in [0.0, 90.0, -90.0, 180.0]:
		var want: Vector3 = base + toward.rotated(Vector3.UP, deg_to_rad(angle)) * APPROACH_DIST
		var spot: Vector3 = NavigationServer3D.map_get_closest_point(ai.navmesh, want)
		if Vector2(spot.x - want.x, spot.z - want.z).length() > 0.7 || abs(spot.y - base.y) > 1.5: continue
		var query := PhysicsRayQueryParameters3D.create(spot + Vector3.UP * 1.2, center, ai.sensor.obstruction)
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty() || _part_of(hit["collider"], c): return spot
	return null

## The ray hit the container itself (or the object it sits in), not something next to it like a wall.
func _part_of(collider, c) -> bool:
	if !(collider is Node): return false
	return collider == c || c.is_ancestor_of(collider) || collider.is_ancestor_of(c)

func _start_loot(ai, target, hider: bool, now: float, point: Vector3):
	target.set_meta("bs_reserved", [ai.get_instance_id(), now])
	if hider && is_instance_valid(ai.currentPoint): ai.set_meta("bs_home", ai.currentPoint)
	if ai.currentState != ai.State.Wander:
		# Our own ChangeState hook must not treat this as a normal Wander (Rats would run off to hide).
		ai.set_meta("bs_loot_starting", true)
		ai.ChangeState("Wander")
		ai.remove_meta("bs_loot_starting")
		if ai.currentState != ai.State.Wander:
			ai.currentState = ai.State.Wander
			ai.ResetAnimator()
			ai.animator["parameters/conditions/Wander"] = true
			ai.speed = 1.0
			ai.agent.target_desired_distance = 1.0
	ai.set_meta("bs_loot", {"target": target, "left": randi_range(LOOT_PER_VISIT.x, LOOT_PER_VISIT.y), "t": now})
	ai.looting = true
	ai.lootTarget = target
	ai.currentPoint = target
	ai.MoveToPoint(point)
	ai.set_meta("bs_choice", "Loot body" if _is_corpse(target) else "Loot")
	if _debug: print(TAG + ai.name + " [" + str(ai.get_meta("bs_pers", "?")) + "] going to loot " + str(target.name) + " (" + str(snapped(ai.global_position.distance_to(target.global_position), 0.1)) + " m)")

## Vanilla Loot() always ends with ChangeState("Wander"), even if a fight started meanwhile. Same steps, but it only
## finishes (and only goes back to wandering) if the bot is still looting.
func _on_loot():
	var ai = _lib._caller
	if !_affects(ai): return
	_lib.skip_super()
	_do_loot(ai)

func _do_loot(ai):
	ai.animator["parameters/Wander/P_Loot/request"] = AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
	ai.animator["parameters/Wander/R_Loot/request"] = AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
	await get_tree().create_timer(0.5, false).timeout
	if !_still_looting(ai): return


	# Open once, then grab up to the visit's item count one after another (or find nothing and move on).
	var target = ai.lootTarget
	var taken := 0
	if is_instance_valid(target) && target is LootContainer:
		ai.PlayLoot()
		var wanted: int = int(ai.get_meta("bs_loot")["left"]) if ai.has_meta("bs_loot") else 1
		for i in wanted:
			await get_tree().create_timer(GRAB_TIME, false).timeout
			if !_still_looting(ai) || ai.container.loot.size() >= LOOT_CAP || !_has_loot(target): break
			var item = target.AILoot()
			if item == null: break
			ai.container.loot.append(item)
			ai.PlayPickup()
			taken += 1
			if _debug: print(TAG + ai.name + " looted " + str(item.itemData.name) + " from " + str(target.name))
	await get_tree().create_timer(0.6 if taken == 0 else 0.8, false).timeout
	if !_still_looting(ai): return
	if taken == 0 && _debug: print(TAG + ai.name + " found nothing in " + str(target.name if is_instance_valid(target) else "?"))
	ai.looting = false
	ai.ChangeState("Wander")

func _still_looting(ai) -> bool:
	if !is_instance_valid(ai) || ai.dead: return false
	if ai.currentState != ai.State.Loot:
		ai.looting = false
		return false
	return true

## Called from _on_change_state("Wander") after a visit: keep searching nearby, go home (hiders), or finish.
func _continue_loot(ai) -> bool:
	if !ai.has_meta("bs_loot"): return false
	_end_loot(ai, true)
	if _search_on(ai): return true
	# Hiders go back to their hide point and wait there.
	if ai.has_meta("bs_home") && is_instance_valid(ai.get_meta("bs_home")):
		_go_home(ai)
		return true
	return false

## More unchecked containers close by (same room/house): keep searching them before moving on.
## Runs right after vanilla's ChangeState("Wander") picked a random waypoint, before the AI turns toward it: walking
## straight on to the nearest unchecked container avoids the turn-to-leave-then-turn-back.
func _search_on(ai) -> bool:
	var now := _now()
	var visited := _visited(ai)
	var best = null
	var bestDist := SEARCH_ON
	for c in _containers:
		if !_is_map_container(c) || _reserved(c, ai, now): continue
		if now - float(visited.get(c.get_instance_id(), -INF)) < VISIT_FORGET: continue
		var d: float = c.global_position.distance_to(ai.global_position)
		if d < bestDist:
			best = c
			bestDist = d
	if best == null: return false
	var point = _approach(ai, best)
	if point == null:
		visited[best.get_instance_id()] = now
		return false
	ai.set_meta("bs_search_until", now + SEARCH_ON_TIME)
	_start_loot(ai, best, false, now, point)
	return true

func _end_loot(ai, done: bool):
	if !ai.has_meta("bs_loot"): return
	var target = ai.get_meta("bs_loot")["target"]
	ai.remove_meta("bs_loot")
	ai.looting = false
	if is_instance_valid(target):
		target.remove_meta("bs_reserved")
		_visited(ai)[target.get_instance_id()] = _now()
	if !done && _debug: print(TAG + ai.name + " stopped looting")

## Walk back to the hide point (Hide state; _on_hide puts the bot in Ambush on arrival).
func _go_home(ai):
	var home = ai.get_meta("bs_home")
	ai.currentPoint = home
	ai.set_meta("bs_hidept", home)
	ai.set_meta("bs_homerun", true)
	ai.currentState = ai.State.Hide
	ai.ResetAnimator()
	ai.animator["parameters/conditions/Wander"] = true
	ai.speed = 1.0
	ai.rotationSpeed = 5.0
	ai.agent.target_desired_distance = 0.5
	ai.MoveToPoint(home.global_position)
	ai.set_meta("bs_choice", "Back to ambush")

## A hider/Rat that senses something while out looting: drop it and get back into ambush (not hunt).
func _ambush_now(ai):
	_end_loot(ai, false)
	if ai.has_meta("bs_home") && is_instance_valid(ai.get_meta("bs_home")) \
			&& ai.global_position.distance_to(ai.get_meta("bs_home").global_position) < 20.0:
		_go_home(ai)
	else:
		if !is_instance_valid(ai.currentPoint): return
		ai.ChangeState("Ambush")
	ai.set_meta("bs_choice", "Ambush!")
	if _debug: print(TAG + ai.name + " senses something -> ambush")

func _calm(ai) -> bool:
	var sensor = ai.sensor
	return !sensor.hot && !sensor.PVisible && float(sensor.get_meta("bs_aw", 0.0)) < 0.3 && !is_instance_valid(sensor.threatPriority)

func _has_loot(c) -> bool:
	if !is_instance_valid(c): return false
	return !(c.storage if c.storaged else c.loot).is_empty()

func _is_corpse(c) -> bool:
	return c.owner != null && "variant" in c.owner

func _is_map_container(c) -> bool:
	return is_instance_valid(c) && c.is_inside_tree() && c.visible && c.process_mode != Node.PROCESS_MODE_DISABLED \
		&& !c.locked && !c.furniture && !_is_corpse(c)

func _reserved(c, ai, now: float) -> bool:
	if !c.has_meta("bs_reserved"): return false
	var r: Array = c.get_meta("bs_reserved")
	return int(r[0]) != ai.get_instance_id() && now - float(r[1]) < RESERVE_TIME

func _visited(ai) -> Dictionary:
	if !ai.has_meta("bs_visited"): ai.set_meta("bs_visited", {})
	return ai.get_meta("bs_visited")



func _scan_grenades(now: float):
	for i in range(_grenades.size() - 1, -1, -1):
		var nade = _grenades[i]
		if !is_instance_valid(nade) || !nade.is_inside_tree():
			_grenades.remove_at(i)
			continue
		# AI grenades sit disabled in the thrower's hand until released.
		if !nade.frag || nade.process_mode == Node.PROCESS_MODE_DISABLED: continue


		var pos: Vector3 = nade.global_position
		var noticed: bool = nade.has_meta("bs_noticed")
		for ai in _live_bots():
			if now < float(ai.get_meta("bs_evade_until", -100.0)) || ai.has_meta("bs_nade_react"): continue
			var dist: float = ai.global_position.distance_to(pos)
			if dist > NADE_DANGER: continue
			# Still flying fast away from this bot (e.g. its own throw): judge it when it lands.
			var vel: Vector3 = nade.linear_velocity
			if vel.length() > 6.0 && vel.dot(pos - ai.global_position) > 0.0: continue
			var sees: bool = dist < 4.0 || (dist < NADE_NOTICE && _clear(ai.sensor, ai.sensor.global_position, pos + Vector3.UP * 0.2))
			if !sees && !noticed: continue
			if !noticed:
				nade.set_meta("bs_noticed", true)
				noticed = true
			# Timid sometimes freezes.
			if ai.get_meta("bs_pers", "") == "Timid" && randf() < 0.15: continue
			ai.set_meta("bs_nade_react", true)
			get_tree().create_timer(randf_range(NADE_REACT.x, NADE_REACT.y), false).timeout.connect(_evade.bind(ai, nade))

func _evade(ai, nade):
	if !is_instance_valid(ai): return
	ai.remove_meta("bs_nade_react")
	if ai.dead || !ai.active || !is_instance_valid(nade): return


	var from: Vector3 = nade.global_position
	var away: Vector3 = ai.global_position - from
	away.y = 0.0
	if away.length() < 0.1: away = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	away = away.normalized()
	for angle in [0.0, 50.0, -50.0]:
		var wanted: Vector3 = from + away.rotated(Vector3.UP, deg_to_rad(angle)) * NADE_EVADE_DIST
		var spot: Vector3 = NavigationServer3D.map_get_closest_point(ai.navmesh, wanted)
		if spot.distance_to(from) < NADE_EVADE_DIST * 0.7: continue
		_stop_heal(ai)
		_run_to_cover(ai, {"pos": spot, "dist": ai.global_position.distance_to(spot), "full": false}, "Cover")
		ai.set_meta("bs_evade_until", _now() + NADE_EVADE_TIME)
		ai.set_meta("bs_choice", "Grenade!")
		_bark(ai)
		if _debug: print(TAG + ai.name + " evading grenade (" + str(snapped(ai.global_position.distance_to(from), 0.1)) + " m)")
		return



## ------------------------------------------------------------------------------------------------ tactical tick

func _physics_process(_delta):
	# Map transitions free the old map's AI, containers and bodies: do nothing until the new map is up.
	if gameData.transition || get_tree().current_scene == null: return
	var now := _now()
	# F9 overlay: bots that spawned (or came back from the pool) after it was switched on get it too.
	if _debug && now - _debugT > 0.5:
		_debugT = now
		for ai in _live_bots():
			if !ai.status.visible:
				ai.AISpawner.debug = true
				ai.Debug(true)
	if now - _nadeScanT >= NADE_SCAN && !_grenades.is_empty():
		_nadeScanT = now
		_scan_grenades(now)


	var bots := _live_bots()
	if bots.is_empty(): return
	for i in min(TICK_BOTS_PER_FRAME, bots.size()):
		_tickIndex = (_tickIndex + 1) % bots.size()
		var ai = bots[_tickIndex]
		_morale(ai, now)
		_try_heal(ai, now)
		if _builtinLoot: _loot_tick(ai, now)



## Performance counters, logged once a minute: [calls, total us, max us] per category.
## Diagnostics: compare what blocks a bot's vision rays with what blocks its bullets (layers 1-32 that are set).
func _log_masks():
	var nearest = null
	for ai in _live_bots():
		if nearest == null || ai.global_position.distance_to(gameData.playerPosition) < nearest.global_position.distance_to(gameData.playerPosition):
			nearest = ai
	if nearest == null: return
	var fireMask: int = nearest.fire.collision_mask if "fire" in nearest && nearest.fire is RayCast3D else -1
	print(TAG + "masks (" + nearest.name + "): vision obstruction layers " + str(_layers(int(nearest.sensor.obstruction)))
		+ " | bullet ray layers " + str(_layers(fireMask)))

func _layers(mask: int) -> Array:
	var on := []
	if mask < 0: return on
	for i in 32:
		if mask & (1 << i): on.append(i + 1)
	return on

func _perf_add(key: String, usec: int):
	var entry: Array = _perf.get(key, [0, 0, 0])
	entry[0] += 1
	entry[1] += usec
	entry[2] = max(entry[2], usec)
	_perf[key] = entry

func _process(delta):
	_perfTimer += delta
	if _perfTimer < PERF_INTERVAL: return
	_perfTimer = 0.0


	var line := TAG + "perf/" + str(int(PERF_INTERVAL)) + "s bots=" + str(_live_bots().size())
	for key in ["tick", "los", "decision", "cover"]:
		var entry: Array = _perf.get(key, [0, 0, 0])
		var avg: float = float(entry[1]) / max(entry[0], 1)
		line += " | " + key + " n=" + str(entry[0]) + " avg=" + str(int(avg)) + "us max=" + str(entry[2]) + "us"
	line += " | rays=" + str(_perf.get("rays", 0)) + " snaps=" + str(_perf.get("snaps", 0))
	line += " | fps=" + str(Engine.get_frames_per_second()) + " physics=" + str(snapped(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01)) + "ms"
	print(line)
	_perf.clear()

func _register(ai):
	_bots[ai.get_instance_id()] = ai
	if ai.has_meta("bs_pers"): return
	# Bots spawned together would otherwise all cast their LOS rays on the same frame.
	ai.sensor.raycastTimer = randf() * ai.sensor.raycastCycle

	var personality: String = Brain.pick_personality(ai)
	ai.set_meta("bs_pers", personality)
	ai.set_meta("bs_nades", Brain.starting_grenades(personality))
	ai.set_meta("bs_meds", Brain.starting_meds(ai))
	if _debug: print(TAG + ai.name + " personality " + personality)

## False for bots that treat the player as friendly (Nomads with good reputation); they ignore
## everything the player does.
func _player_hostile(ai) -> bool:
	if Engine.get_meta("rtv_ai_ignore_player", false): return false
	return ai.sensor.PlayerValid()

func _affects(ai) -> bool:
	if ai == null || !("variant" in ai) || ai.variant == null: return false
	return ai.variant.faction in affectedFactions

func _live_bots() -> Array:
	var live := []
	for id in _bots.keys():
		var ai = _bots[id]
		if !is_instance_valid(ai) || ai.dead:
			_bots.erase(id)
		# Not in the world = being torn down by a map change: never touch it.
		elif ai.active && ai.is_inside_tree():
			live.append(ai)
	return live

func _clear(sensor, from: Vector3, to: Vector3) -> bool:
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = sensor.obstruction
	return sensor.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
