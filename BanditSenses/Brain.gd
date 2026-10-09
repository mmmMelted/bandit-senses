extends RefCounted
## Brain: utility-scored combat decisions and per-bot personalities (SAIN-inspired, clean-room).
## Every option gets a score from the bot's situation, scaled by its personality; the best one wins.


const gameData = preload("res://Resources/GameData.tres")


const OPTIONS := ["Combat", "Defend", "Cover", "Hide", "Vantage", "Hunt", "Attack", "Grenade", "Flank"]


## How willing each personality is to flank while allies hold the target's attention.
const FLANK_WILL := {"Normal": 1.0, "Rat": 0.15, "Timid": 0.25, "Rusher": 1.3, "Berserker": 0.6}
const SUPPRESS_DECAY := 0.2


const PERSONALITIES := {
	"Normal":    {"Combat": 1.0, "Defend": 1.0, "Cover": 1.0, "Hide": 1.0, "Vantage": 1.0, "Hunt": 1.0, "Attack": 1.0, "Grenade": 1.0},
	"Rat":       {"Combat": 0.7, "Defend": 1.3, "Cover": 1.3, "Hide": 1.6, "Vantage": 1.3, "Hunt": 0.5, "Attack": 0.3, "Grenade": 0.8},
	"Timid":     {"Combat": 0.9, "Defend": 1.1, "Cover": 1.5, "Hide": 1.4, "Vantage": 0.8, "Hunt": 0.6, "Attack": 0.4, "Grenade": 0.7},
	"Rusher":    {"Combat": 1.0, "Defend": 0.7, "Cover": 0.7, "Hide": 0.4, "Vantage": 0.6, "Hunt": 1.0, "Attack": 1.7, "Grenade": 1.3},
	"Berserker": {"Combat": 0.8, "Defend": 0.4, "Cover": 0.3, "Hide": 0.1, "Vantage": 0.3, "Hunt": 0.8, "Attack": 2.2, "Grenade": 1.0},
}


## Faction temperament on top of personality. Bandits are undisciplined (they chase and push a little more, dig in a
## little less) but still want to live; real aggression comes from having the advantage (see advantage()).
const FACTION_STYLE := {
	AIData.Faction.Bandit: {"Attack": 1.1, "Hunt": 1.05, "Grenade": 1.1, "Defend": 0.95, "Cover": 0.95, "Hide": 0.85, "Vantage": 0.85},
}


## How much being wounded discourages pushing (1 = normal).
const WOUND_FEAR := {"Normal": 1.0, "Rat": 1.2, "Timid": 1.4, "Rusher": 0.6, "Berserker": 0.1}
## Personalities that always sprint when pushing; everyone else (Rushers too) sprints only at a vulnerable target.
const ALWAYS_SPRINT := ["Berserker"]


## Farthest cover a bot will run to while the threat can see it; beyond this it stands and fights.
const COVER_SPRINT_MAX := 22.0
const HIDE_SPRINT_MAX := 22.0
## After settling into a firing position, don't pick another one for this long (unless hurt): fight from it.
const COVER_SETTLE := 8.0
## Hiding in full cover but saw the target within this long: go back to a firing position.
const REENGAGE_MEMORY := 25.0


const HURT_MEMORY := 5.0
## Keep fighting from where you are rather than dithering (applies to Defend while the target is visible).
const HOLD_BONUS := 0.1
const NOISE := 0.08



