package sim

// A soldier: the struct, spawning, and the tick in order. The parts live in their
// own files: movement (the control state machines), soldier_anim, combat, antics,
// soldier_collision. Ported from OpenSoldat Sprites.pas by way of the old Odin port.

DEFAULT_HEALTH     :: 150.0
DEFAULT_CEASE_FIRE :: 90
SOLDIER_DAMPING    :: 0.99

Stance :: enum u8 { Stand, Crouch, Prone }

Bonus :: enum u8 { None, Flame_God, Predator, Berserker }

// The first block is what its own client's commands drive and so predicts; the rest is
// the server's alone.
Soldier :: struct {
	active: bool,
	team:   Team,
	health: f32,
	dead:   bool,
	ping_ticks: u8, // its round trip in ticks, as the server measured it (PingTicks)
	bullet_count: u16, // numbers its shots, from a random start: the seed the others rebuild the pellets from
	death_vel:  Vec2, // how it died, for the corpse any client starts from this state
	death_part: u8,
	rng:      u64, // its own randomness (the spread of its shots), so its client predicts it

	// owned by the client that plays it
	pos, old_pos:  Vec2,
	vel, forces:   Vec2, // forces apply on the next integration step
	push:          [PUSH_TICKS]Vec2, // knockback waiting: push[0] lands next step, the rest shift down (NextPush)
	controls:      Buttons, // this tick's resolved input
	aim:           Vec2,
	direction:     i8, // 1 facing right, -1 left
	old_direction: i8,
	// Left+Right held together keeps the previous direction: memory of the last tick.
	was_running_left: bool,
	was_jumping:      bool,
	stance:        Stance,
	legs, body:    Anim,
	on_ground:     bool,
	on_ground_last, on_ground_permanent, on_ground_for_law: bool,
	jets:          i32,
	bg:            Background_State,
	fired:         bool, // a shot went off this tick: the muzzle flash
	weapon:        Weapon,
	secondary:     Weapon,
	grenades:      i32,
	burst_count:   i32,
	grenade_can_throw:         bool,
	can_auto_reload_spas:      bool,
	auto_reload_when_can_fire: bool,
	// Distance from the muzzle to cover (a map collider, or a crouched teammate),
	// refreshed every 10 ticks; 255 = not near any. Crouching by cover raises the gun.
	collider_distance: u8,
	hit_spray:     u16, // bink: aim disturbance from being hit, decaying one per tick
	spawn_still:   bool, // not moved since spawning: the weapons menu still applies
	para, stat:    u8, // the parachute or stationary gun in use (thing index + 1)
	idle:          Idle,
	holding_flag:  bool,

	// the server's
	respawn_counter:    i32,
	cease_fire_counter: i32, // spawn protection: no shooting, no wounds while >= 0
	vest:               f32,
	bonus:              Bonus,
	bonus_time:         i32,
	primary_choice:     Weapon_Id, // the loadout for the next spawn
	secondary_choice:   Weapon_Id,
	kills, deaths, flags: i32,
}

// A fresh soldier at a spot; the tally survives a respawn.
soldier_spawn :: proc(ctx: ^Context, s: ^Soldier, pos: Vec2, team: Team, primary, secondary: Weapon_Id) {
	kills, deaths, flags := s.kills, s.deaths, s.flags
	rng := s.rng != 0 ? s.rng : (u64(transmute(u32)pos.x) << 32 | u64(transmute(u32)pos.y)) | 1 // seeded once, from where it first stood
	bullet_count := s.bullet_count != 0 ? s.bullet_count : u16(rng >> 17) | 1
	s^ = {
		rng                = rng,
		bullet_count       = bullet_count,
		kills              = kills,
		deaths             = deaths,
		flags              = flags,
		active             = true,
		team               = team,
		health             = DEFAULT_HEALTH,
		pos                = pos,
		old_pos            = pos,
		direction          = 1,
		old_direction      = 1,
		stance             = .Stand,
		jets               = ctx.level.start_jet,
		bg                 = {status = BACKGROUND_TRANSITION, poly = BACKGROUND_POLY_UNKNOWN},
		cease_fire_counter = DEFAULT_CEASE_FIRE,
		grenades           = 1,
		primary_choice     = primary,
		secondary_choice   = secondary,
		weapon             = weapon_state(ctx, primary),
		secondary          = weapon_state(ctx, secondary),
		grenade_can_throw  = true,
		collider_distance  = 255,
		spawn_still        = true,
		bonus_time         = -1,
	}
	anim_set(ctx.anims, &s.legs, .Stand)
	anim_set(ctx.anims, &s.body, .Stand)
}

