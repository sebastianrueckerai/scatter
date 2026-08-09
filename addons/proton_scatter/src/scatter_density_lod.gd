@tool
class_name ScatterDensityLOD
extends Node

## Thins ProtonScatter foliage with distance, so any amount of ground can be
## covered while only the foliage near the player is actually drawn.
##
## ProtonScatter already splits its output into one MultiMeshInstance3D per
## chunk when Performance/use_chunks is on, and centres each chunk on its own
## instances. That gives Godot small bounding boxes to frustum-cull, and makes
## the ScatterItem's visibility_range_end work per chunk. What it does not give
## you is *density* that varies with distance -- every chunk inside the visible
## range draws all of its instances.
##
## This node adds that. Per chunk it sets MultiMesh.visible_instance_count from
## a curve of distance to the player, and hides chunks past max_distance.
## Thinning by instance count is uniform because ProtonScatter's create
## modifiers emit transforms in random order and the chunk bucketing preserves
## it, so the first N instances of a chunk are a random N-subset of it.
##
## Cost does not grow with world size. Chunks are kept in a grid keyed by
## position, so an update only looks at the cells overlapping the player's
## radius -- roughly (max_distance / chunk size)^2 chunks, whether the world is
## one island or a hundred square kilometres. An update is also skipped
## entirely until the player has moved `update_move_threshold` metres.
##
## Scatter nodes can come and go at runtime. Point `scatter_root` at a subtree
## and everything under it is picked up, or call register_scatter() and
## unregister_scatter() from a streaming system. Neither path rebuilds the
## whole grid; only the affected node's chunks are touched.
##
## Part of the WilloWink fork of ProtonScatter, not upstream. It sits beside
## scatter.gd rather than in src/modifiers/, because modifiers run at build time
## on a worker thread and have no camera or player to measure from -- this needs
## to run every frame against a live position.

## Subtree to search for ProtonScatter nodes. Empty means "the parent node",
## which covers the common case of dropping this in as a child of one scatter.
@export var scatter_root: NodePath

## What distance is measured from. Empty falls back to the node in the "player"
## group, then to the current camera.
@export var tracked_node: NodePath

## Chunks beyond this are hidden. This is the only distance you normally tune.
@export var max_distance: float = 70.0:
	set(val):
		max_distance = maxf(val, 1.0)
		if is_inside_tree() and not _chunks.is_empty():
			_rehash()

## Density against distance: x is distance / max_distance, y is the fraction of
## a chunk's instances to draw. Null uses a built-in falloff that holds full
## density to a quarter of max_distance and then declines.
@export var density_curve: Curve

## Density is rounded to this many steps. Without it every chunk would be
## rewritten on every frame the player moves, which costs more than it saves
## and makes blades flicker at the ring edges.
@export_range(2, 64) var density_steps: int = 12

## How far the player must move before the rings are re-evaluated. Standing
## still costs nothing at all.
@export_range(0.0, 32.0) var update_move_threshold: float = 2.0

## Run in the editor too. Off by default, since it edits the scatter output.
@export var preview_in_editor: bool = false


# Chunk records, addressed by slot. Freed slots are reused rather than
# compacted, so a scatter node unregistering never disturbs the others.
var _chunks: Array[MultiMeshInstance3D] = []
var _positions: PackedVector3Array = PackedVector3Array()
var _full_counts: PackedInt32Array = PackedInt32Array()
var _applied_step: PackedInt32Array = PackedInt32Array()
var _free_slots: Array[int] = []

# Grid cell (x, z) -> slots inside it. Cell size follows max_distance so a
# query never has to look at more than 3x3 cells.
var _cells: Dictionary = {}
var _cell_size: float = 70.0

# Which slots belong to which ProtonScatter, so one can be removed on its own.
var _slots_by_scatter: Dictionary = {}

var _active: Dictionary = {}
var _tracked: Node3D
var _last_update_position: Vector3 = Vector3.INF
var _rehash_queued: bool = false


func _ready() -> void:
	if Engine.is_editor_hint() and not preview_in_editor:
		set_process(false)
		return
	_discover_scatters()


func _exit_tree() -> void:
	# Leaving everything hidden would be a nasty surprise for whoever removes
	# this node, so put the foliage back the way it was found.
	restore_all()


# ------------------------------------------------------------------ discovery