static func pick_personality(ai) -> String:
	var faction = ai.variant.faction
	# Bandits: undisciplined, a few more rushers; berserkers rare so they stand out.
	var w := {"Normal": 47.0, "Rat": 12.0, "Timid": 12.0, "Rusher": 24.0, "Berserker": 5.0}
	if faction == AIData.Faction.Guard:
		w = {"Normal": 45.0, "Rat": 12.0, "Timid": 8.0, "Rusher": 25.0, "Berserker": 3.0}
	elif faction == AIData.Faction.Military:
		w = {"Normal": 50.0, "Rat": 0.0, "Timid": 5.0, "Rusher": 35.0, "Berserker": 8.0}
	elif faction == AIData.Faction.Nomad:
		w = {"Normal": 55.0, "Rat": 0.0, "Timid": 20.0, "Rusher": 15.0, "Berserker": 3.0}
	var action: String = ai.weaponData.weaponAction if ai.weaponData else ""

	if ai.weaponType == "Pistol":
		w["Timid"] += 15.0
		w["Rat"] += 5.0
		w["Rusher"] -= 10.0
	if ai.optic:
		w["Rat"] += 15.0
		w["Berserker"] -= 3.0
	if action == "Bolt":
		w["Rat"] += 20.0
		w["Rusher"] -= 10.0
	elif action == "Pump":
		w["Rusher"] += 15.0
	if ai.backpack:
		w["Rat"] += 5.0
	if faction == AIData.Faction.Military || faction == AIData.Faction.Nomad:
		w["Rat"] = 0.0


	var total := 0.0
	for k in w: total += max(w[k], 0.0)
	var roll := randf() * total
	for k in w:
		roll -= max(w[k], 0.0)
		if roll <= 0.0: return k
	return "Normal"

static func starting_grenades(personality: String) -> int:
	match personality:
		"Rusher": return randi_range(1, 3)
		"Berserker", "Normal": return randi_range(1, 2)
		"Rat": return 1
		_: return randi_range(0, 1)



## Medical items a bot carries for healing behind cover.
static func starting_meds(ai) -> int:
	match ai.variant.faction:
		AIData.Faction.Military: return randi_range(1, 2)
		AIData.Faction.Guard: return 1
		_: return randi_range(0, 1)



## Current suppression 0..1, decaying since the last near miss.
static func suppression(ai, now: float) -> float:
	var level: float = ai.get_meta("bs_sup", 0.0)
	if level <= 0.0: return 0.0
	return max(level - (now - float(ai.get_meta("bs_sup_t", now))) * SUPPRESS_DECAY, 0.0)

