extends RefCounted
## Dynamic cover (SAIN-inspired, clean-room), from the map's cover and hide points, a ring of navmesh samples around
## the bot, and the bot's own position.
## - "fire": a firing position. Something within COVER_NEAR of the spot blocks the threat's line of sight at crouch
##   height, but standing height sees the threat, so the bot is protected and can still shoot.
## - "full": blocked at standing height too. Used to hide (hurt, reloading, breaking contact), not to fight from.
## Candidates are checked nearest-first; the search stops once both kinds are found or the snap/ray budget is spent.


const RADII := [3.0, 6.0, 10.0, 16.0, 24.0, 32.0, 40.0]
const DIRECTIONS := 12
const CROUCH_HEIGHT := 1.0
const STAND_HEIGHT := 1.6
const MAX_NAV_SNAP := 1.5
const MIN_THREAT_DIST := 6.0
## The blocking obstacle must be this close to the spot to count as the spot's cover.
const COVER_NEAR := 3.5
## Crouch-height checks only need to reach past the nearby obstacle; standing LOS checks look this far.
const CHECK_LENGTH := 30.0
const SIGHT_LENGTH := 90.0
const MAX_RAYS := 40
const MAX_SNAPS := 4
## Navmesh snaps memoized on a grid (per navmesh); map points never move, ring samples land on few cells.
const SNAP_CELL := 1.5
const SNAP_MEMO_MAX := 6000


static var _snapMemo := {}
static var _snapMap := RID()
static var _query: PhysicsRayQueryParameters3D = null



## Returns {"fire": entry, "full": entry, "rays": n, "snaps": n}; an entry is {"pos", "dist", "full"} or empty.
## minGain > 0 = retreat: only spots at least that much farther from the threat than the bot is now.
static func find(ai, threat: Vector3, maxDist: float, minGain := 0.0) -> Dictionary:
	var origin: Vector3 = ai.global_position
	var toThreat := threat - origin
	toThreat.y = 0.0
	toThreat = toThreat.normalized()


	# [distance, position, kind]: 0 = own position, 1 = map point (authored on the navmesh), 2 = ring sample.
	var samples := [[0.0, origin, 0]] if minGain <= 0.0 else []
	var minThreat := origin.distance_to(threat) + minGain if minGain > 0.0 else MIN_THREAT_DIST
	var maxSq := maxDist * maxDist
	for point in ai.AISpawner.covers:
		if is_instance_valid(point) && origin.distance_squared_to(point.global_position) <= maxSq:
			_consider_position(samples, point.global_position, origin, threat, toThreat, maxDist, 1, minThreat, minGain > 0.0)
	for point in ai.AISpawner.hides:
		if is_instance_valid(point) && origin.distance_squared_to(point.global_position) <= maxSq:
			_consider_position(samples, point.global_position, origin, threat, toThreat, maxDist, 1, minThreat, minGain > 0.0)
	for radius in RADII:
		if radius > maxDist: break
		for i in DIRECTIONS:
			var angle := TAU * i / DIRECTIONS + randf() * 0.25
			_consider_position(samples, origin + Vector3(sin(angle), 0.0, cos(angle)) * radius, origin, threat, toThreat, maxDist, 2, minThreat, minGain > 0.0)
	samples.sort_custom(func(a, b): return a[0] < b[0])


	var space = ai.get_world_3d().direct_space_state
	var mask: int = ai.sensor.obstruction
	var exclude := [ai.collision.get_rid()] if ai.collision else []
	var fire := {}
	var full := {}
	var rays := 0
	var snaps := 0


	for sample in samples:
		if !fire.is_empty() && !full.is_empty(): break
		if rays >= MAX_RAYS || snaps >= MAX_SNAPS: break


		# Ring samples: find the ground with a cheap ray first; the expensive navmesh snap only runs for spots that
		# pass the cover test. Map points are authored on the navmesh and the bot stands on it already.
		var spot: Vector3 = sample[1]
		if sample[2] == 2:
			rays += 1
			var ground := _ray(space, mask, exclude, spot + Vector3.UP * 3.0, spot + Vector3.DOWN * 4.0)
			if ground.is_empty(): continue
			spot = ground["position"]
			if abs(spot.y - origin.y) > 2.5: continue
		var dist := origin.distance_to(spot)
		if dist > maxDist || spot.distance_to(threat) < minThreat: continue


		rays += 1
		if !_blocked_near(space, mask, exclude, spot + Vector3.UP * CROUCH_HEIGHT, threat): continue
		rays += 1
		var standClear := _sees(space, mask, exclude, spot + Vector3.UP * STAND_HEIGHT, threat)
		if standClear && !fire.is_empty(): continue
		if !standClear && !full.is_empty(): continue


		if sample[2] == 2:
			var cached := _snap(ai.navmesh, spot)
			if !cached[1]: snaps += 1
			if Vector2(cached[0].x - spot.x, cached[0].z - spot.z).length() > MAX_NAV_SNAP: continue
			spot = cached[0]


		var entry := {"pos": spot, "dist": dist, "full": !standClear}
		if standClear && fire.is_empty(): fire = entry
		elif !standClear && full.is_empty(): full = entry


	return {"fire": fire, "full": full, "rays": rays, "snaps": snaps}

static func _consider_position(samples: Array, pos: Vector3, origin: Vector3, threat: Vector3, toThreat: Vector3, maxDist: float,
		kind: int, minThreat: float, retreat: bool):
	var dist := origin.distance_to(pos)
	if dist > maxDist || dist < 0.5 || pos.distance_to(threat) < minThreat: return
	var dir := pos - origin
	dir.y = 0.0
	if !retreat && dist > 3.0 && dir.normalized().dot(toThreat) > 0.3: return
	samples.append([dist, pos, kind])

## [snapped position, was cached].
static func _snap(navmesh: RID, pos: Vector3) -> Array:
	if navmesh != _snapMap || _snapMemo.size() > SNAP_MEMO_MAX:
		_snapMemo.clear()
		_snapMap = navmesh
	var key := Vector3i(floori(pos.x / SNAP_CELL), floori(pos.y / SNAP_CELL), floori(pos.z / SNAP_CELL))
	if _snapMemo.has(key): return [_snapMemo[key], true]
	var spot: Vector3 = NavigationServer3D.map_get_closest_point(navmesh, pos)
	_snapMemo[key] = spot
	return [spot, false]

static func _ray(space, mask: int, exclude: Array, from: Vector3, to: Vector3) -> Dictionary:
	if _query == null: _query = PhysicsRayQueryParameters3D.new()
	_query.from = from
	_query.to = to
	_query.collision_mask = mask
	_query.exclude = exclude
	return space.intersect_ray(_query)

## Line toward the threat is blocked by something close to the spot (the spot's own cover).
static func _blocked_near(space, mask: int, exclude: Array, from: Vector3, threat: Vector3) -> bool:
	var to := threat
	if from.distance_to(threat) > CHECK_LENGTH: to = from + (threat - from).normalized() * CHECK_LENGTH
	var hit := _ray(space, mask, exclude, from, to)
	return !hit.is_empty() && from.distance_to(hit["position"]) <= COVER_NEAR

## Clear line to the threat (up to SIGHT_LENGTH; beyond that assume clear).
static func _sees(space, mask: int, exclude: Array, from: Vector3, threat: Vector3) -> bool:
	var to := threat
	if from.distance_to(threat) > SIGHT_LENGTH: to = from + (threat - from).normalized() * SIGHT_LENGTH
	return _ray(space, mask, exclude, from, to).is_empty()