func _discover_scatters() -> void:
	var root: Node = get_node_or_null(scatter_root) if not scatter_root.is_empty() \
			else get_parent()
	if not root:
		push_warning("ScatterDensityLOD at %s: nothing to search." % get_path())
		set_process(false)
		return

	var found := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is ProtonScatter:
			register_scatter(n)
			found += 1
		for c in n.get_children():
			stack.append(c)

	if found == 0:
		push_warning("ScatterDensityLOD at %s: no ProtonScatter node found under %s."
				% [get_path(), root.get_path()])
		set_process(false)


## Start driving a ProtonScatter node. Safe to call again for the same node --
## it re-reads the chunks, which is what you want after a rebuild.
func register_scatter(s: ProtonScatter) -> void:
	if not is_instance_valid(s):
		return
	unregister_scatter(s)

	if not s.build_completed.is_connected(_on_build_completed):
		s.build_completed.connect(_on_build_completed.bind(s))
	if not s.tree_exiting.is_connected(_on_scatter_exiting):
		s.tree_exiting.connect(_on_scatter_exiting.bind(s))

	var slots := PackedInt32Array()
	var out_root := s.get_node_or_null("ScatterOutput")
	if out_root:
		var stack: Array[Node] = [out_root]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is MultiMeshInstance3D and n.multimesh:
				slots.append(_add_chunk(n))
			for c in n.get_children():
				stack.append(c)

	_slots_by_scatter[s.get_instance_id()] = slots
	# Force the next update to run even if the player has not moved.
	_last_update_position = Vector3.INF


## Stop driving a ProtonScatter node and forget its chunks.
func unregister_scatter(s: ProtonScatter) -> void:
	var key := s.get_instance_id()
	if not _slots_by_scatter.has(key):
		return
	for slot in _slots_by_scatter[key] as PackedInt32Array:
		_remove_chunk(slot)
	_slots_by_scatter.erase(key)
	_last_update_position = Vector3.INF


func _on_build_completed(s: ProtonScatter) -> void:
	# A rebuild destroys and recreates every chunk node, so the references have
	# to be re-read. Coalesced to idle: several nodes often finish together.
	if _rehash_queued:
		return
	_rehash_queued = true
	_reregister.call_deferred(s)


func _reregister(s: ProtonScatter) -> void:
	_rehash_queued = false
	if is_instance_valid(s):
		register_scatter(s)


func _on_scatter_exiting(s: ProtonScatter) -> void:
	unregister_scatter(s)


# ----------------------------------------------------------------- chunk store

func _add_chunk(mmi: MultiMeshInstance3D) -> int:
	var pos := mmi.global_position
	var slot: int
	if _free_slots.is_empty():
		slot = _chunks.size()
		_chunks.append(mmi)
		_positions.append(pos)
		_full_counts.append(mmi.multimesh.instance_count)
		_applied_step.append(-1)
	else:
		slot = _free_slots.pop_back()
		_chunks[slot] = mmi
		_positions[slot] = pos
		_full_counts[slot] = mmi.multimesh.instance_count
		_applied_step[slot] = -1

	# Start hidden. The first update turns on whatever is close enough, which
	# also means a chunk that is never visited stays correctly dark.
	mmi.visible = false
	_applied_step[slot] = 0

	var cell := _cell_of(pos)
	if not _cells.has(cell):
		_cells[cell] = PackedInt32Array()
	var arr: PackedInt32Array = _cells[cell]
	arr.append(slot)
	_cells[cell] = arr
	return slot


func _remove_chunk(slot: int) -> void:
	if slot < 0 or slot >= _chunks.size():
		return
	var mmi := _chunks[slot]
	if is_instance_valid(mmi):
		mmi.visible = true
		mmi.multimesh.visible_instance_count = -1

	var cell := _cell_of(_positions[slot])
	if _cells.has(cell):
		var arr: PackedInt32Array = _cells[cell]
		var at := arr.find(slot)
		if at >= 0:
			arr.remove_at(at)
		if arr.is_empty():
			_cells.erase(cell)
		else:
			_cells[cell] = arr

	_chunks[slot] = null
	_applied_step[slot] = -1
	_active.erase(slot)
	_free_slots.append(slot)


func _cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / _cell_size)), int(floor(pos.z / _cell_size)))


## Re-bucket every chunk. Only needed when the cell size changes, i.e. when
## max_distance is changed at runtime.
func _rehash() -> void:
	_cell_size = maxf(max_distance, 1.0)
	_cells.clear()
	for slot in _chunks.size():
		if not is_instance_valid(_chunks[slot]):
			continue
		var cell := _cell_of(_positions[slot])
		if not _cells.has(cell):
			_cells[cell] = PackedInt32Array()
		var arr: PackedInt32Array = _cells[cell]
		arr.append(slot)
		_cells[cell] = arr
	_last_update_position = Vector3.INF