## ctx: {"cover": Cover.find() result, "allies": engaged allies nearby, "flanker": an ally is already
## flanking, "flank": navmesh flank point or null, "nade": grenade possible, "memory": valid memory of the player
## (Main checked target, age and hot), "seen_age": seconds since the bot last actually saw the target,
## "squad_nade_t": when this squad last threw a grenade}.
static func decide(ai, now: float, ctx: Dictionary) -> String:
	var cover: Dictionary = ctx.get("cover", {})
	var sensor = ai.sensor
	var personality: String = ai.get_meta("bs_pers", "Normal")
	var weights: Dictionary = PERSONALITIES[personality]
	var temper: Dictionary = FACTION_STYLE.get(ai.variant.faction, {})
	var state: String = ai.State.find_key(ai.currentState)


	var hp: float = clamp(ai.health / max(ai.variant.health, 1.0), 0.0, 1.0)
	var ammo := 1.0
	if ai.weaponData.magazineSize > 0:
		ammo = float(ai.weaponSlot.amount) / ai.weaponData.magazineSize
	var vis: bool = sensor.PVisible
	var hurt: bool = now - float(ai.get_meta("bs_hit", -100.0)) < HURT_MEMORY
	var hasMemory: bool = ctx.get("memory", false)
	var seenAge: float = ctx.get("seen_age", 999.0)
	var sup := suppression(ai, now)


	var dist: float = sensor.PDistance
	if !vis && hasMemory: dist = ctx.get("threat_dist", dist)


	var targetWeak := target_weak(ai, now)
	var edge := advantage(ai, now, ctx)
	# Only move to cover when there is something to take cover from.
	var fireCover: Dictionary = cover.get("fire", {})
	var fullCover: Dictionary = cover.get("full", {})
	var broken: bool = ctx.get("broken", false)
	# Hiding in full cover with a recent contact: worth moving back to a spot we can shoot from.
	var reengage: bool = !fullCover.is_empty() && fullCover["dist"] < 1.5 && hasMemory && seenAge < REENGAGE_MEMORY && !broken
	var threatened: bool = vis || hurt || sup > 0.2 || seenAge < 3.0 || reengage
	var inFirePos: bool = !fireCover.is_empty() && fireCover["dist"] < 1.5
	var settled: bool = now - float(ai.get_meta("bs_settled", -100.0)) < COVER_SETTLE && !hurt
	var coverOk: bool = !fireCover.is_empty() && !inFirePos && !settled && threatened \
		&& (!vis || fireCover["dist"] <= COVER_SPRINT_MAX)
	var hideOk: bool = !fullCover.is_empty() && (!vis || fullCover["dist"] <= HIDE_SPRINT_MAX)
	var vantage := count_points(ai, "AI_PP", 0.9)


	var s := {}
	# Combat = vanilla's strafing walk to random waypoints: a fallback, not a plan.
	s["Combat"] = 0.25 if vis else 0.3
	s["Defend"] = (0.4 + (0.15 if dist > 40.0 else 0.0)) if vis else 0.1
	if vis && state == "Defend": s["Defend"] += HOLD_BONUS
	# Already standing in a firing position: fight from it.
	if inFirePos && (vis || seenAge < 6.0): s["Defend"] += 0.35


	# Cover = run to a firing position (protected but can shoot). In the open under fire this beats standing there.
	s["Cover"] = 0.0
	if coverOk:
		s["Cover"] = 0.45 + (1.0 - hp) * 0.3 + (0.2 if hurt else 0.0) + (0.15 if vis else 0.0) \
			+ (0.1 if fireCover["dist"] < 8.0 else 0.0) + (0.15 if reengage else 0.0)
	# Hide = full cover to break contact: badly hurt, out of ammo, or pinned.
	s["Hide"] = 0.0
	if hideOk:
		s["Hide"] = (1.0 - hp) * 0.7 + (0.2 if hurt else 0.0) + (0.25 if ammo < 0.2 else 0.0) + (0.3 if sup > 0.6 else 0.0)


	# Flank while allies keep the target busy; one flanker per group.
	s["Flank"] = 0.0
	var allies: int = ctx.get("allies", 0)
	if allies > 0 && ctx.get("flank") != null && !ctx.get("flanker", false) && hp > 0.5 && sup < 0.4 && hasMemory:
		s["Flank"] = (0.35 + min(allies, 3) * 0.1) * FLANK_WILL[personality]


	# Hurt with no reachable cover: stand and return fire instead of turning your back.
	if hurt && vis && !coverOk:
		s["Defend"] += 0.3
		s["Combat"] += 0.15
	s["Vantage"] = 0.0 if vantage == 0 else 0.25 + (0.2 if dist > 40.0 else 0.0)
	s["Hunt"] = 0.2 if vis else (0.55 if hasMemory else 0.3)
	# Just lost sight from a firing position: watch the angle a few seconds before going to look.
	if !vis && inFirePos && seenAge < 6.0: s["Hunt"] -= 0.2
	# A squadmate is already going to look: hold the angle and cover them instead of everyone walking in.
	if !vis && hasMemory && ctx.get("ally_hunting", false):
		s["Hunt"] -= 0.25
		s["Defend"] += 0.2
	# Push when holding the advantage (target weak, outnumbered, just flushed); otherwise pushing is a gamble.
	s["Attack"] = 0.0
	if vis || hasMemory:
		s["Attack"] = (0.2 if vis else 0.3) + max(0.0, 1.0 - dist / 60.0) * 0.3 + edge \
			- (1.0 - hp) * 0.5 * WOUND_FEAR[personality] - (0.3 if ammo < 0.3 else 0.0)


	# Suppressed: get into cover, stop pushing, don't stand in the open.
	if sup > 0.0:
		var fear: float = WOUND_FEAR[personality]
		s["Cover"] += sup * 0.6 if coverOk else 0.0
		s["Hide"] += sup * 0.3 if hideOk else 0.0
		s["Attack"] -= sup * 0.6 * fear
		s["Hunt"] -= sup * 0.3 * fear
		s["Vantage"] -= sup * 0.3


	# Grenades flush a target that went out of sight at a known spot; the longer it stays hidden, the likelier.
	# ctx["nade"] = Main checked count, range, cooldowns, indoors and a clear throw.
	s["Grenade"] = 0.0
	if ctx.get("nade", false):
		var age: float = ctx.get("memory_age", 999.0)
		if !vis && hasMemory && age < 20.0:
			s["Grenade"] = 0.6 + (0.2 if age > 3.0 else 0.0) + (0.1 if targetWeak else 0.0)
		elif vis && dist > 15.0:
			s["Grenade"] = 0.35 + (0.1 if allies > 0 else 0.0)


	# Morale: shaken bots push less; broken ones (retreating/fleeing recently) don't push, flank or chase at all.
	var morale: float = ctx.get("morale", 1.0)
	s["Attack"] *= clamp(morale + 0.3, 0.3, 1.0)
	if broken:
		s["Attack"] *= 0.15
		s["Flank"] = 0.0
		s["Hunt"] *= 0.3
		s["Grenade"] *= 0.5
		s["Hide"] *= 1.5
		s["Cover"] *= 1.2


	var best := "Combat"
	var bestScore := -INF
	for option in OPTIONS:
		var score: float = s[option] * weights.get(option, 1.0) * temper.get(option, 1.0)
		if score <= 0.0: continue
		score += randf_range(-NOISE, NOISE)
		if score > bestScore:
			bestScore = score
			best = option


	return best



