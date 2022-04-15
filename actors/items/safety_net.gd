extends Area2D

onready var collision = $CollisionShape2D

func snap_player(check_body):
	var bodies
	if check_body == null:
		bodies = get_overlapping_bodies()
	else:
		bodies = [check_body]
	if bodies.size() > 0:
		for body in bodies:
			var player_box = body.get_node("Hitbox")
			if (body.vel.y > 0
			&& body.position.y + player_box.shape.extents.y + player_box.position.y - 4 < global_position.y + collision.shape.extents.y
			):
				body.position.y = global_position.y - collision.shape.extents.y - player_box.shape.extents.y - player_box.position.y
				body.vel.y = 1


func _physics_process(_delta):
	snap_player(null)


func _on_SafetyNet_body_entered(body):
	snap_player(body)


func _on_SafetyNet_body_exited(body):
	if body.vel.y < 0 && (!Input.is_action_pressed("fludd") || Singleton.classic || Singleton.nozzle != Singleton.n.rocket):
		Singleton.power = 100 #air rocket