soldier_respawn :: proc(ctx: ^Context, w: ^World, index: u8, events: ^Events) {
	s := &w.soldiers[index]
	pos := level_spawn_point(ctx.level, s.team, &w.rng)
	soldier_spawn(ctx, s, pos, s.team, s.primary_choice, s.secondary_choice)
	emit(events, Respawn{target = index, pos = pos})
}

// Euler integration of the body particle, before the control step.
soldier_integrate :: proc(s: ^Soldier, gravity: f32) {
	s.forces.y += gravity
	prev := s.pos
	s.vel += s.forces
	s.pos += s.vel
	s.vel *= SOLDIER_DAMPING
	s.old_pos = prev
	s.forces = {}
}

// One tick of one soldier, in the original's order: integrate, take the knockback,
// the controls through the state machines, animate, collide with the map, the
// weapon timers, the jet fuel.
soldier_step :: proc(ctx: ^Context, w: ^World, index: u8, cmd: Command, events: ^Events) {
	s := &w.soldiers[index]
	if !s.active || s.dead do return
	soldier_integrate(s, w.gravity)
	s.vel += s.push[0]
	copy(s.push[:PUSH_TICKS - 1], s.push[1:])
	s.push[PUSH_TICKS - 1] = {}
	if s.hit_spray > 0 do s.hit_spray -= 1

	// Between rounds nobody moves.
	s.controls = w.round.state == .Ended ? {} : cmd.buttons
	s.aim = cmd.aim
	// suicide is a hit on oneself, applied like any other, and a brutal one
	if .Suicide in s.controls do emit(events, Hit{shooter = index, target = index, amount = 4 * DEFAULT_HEALTH, pos = s.pos})
	soldier_control(ctx, w, index, events)
	s.direction = s.aim.x >= s.pos.x ? 1 : -1
	anim_advance(ctx.anims, &s.body)
	anim_advance(ctx.anims, &s.legs)
	if s.cease_fire_counter > -1 do s.cease_fire_counter -= 1

	level := ctx.level
	bound := f32(level.sectors_num * level.sectors_division - 50)
	if abs(s.pos.x) > bound || abs(s.pos.y) > bound {
		if w.net.server do soldier_respawn(ctx, w, index, events) // a client waits for the server's word
		return
	}

	soldier_collide(ctx, w, index, events)
	weapon_timers(ctx, s)
	antics_apply(ctx, w, s)
	bonus_tick(s)

	// Jet fuel regenerates when not jetting: every tick on the ground, every other in the air.
	if s.jets < level.start_jet && .Jet not_in s.controls {
		if s.on_ground || w.tick % 2 == 0 do s.jets += 1
	}
}

// A hit's shove, into the victim's queue. On the server it lands next tick. On a client
// it waits until the bullet is seen to arrive: half the victim's round trip, plus the
// shooter's as the bullet carries it, plus one (OpenSoldat's PushTick), so the shove
// is felt about when the shooter saw the hit.
PUSH_TICKS :: 126 // MAX_PUSHTICK 125, and the one landing now

soldier_shove :: proc(w: ^World, victim: u8, bullet_lag: u8, push: Vec2) {
	s := &w.soldiers[victim]
	k := 0
	if !w.net.server do k = min(int(s.ping_ticks) / 2 + int(bullet_lag) + 1, PUSH_TICKS - 1)
	s.push[k] += push
}

// The one thing that ticks on a dead soldier: the countdown to its respawn.
soldier_dead_tick :: proc(ctx: ^Context, w: ^World, index: u8, events: ^Events) {
	s := &w.soldiers[index]
	s.respawn_counter -= 1
	if s.respawn_counter < 1 do soldier_respawn(ctx, w, index, events)
}

bonus_tick :: proc(s: ^Soldier) {
	if s.bonus_time > -1 {
		s.bonus_time -= 1
		if s.bonus_time < 1 do s.bonus = .None
	} else {
		s.bonus = .None
	}
}
