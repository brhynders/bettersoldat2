package sim

// The bullet pool: spawning, the tick (collisions, then movement, then the timeout
// and the damage falling off with distance), ending. Ported from OpenSoldat
// Bullets.pas by way of the old Odin port. What a bullet does to a soldier is a Hit
// event (bullet_collision.odin); this file never wounds anyone.

BULLET_GRAVITY :: 2.25
BULLET_DAMPING :: 0.99
ARROW_RESIST   :: 280

Bullet :: struct {
	active:         bool,
	style:          Bullet_Style,
	weapon:         Weapon_Id,
	owner:          u8,
	lag:            u8, // its shooter's round trip in ticks (OwnerPingTick): how far back it meets the others on a client, and how late its shove lands
	seed:           u16, // its shooter's shot number: what the others rebuild the pellets from
	pos, old_pos:   Vec2,
	vel, forces:    Vec2,
	initial:        Vec2, // where it was fired: the damage falls off from here
	hit_spot:       Vec2, // the last ricochet, so one surface deflects it once
	timeout:        i32,
	hit_multiply:   f32,
	hit_body:       i8, // the soldier last hit, so a piercing bullet hits it once
	ricochet_count: i32,
	degrade_count:  i32,
	thing_cooldowns: [4]Thing_Cooldown, // things it pushed recently: not again every tick
}

Thing_Cooldown :: struct {
	thing: u8, // index + 1, 0 for an empty slot
	until: u32,
}

bullets_update :: proc(ctx: ^Context, w: ^World, events: ^Events) {
	for &b, i in w.bullets {
		if b.active do bullet_update(ctx, w, &b, u16(i), events)
	}
	for &b in w.bullets {
		if b.active do bullet_integrate(w, &b)
	}
}

// A bullet, whatever asks for it. A shot from the keys goes through fire_bullet.
bullet_spawn :: proc(ctx: ^Context, w: ^World, pos, vel: Vec2, weapon: Weapon_Id, owner: u8, damage: f32, events: ^Events, lag: u8 = 0) -> (index: int, ok: bool) {
	for &b, i in w.bullets {
		if b.active do continue
		info := &ctx.weapons[weapon]
		b = {
			active = true, style = info.style, weapon = weapon, owner = owner, lag = lag, seed = w.soldiers[owner].bullet_count,
			pos = pos, old_pos = pos, vel = vel, initial = pos,
			timeout = info.timeout, hit_multiply = damage, hit_body = -1,
		}
		emit(events, Bullet_Spawn{id = u16(i), player = owner, weapon = weapon, pos = pos, vel = vel, damage = damage})
		return i, true
	}
	return 0, false
}

// A shot from the keys (OpenSoldat's CreateBullet without MustCreate), which is not
// always this machine's to create. A weapon that fires slower than FIRE_INTERVAL_NET
// is sent over the wire, one message per shot: the machine that plays the shooter
// makes it and sends it, the server makes it on receiving it, and a client makes it
// on receiving the relay; so from the keys the server makes none of a player's, and
// a client none of another's that the server would have relayed to it
// (bullet_visible). Faster weapons are never sent: every machine makes them from the
// Fire key.
FIRE_INTERVAL_NET :: 5

fire_bullet :: proc(ctx: ^Context, w: ^World, pos, vel: Vec2, weapon: Weapon_Id, owner: u8, damage: f32, events: ^Events) -> (index: int, ok: bool) {
	if ctx.weapons[weapon].fire_interval > FIRE_INTERVAL_NET && int(owner) not_in w.net.mine {
		if w.net.server do return 0, false
		if bullet_visible(pos, vel, w.net.view, w.net.view_half) do return 0, false
	}
	return bullet_spawn(ctx, w, pos, vel, weapon, owner, damage, events)
}

// One tick of one bullet, for flying a relayed one on by the pings.
bullet_tick :: proc(ctx: ^Context, w: ^World, index: u16, events: ^Events) {
	b := &w.bullets[index]
	if !b.active do return
	bullet_update(ctx, w, b, index, events)
	if b.active do bullet_integrate(w, b)
}

// Whether a bullet born at `pos` is worth sending to a viewer whose camera is at
// `view`: inside the box around the view, or inside a wider one when it is flying
// toward the viewer (OpenSoldat's BulletCanSend).
bullet_visible :: proc(pos, vel, view, half: Vec2) -> bool {
	if abs(pos.x - view.x) < half.x && abs(pos.y - view.y) < half.y do return true
	toward := (view.x < pos.x && vel.x < 0) || (view.x > pos.x && vel.x > 0)
	return toward && abs(pos.x - view.x) < 1640 && abs(pos.y - view.y) < 680
}

// Every deactivation goes through here so the end event is emitted where it happens.
// `impact` is where it stopped against something, if it did.
bullet_end :: proc(w: ^World, b: ^Bullet, index: u16, events: ^Events, impact: Maybe(Vec2) = nil) {
	if !b.active do return
	b.active = false
	e := Bullet_End{id = index, owner = b.owner, weapon = b.weapon, pos = b.pos}
	if p, ok := impact.?; ok do e.pos, e.impact = p, true
	emit(events, e)
}

@(private = "file")
bullet_integrate :: proc(w: ^World, b: ^Bullet) {
	b.forces.y += w.gravity * BULLET_GRAVITY
	prev := b.pos
	b.vel += b.forces
	b.pos += b.vel
	b.vel *= BULLET_DAMPING
	b.old_pos = prev
	b.forces = {}
}

@(private = "file")
bullet_update :: proc(ctx: ^Context, w: ^World, b: ^Bullet, index: u16, events: ^Events) {
	level := ctx.level
	bound := f32(level.sectors_num * level.sectors_division - 10)
	if abs(b.pos.x) > bound || abs(b.pos.y) > bound {
		bullet_end(w, b, index, events)
		return
	}

	bullet_collide(ctx, w, b, index, events)
	if !b.active do return

	b.timeout -= 1
	if b.timeout == 0 {
		#partial switch b.style {
		case .Frag_Grenade, .M79, .Flame_Arrow, .LAW: explode(ctx, w, b, index, .Frag, -1, -1, events)
		case .Cluster, .M2:                           explode(ctx, w, b, index, .Cluster, -1, -1, events)
		}
		bullet_end(w, b, index, events)
		return
	}

	// the damage falls off with distance travelled
	if b.timeout % 6 == 0 && b.weapon != .Barrett && b.weapon != .M79 && b.weapon != .Knife && b.weapon != .LAW {
		dist := vec2_length(b.initial - b.pos)
		if (b.degrade_count == 0 && dist > 500) || (b.degrade_count == 1 && dist > 900) {
			b.hit_multiply *= 0.5
			b.degrade_count += 1
		}
	}
	if b.style == .Flame do b.forces.y -= 0.15
}