## The player is vulnerable: this bot heard or saw a noisy action (reload, heal, eat...) or sees them hurt.
static func target_weak(ai, now: float) -> bool:
	var sensor = ai.sensor
	if !is_instance_valid(sensor.priority) || !sensor.priority.is_in_group("Player"): return false
	if now < float(ai.get_meta("bs_vuln", -100.0)): return true
	if !sensor.PVisible: return false
	return (gameData.health < 40.0 || gameData.isReloading || gameData.isOccupied
		|| gameData.isInserting || gameData.isChecking)

## How much the situation favours pushing: target weak (reloading, healing, hurt), we outnumber it, or this squad
## just flushed it with a grenade.
static func advantage(ai, now: float, ctx: Dictionary) -> float:
	var edge := 0.0
	if target_weak(ai, now): edge += 0.6
	var allies: int = ctx.get("allies", 0)
	if allies >= 1: edge += 0.1
	if allies >= 2: edge += 0.1
	if now - float(ctx.get("squad_nade_t", -100.0)) < 6.0: edge += 0.3
	return edge

static func push_sprints(ai, now: float) -> bool:
	return ai.get_meta("bs_pers", "Normal") in ALWAYS_SPRINT || target_weak(ai, now)



static func count_points(ai, group: String, minFacing: float) -> int:
	var threat: Vector3 = ai.sensor.PLocation
	var count := 0

	for point in ai.points:
		if !is_instance_valid(point) || !point.is_in_group(group): continue

		var toAI: float = ai.global_position.distance_to(point.global_position)
		if toAI >= 40.0 || toAI >= point.global_position.distance_to(threat): continue


		if group == "AI_CP" || group == "AI_PP":
			var facing: float = (threat - point.global_position).normalized().dot(point.global_transform.basis.z)
			if group == "AI_CP" && facing >= minFacing: continue
			if group == "AI_PP" && facing <= minFacing: continue

		count += 1

	return count
