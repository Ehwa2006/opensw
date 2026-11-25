extends SceneTree
## 개발용: 임포트된 FBX의 크기(AABB)와 머티리얼 이름을 출력한다.
## godot --headless -s res://tools/probe_models.gd

func _init() -> void:
	var dir := DirAccess.open("res://assets/models")
	for f in dir.get_files():
		if not f.ends_with(".fbx"):
			continue
		var ps: PackedScene = load("res://assets/models/" + f)
		var inst := ps.instantiate()
		root.add_child(inst)
		var aabb := AABB()
		var first := true
		var mats := {}
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			var b: AABB = m.global_transform * m.mesh.get_aabb()
			aabb = b if first else aabb.merge(b)
			first = false
			for s in m.mesh.get_surface_count():
				var mat := m.mesh.surface_get_material(s)
				mats[mat.resource_name if mat else "?"] = true
		print("%s size=%s pos=%s mats=%s" % [f, aabb.size, aabb.position, mats.keys()])
		inst.queue_free()
	quit()