# --------------------------------------------------------------------- update

func _process(_delta: float) -> void:
	if _chunks.is_empty():
		return
	if not _update_tracked_position():
		return

	var pos := _tracked_position
	if _last_update_position.is_finite() \
			and pos.distance_squared_to(_last_update_position) \
				< update_move_threshold * update_move_threshold:
		return
	_last_update_position = pos

	var max_d2 := max_distance * max_distance
	var steps := float(density_steps)
	var centre := _cell_of(pos)
	var reach := int(ceil(max_distance / _cell_size))
	var still_active := {}

	for cx in range(centre.x - reach, centre.x + reach + 1):
		for cz in range(centre.y - reach, centre.y + reach + 1):
			var cell := Vector2i(cx, cz)
			if not _cells.has(cell):
				continue
			for slot in _cells[cell] as PackedInt32Array:
				var d2 := _positions[slot].distance_squared_to(pos)
				if d2 > max_d2:
					continue
				var frac := _density_at(sqrt(d2) / max_distance)
				var step := int(ceil(frac * steps))
				if step <= 0:
					continue
				still_active[slot] = true
				if step == _applied_step[slot]:
					continue
				_applied_step[slot] = step

				var mmi := _chunks[slot]
				if not is_instance_valid(mmi):
					continue
				mmi.visible = true
				if step >= density_steps:
					mmi.multimesh.visible_instance_count = -1
				else:
					mmi.multimesh.visible_instance_count = maxi(
							1, int(_full_counts[slot] * float(step) / steps))

	# Anything that was on last time and is not now has just gone out of range.
	for slot in _active:
		if still_active.has(slot):
			continue
		var mmi := _chunks[slot]
		if is_instance_valid(mmi):
			mmi.visible = false
		_applied_step[slot] = 0
	_active = still_active


func _density_at(x: float) -> float:
	if density_curve:
		return clampf(density_curve.sample_baked(clampf(x, 0.0, 1.0)), 0.0, 1.0)
	# Full density close in, then a smooth decline to a thin scatter at the edge.
	if x <= 0.25:
		return 1.0
	return clampf(1.0 - smoothstep(0.25, 1.0, x) * 0.95, 0.0, 1.0)


var _tracked_position: Vector3 = Vector3.ZERO

## Writes the distance origin into _tracked_position. False means there is
## nothing to measure from yet, which happens between the scene loading and the
## player spawning.
func _update_tracked_position() -> bool:
	if is_instance_valid(_tracked):
		_tracked_position = _tracked.global_position
		return true

	if not tracked_node.is_empty():
		var n := get_node_or_null(tracked_node)
		if n is Node3D:
			_tracked = n
			_tracked_position = _tracked.global_position
			return true

	var tree := get_tree()
	if tree:
		# The literal rather than Player.PLAYER_GROUP: referencing the Player
		# class would pull player.gd and the whole quest system in as a compile
		# dependency of a foliage node.
		var player := tree.get_first_node_in_group(&"player")
		if player is Node3D:
			_tracked = player
			_tracked_position = _tracked.global_position
			return true

	var vp := get_viewport()
	if vp:
		var cam := vp.get_camera_3d()
		if cam:
			_tracked_position = cam.global_position
			return true
	return false


# ---------------------------------------------------------------------- extras

## Put every chunk back to fully visible. Called when this node leaves the tree.
func restore_all() -> void:
	for slot in _chunks.size():
		var mmi := _chunks[slot]
		if not is_instance_valid(mmi):
			continue
		mmi.visible = true
		if mmi.multimesh:
			mmi.multimesh.visible_instance_count = -1
		_applied_step[slot] = -1
	_active.clear()


## Instances currently drawn, and how many there would be without thinning.
## Useful on a debug HUD.
func get_stats() -> Dictionary:
	var drawn := 0
	var total := 0
	var live := 0
	for slot in _chunks.size():
		var mmi := _chunks[slot]
		if not is_instance_valid(mmi):
			continue
		live += 1
		total += _full_counts[slot]
		if not mmi.visible:
			continue
		var v: int = mmi.multimesh.visible_instance_count
		drawn += _full_counts[slot] if v < 0 else v
	return {
		"chunks": live,
		"chunks_visible": _active.size(),
		"instances_drawn": drawn,
		"instances_total": total,
		"scatter_nodes": _slots_by_scatter.size(),
		"cells": _cells.size(),
	}
