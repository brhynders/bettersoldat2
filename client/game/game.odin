package game

import "../connection"
import "../input"
import "../../shared/net"
import "../../shared/sim"

// The game as OpenSoldat's client plays it (ClientGame.pas, UpdateFrame.pas,
// NetworkClient*.pas). One world, stepped every tick: my soldier on my keys, everyone
// else on the last keys the server relayed of them (dead reckoning: the whole movement
// code, so they keep running, jumping and jetting as they were), every bullet, every
// thing. What the server says of the others lands as it comes: a snapshot or a delta
// puts a soldier where the server has it, no blending. Of my own soldier the server's
// word is only my health, my vest and my grenades; where I am is mine to say, and I
// say it every few ticks. I wound nobody: the hits I see are blood and a shove, and
// the wound comes back in a snapshot. A slow weapon's shot comes as a bullet that is
// flown on by my ping and its shooter's; a fast weapon's I make from their Fire key.
Game :: struct {
	ctx:       sim.Context,
	level:     sim.Level,
	anims:     ^sim.Anims,
	skeletons: ^sim.Skeletons,
	world:     sim.World,
	history:   sim.History, // where everyone was, so a relayed bullet meets them as its shooter saw them
	me:        u8,
	events:    sim.Events, // this tick's, for the sparks and sounds
	others:    [sim.MAX_PLAYERS]sim.Command, // the last keys and aim heard of each: what they are stepped on

	// the clock and the line
	client_ticks:  i32, // the server's tick as last told, counted on (ClientTickCount)
	last_told:     i32, // the newest server tick a snapshot named: an older delta is stale
	stop_moving:   int, // ticks left before the world freezes for want of a ping (ClientStopMovingCounter)
	heartbeat_at:  u32, // when the last heartbeat came
	had_heartbeat: bool,
	players:       int, // for the packet-rate scale

	// what I last sent, for the change gates
	old_snapshot: net.Client_Sprite_Snapshot,
	old_mov:      net.Client_Sprite_Snapshot_Mov, // its aim is the mouse on the screen, as the original keeps it
	force_mov:    bool, // a fast weapon fired: the next movement packet goes at once
	last_force:   u32,
	sent_seed:    u16,  // my newest shot sent: one message per shot, whatever its pellets

	prev:        [sim.MAX_PLAYERS]sim.Vec2, // where each soldier was before the newest tick, for drawing between ticks
	shots_fired: int,
	hits_seen:   int, // my bullets meeting an enemy, as I saw them
	writer:      net.Writer,
}

// The sim's data for the map, and the world as the welcome describes it: everyone
// playing is there, dead until their first snapshot puts them somewhere.
init :: proc(g: ^Game, base: string, welcome: ^net.Welcome) -> bool {
	ok: bool
	if g.level, ok = sim.level_load_file(base, welcome.map_name); !ok do return false
	if g.anims, ok = sim.anims_load_files(base); !ok do return false
	if g.skeletons, ok = sim.skeletons_load_files(base); !ok do return false
	g.ctx.level = &g.level
	g.ctx.anims = g.anims
	g.ctx.skeletons = g.skeletons
	sim.weapons_default(&g.ctx.weapons)
	sim.world_init(&g.world, 0)
	sim.round_init(&g.world.round)
	g.me = welcome.slot
	g.world.net.mine = {int(g.me)}
	g.world.history = &g.history
	g.client_ticks = welcome.server_ticks
	g.world.tick = u32(welcome.server_ticks)
	for team, i in welcome.teams do if team != .None do player_appears(g, u8(i), team)
	g.stop_moving = net.CLIENT_STOP_MOVE_RETRYS
	return true
}

destroy :: proc(g: ^Game) {
	sim.level_destroy(&g.level)
	free(g.anims)
	free(g.skeletons)
}

// A soldier that is playing but not yet placed: dead, so its first snapshot revives it.
player_appears :: proc(g: ^Game, slot: u8, team: sim.Team) {
	s := &g.world.soldiers[slot]
	sim.soldier_spawn(&g.ctx, s, {}, team, .AK74, .Colt)
	s.dead = true
	g.players += 1
}

// ---- the tick ----

// Everyone stepped on their keys, then the things, the bullets and the corpses; and
// where everyone was, recorded. With the pings stopped, nothing moves (the original's
// ClientStopMovingCounter). `view` is my camera and `view_half` half my view, for the
// rules that go by what I can see.
simulate :: proc(g: ^Game, in_: ^input.Input, view, view_half: sim.Vec2) {
	w := &g.world
	w.net.view, w.net.view_half = view, view_half
	sim.events_clear(&g.events)
	if g.stop_moving > 0 do g.stop_moving -= 1
	if g.had_heartbeat && w.tick - g.heartbeat_at > net.CONNECTION_PROBLEM_TIME do g.stop_moving = 0

	mine := input.command(in_, 0)
	for &s, i in w.soldiers do g.prev[i] = s.pos
	if g.stop_moving > 0 {
		for &s, i in w.soldiers {
			if !s.active || s.dead do continue
			sim.soldier_step(&g.ctx, w, u8(i), u8(i) == g.me ? mine : g.others[i], &g.events)
		}
		sim.things_update(&g.ctx, w, &g.events)
		sim.bullets_update(&g.ctx, w, &g.events)
	}
	sim.ragdolls_update(&g.ctx, w)
	sim.history_record(&g.history, w)
	w.tick += 1
	g.client_ticks += 1

	for e in sim.events_slice(&g.events) {
		#partial switch v in e {
		case sim.Fire:
			if v.player != g.me do continue
			g.shots_fired += 1
			// a fast weapon's shot is not sent: the next movement packet goes at once instead
			if g.ctx.weapons[v.weapon].fire_interval <= sim.FIRE_INTERVAL_NET && w.tick > g.last_force + sim.FIRE_INTERVAL_NET {
				g.force_mov = true
				g.last_force = w.tick
			}
		case sim.Hit:
			if v.shooter == g.me && v.target != g.me && w.soldiers[v.target].team != w.soldiers[g.me].team do g.hits_seen += 1
		}
	}
}

// ---- sending ----

// On the schedules of ClientGame.pas: what I hold every seven ticks or so when it
// changed, where I am every five when it changed enough, that I am dead every thirty;
// and each slow weapon's shot as it leaves.
send :: proc(g: ^Game, conn: ^connection.Connection, in_: ^input.Input, mouse: sim.Vec2) {
	w := &g.world
	me := &w.soldiers[g.me]
	a := net.client_adjust(g.players)
	tick := w.tick
	if me.active && !me.dead {
		if net.due(tick, 7, a, 1) && !net.due(tick, 5, a) do send_snapshot(g, conn)
		if net.due(tick, 5, a) || g.force_mov {
			send_movement(g, conn, in_, mouse)
			g.force_mov = false
		}
	} else if me.active && net.due(tick, 30, a) {
		m := net.Client_Sprite_Snapshot_Dead{camera_focus = g.me}
		send_msg(g, conn, .Client_Sprite_Snapshot_Dead, &m)
	}
	for e in sim.events_slice(&g.events) {
		v, is_spawn := e.(sim.Bullet_Spawn)
		if !is_spawn || v.player != g.me || g.stop_moving <= 0 do continue
		b := &w.bullets[v.id]
		info := &g.ctx.weapons[v.weapon]
		if b.seed == g.sent_seed do continue // a pellet of a shot already sent
		if info.fire_interval <= sim.FIRE_INTERVAL_NET && b.style != .Frag_Grenade && b.style != .Cluster_Nade do continue
		g.sent_seed = b.seed
		m := net.Client_Bullet_Snapshot{weapon = v.weapon, pos = v.pos, vel = v.vel, seed = b.seed, client_ticks = g.client_ticks}
		send_msg(g, conn, .Bullet_Snapshot, &m)
	}
}

send_snapshot :: proc(g: ^Game, conn: ^connection.Connection) {
	me := &g.world.soldiers[g.me]
	m := net.Client_Sprite_Snapshot{
		ammo = u8(clamp(me.weapon.ammo, 0, 255)), secondary_ammo = u8(clamp(me.secondary.ammo, 0, 255)),
		weapon = me.weapon.id, secondary_weapon = me.secondary.id, position = me.stance,
	}
	old := &g.old_snapshot
	if m.ammo == old.ammo && m.weapon == old.weapon && m.secondary_weapon == old.secondary_weapon && m.position == old.position do return
	old^ = m
	send_msg(g, conn, .Client_Sprite_Snapshot, &m)
}

// Where I am, when I moved or turned enough since I last said, or my keys changed, or
// I am jetting (always); the aim's test compares the mouse on the screen with the
// last one, as the original does, while the aim sent is in the world.
send_movement :: proc(g: ^Game, conn: ^connection.Connection, in_: ^input.Input, mouse: sim.Vec2) {
	me := &g.world.soldiers[g.me]
	x, y := net.aim_out(in_.aim)
	m := net.Client_Sprite_Snapshot_Mov{pos = me.pos, vel = me.vel, keys = net.encode_keys(in_.held + in_.pressed), aim_x = x, aim_y = y}
	old := &g.old_mov
	info := &g.ctx.weapons[me.weapon.id]
	mx, my := mouse.x, mouse.y
	ox, oy := f32(old.aim_x), f32(old.aim_y)
	aim_still := (info.fire_interval <= sim.FIRE_INTERVAL_NET && me.weapon.ammo > 0 && f32(i16(mx + 0.5)) == ox && f32(i16(my + 0.5)) == oy) ||
		(abs(mx - ox) < net.MOUSE_AIM_DELTA && abs(my - oy) < net.MOUSE_AIM_DELTA)
	changed := sim.vec2_length(m.pos - old.pos) > net.POS_DELTA || sim.vec2_length(m.vel - old.vel) > net.VEL_DELTA ||
		m.keys != old.keys || m.keys & net.KEY_JET != 0 || !aim_still
	if !changed do return
	old^ = m
	old.aim_x, old.aim_y = i16(clamp(mx, -32000, 32000)), i16(clamp(my, -32000, 32000)) // the screen's, as the original keeps it
	send_msg(g, conn, .Client_Sprite_Snapshot_Mov, &m)
}

send_msg :: proc(g: ^Game, conn: ^connection.Connection, id: net.Msg, m: ^$T) {
	net.put(&g.writer, id, m)
	connection.send(conn, net.writer_bytes(&g.writer), net.reliable(id))
}

// ---- receiving ----

// Everything the server sent since the last tick, in order.
receive :: proc(g: ^Game, conn: ^connection.Connection) {
	for data in connection.receive(conn) {
		r := net.reader_make(data)
		id := net.Msg(net.read_u8(&r))
		#partial switch id {
		case .Server_Sprite_Snapshot:
			m: net.Server_Sprite_Snapshot
			if net.get(&r, &m) do receive_snapshot(g, &m)
		case .Server_Sprite_Snapshot_Major:
			m: net.Server_Sprite_Snapshot_Major
			if net.get(&r, &m) do receive_major(g, &m)
		case .Server_Skeleton_Snapshot:
			m: net.Server_Skeleton_Snapshot
			if net.get(&r, &m) && int(m.num) < sim.MAX_PLAYERS {
				s := &g.world.soldiers[m.num]
				s.dead = true
				s.respawn_counter = i32(m.respawn_counter)
				s.weapon = sim.weapon_state(&g.ctx, .None)
			}
		case .Delta_Movement:
			m: net.Delta_Movement
			if net.get(&r, &m) do receive_delta_movement(g, &m)
		case .Delta_Weapons:
			m: net.Delta_Weapons
			if net.get(&r, &m) && int(m.num) < sim.MAX_PLAYERS && m.num != g.me do set_weapons(g, m.num, m.weapon, m.secondary_weapon, m.ammo)
		case .Bullet_Snapshot:
			m: net.Bullet_Snapshot
			if net.get(&r, &m) do receive_bullet(g, &m)
		case .Sprite_Death:
			m: net.Sprite_Death
			if net.get(&r, &m) do receive_death(g, &m)
		case .Heart_Beat:
			m: net.Heart_Beat
			if net.get(&r, &m) do receive_heartbeat(g, &m)
		case .Ping:
			m: net.Ping
			if net.get(&r, &m) {
				g.world.soldiers[g.me].ping_ticks = m.ping_ticks
				g.stop_moving = net.CLIENT_STOP_MOVE_RETRYS
				pong := net.Pong{ping_num = m.ping_num}
				send_msg(g, conn, .Pong, &pong)
			}
		case .Server_Thing_Snapshot:
			m: net.Server_Thing_Snapshot
			if net.get(&r, &m) do receive_thing(g, &m)
		case .Server_Thing_Must_Snapshot:
			m: net.Server_Thing_Must_Snapshot
			if net.get(&r, &m) do receive_thing_must(g, &m)
		case .Thing_Taken:
			m: net.Thing_Taken
			if net.get(&r, &m) do receive_thing_taken(g, &m)
		case .Flag_Info:
			m: net.Flag_Info
			if net.get(&r, &m) do receive_flag_info(g, &m)
		case .New_Player:
			m: net.New_Player
			if net.get(&r, &m) && int(m.num) < sim.MAX_PLAYERS && !g.world.soldiers[m.num].active do player_appears(g, m.num, m.team)
		case .Player_Disconnect:
			m: net.Player_Disconnect
			if net.get(&r, &m) && int(m.num) < sim.MAX_PLAYERS {
				g.world.soldiers[m.num].active = false
				g.players = max(g.players - 1, 0)
			}
		}
	}
}

// A soldier whole. One I have dead comes back to life where the snapshot has it.
// Another's place is taken as sent, unless its health differs from what I have (a
// hit is on its way to me): then only its aim, keys and gear. Mine keeps its place;
// the server's word is my health, my vest and my grenades. The server's tick becomes
// my clock.
receive_snapshot :: proc(g: ^Game, m: ^net.Server_Sprite_Snapshot) {
	if int(m.num) >= sim.MAX_PLAYERS || int(m.weapon) >= len(sim.Weapon_Id) || int(m.secondary_weapon) >= len(sim.Weapon_Id) do return
	s := &g.world.soldiers[m.num]
	if !s.active do return
	if s.dead do revive(g, m.num, m.pos, m.weapon, m.secondary_weapon)
	if m.num != g.me {
		if s.health == m.health {
			s.old_pos = s.pos
			s.pos, s.vel = m.pos, m.vel
		}
		g.others[m.num] = {buttons = net.decode_keys(m.keys), aim = net.aim_in(m.aim_x, m.aim_y)}
		set_weapons(g, m.num, m.weapon, m.secondary_weapon, m.ammo)
		s.stance = m.position
	}
	s.health, s.vest, s.grenades = m.health, m.vest, i32(m.grenades)
	g.client_ticks = m.server_ticks
	g.last_told = m.server_ticks
}

receive_major :: proc(g: ^Game, m: ^net.Server_Sprite_Snapshot_Major) {
	if int(m.num) >= sim.MAX_PLAYERS do return
	s := &g.world.soldiers[m.num]
	if !s.active do return
	if s.dead do revive(g, m.num, m.pos, s.weapon.id, s.secondary.id)
	if m.num != g.me {
		if s.health == m.health {
			s.old_pos = s.pos
			s.pos, s.vel = m.pos, m.vel
		}
		g.others[m.num] = {buttons = net.decode_keys(m.keys), aim = net.aim_in(m.aim_x, m.aim_y)}
		s.stance = m.position
	}
	s.health = m.health
	g.client_ticks = m.server_ticks
	g.last_told = m.server_ticks
}

// A dead soldier put somewhere by the server: alive again, there.
revive :: proc(g: ^Game, slot: u8, pos: sim.Vec2, primary, secondary: sim.Weapon_Id) {
	s := &g.world.soldiers[slot]
	sim.soldier_spawn(&g.ctx, s, pos, s.team, primary == .None ? .AK74 : primary, secondary == .None ? .Colt : secondary)
	g.prev[slot] = pos
	g.world.ragdolls[slot].active = false
	sim.emit(&g.events, sim.Respawn{target = slot, pos = pos})
}

set_weapons :: proc(g: ^Game, slot: u8, primary, secondary: sim.Weapon_Id, ammo: u8) {
	if int(primary) >= len(sim.Weapon_Id) || int(secondary) >= len(sim.Weapon_Id) do return
	s := &g.world.soldiers[slot]
	if s.weapon.id != primary do s.weapon = sim.weapon_state(&g.ctx, primary)
	if s.secondary.id != secondary do s.secondary = sim.weapon_state(&g.ctx, secondary)
	s.weapon.ammo = i32(ammo)
}

// Another's movement as it sent it, relayed: taken as is, unless older than the
// newest snapshot I have.
receive_delta_movement :: proc(g: ^Game, m: ^net.Delta_Movement) {
	if int(m.num) >= sim.MAX_PLAYERS || m.num == g.me || m.server_tick < g.last_told do return
	s := &g.world.soldiers[m.num]
	if !s.active || s.dead do return
	s.pos, s.vel = m.pos, m.vel
	g.others[m.num] = {buttons = net.decode_keys(m.keys), aim = net.aim_in(m.aim_x, m.aim_y)}
}

// Another's shot from a slow weapon: made here, then flown on by my round trip and
// its shooter's, meeting the others as they were that long ago (the bullet's lag) so
// it lands where the shooter saw it land. Its pellets are rebuilt from its seed.
receive_bullet :: proc(g: ^Game, m: ^net.Bullet_Snapshot) {
	w := &g.world
	if int(m.owner) >= sim.MAX_PLAYERS || int(m.weapon) >= len(sim.Weapon_Id) do return
	owner := &w.soldiers[m.owner]
	if !owner.active do return
	info := &g.ctx.weapons[m.weapon]
	lag := u8(min(int(owner.ping_ticks) + net.PING_TICKS_ADD, net.MAX_OLD_POS))
	ahead := int(w.soldiers[g.me].ping_ticks) + int(lag)
	spawn_ahead(g, m.pos, m.vel, m.weapon, m.owner, info.damage, lag, ahead)
	more := m.weapon == .Eagle ? 1 : info.style == .Shotgun ? 5 : 0
	if more == 0 do return
	rng := u64(m.seed) << 32 | u64(m.seed) | 1
	straight := m.vel - sim.bullet_spread(&rng, {}, info.spread)
	for _ in 0 ..< more do spawn_ahead(g, m.pos, sim.bullet_spread(&rng, straight, info.spread), m.weapon, m.owner, info.damage, lag, ahead)
}

spawn_ahead :: proc(g: ^Game, pos, vel: sim.Vec2, weapon: sim.Weapon_Id, owner: u8, damage: f32, lag: u8, ahead: int) {
	w := &g.world
	index, ok := sim.bullet_spawn(&g.ctx, w, pos, vel, weapon, owner, damage, &g.events, lag)
	if !ok do return
	for _ in 0 ..< ahead {
		if !w.bullets[index].active do break
		sim.bullet_tick(&g.ctx, w, u16(index), &g.events)
	}
}

// A death: the corpse as the server started it. My own exploding kill (an M79, a LAW,
// a grenade) is moved onto its victim and set off here, so the blast shows where it
// counted (the original's one lag hack).
receive_death :: proc(g: ^Game, m: ^net.Sprite_Death) {
	if int(m.num) >= sim.MAX_PLAYERS || int(m.weapon) >= len(sim.Weapon_Id) do return
	w := &g.world
	s := &w.soldiers[m.num]
	if !s.active do return
	s.health = m.health
	s.dead = true
	s.respawn_counter = i32(m.respawn_counter)
	s.weapon = sim.weapon_state(&g.ctx, .None)
	w.ragdolls[m.num] = {active = true, pos = m.pos, old_pos = m.old_pos, torn = transmute(sim.Torn)m.torn}
	sim.emit(&g.events, sim.Kill{killer = m.killer, target = m.num, weapon = m.weapon, pos = s.pos, health = m.health, part = m.part})
	if m.killer != g.me do return
	kind: sim.Explosion_Kind
	#partial switch m.weapon {
	case .M79, .LAW: kind = .M79
	case .Frag:      kind = .Frag
	case: return
	}
	for &b, i in w.bullets {
		if !b.active || b.owner != g.me || b.weapon != m.weapon do continue
		b.pos = m.pos[sim.RAGDOLL_HEAD]
		sim.explode(&g.ctx, w, &b, u16(i), kind, -1, -1, &g.events)
		sim.bullet_end(w, &b, u16(i), &g.events)
		break
	}
}

// The tally, packed by active soldier: unpacked over mine in the same order.
receive_heartbeat :: proc(g: ^Game, m: ^net.Heart_Beat) {
	w := &g.world
	w.round.scores[.Alpha] = i32(m.team_score[0])
	w.round.scores[.Bravo] = i32(m.team_score[1])
	k := 0
	for &s, i in w.soldiers {
		if !s.active do continue
		if k >= sim.MAX_PLAYERS || !m.active[k] do break
		s.kills, s.deaths, s.flags = i32(m.kills[k]), i32(m.deaths[k]), i32(m.caps[k])
		s.team = m.team[k]
		if u8(i) != g.me do s.ping_ticks = m.ping[k]
		k += 1
	}
	g.players = k
	g.heartbeat_at = w.tick
	g.had_heartbeat = true
}

// A thing as the server has it. One I did not have yet comes whole with the must
// snapshot; this one only moves it.
receive_thing :: proc(g: ^Game, m: ^net.Server_Thing_Snapshot) {
	if int(m.num) >= sim.MAX_THINGS || int(m.style) >= len(sim.Thing_Style) do return
	t := &g.world.things[m.num]
	if t.style == .None {
		if m.style == .None || m.style == .Weapon do return
		sim.thing_place(&g.ctx, t, m.style, m.pos[0])
	}
	t.style, t.owner, t.holder = m.style, m.owner, m.holder
	t.pos, t.old_pos = m.pos, m.old_pos
	t.static = false
}

receive_thing_must :: proc(g: ^Game, m: ^net.Server_Thing_Must_Snapshot) {
	if int(m.num) >= sim.MAX_THINGS || int(m.style) >= len(sim.Thing_Style) || m.style == .None || int(m.weapon) >= len(sim.Weapon_Id) do return
	t := &g.world.things[m.num]
	sim.thing_place(&g.ctx, t, m.style, m.pos[0], m.weapon)
	t.owner, t.holder, t.timeout, t.ammo = m.owner, m.holder, m.timeout, i32(m.ammo)
	t.pos, t.old_pos = m.pos, m.old_pos
}

// A thing taken, or gone: given here to whoever took it, as the server gave it.
receive_thing_taken :: proc(g: ^Game, m: ^net.Thing_Taken) {
	if int(m.num) >= sim.MAX_THINGS do return
	w := &g.world
	t := &w.things[m.num]
	if m.who == net.THING_GONE || int(m.who) >= sim.MAX_PLAYERS {
		sim.thing_clear(t)
		return
	}
	s := &w.soldiers[m.who]
	#partial switch m.style {
	case .Alpha_Flag, .Bravo_Flag:
		t.holder = m.who + 1
		t.static = false
		sim.emit(&g.events, sim.Flag_Grab{player = m.who, thing = m.num, flag = m.style, pos = t.pos[0]})
	case .Weapon:
		s.weapon = sim.weapon_state(&g.ctx, t.weapon)
		s.weapon.ammo = i32(m.ammo)
		sim.emit(&g.events, sim.Weapon_Pickup{player = m.who, thing = m.num, weapon = t.weapon, pos = t.pos[0]})
		sim.thing_clear(t)
	case .Medical_Kit, .Grenade_Kit, .Flamer_Kit, .Predator_Kit, .Vest_Kit, .Berserk_Kit, .Cluster_Kit:
		sim.kit_give(&g.ctx, w, s, m.style)
		sim.emit(&g.events, sim.Kit_Pickup{player = m.who, thing = m.num, kit = m.style, pos = t.pos[0]})
		sim.thing_clear(t)
	}
}

receive_flag_info :: proc(g: ^Game, m: ^net.Flag_Info) {
	if int(m.who) >= sim.MAX_PLAYERS do return
	pos := g.world.soldiers[m.who].pos
	switch m.style {
	case .Capture_Red:  sim.emit(&g.events, sim.Flag_Score{player = m.who, flag = .Alpha_Flag, pos = pos})
	case .Capture_Blue: sim.emit(&g.events, sim.Flag_Score{player = m.who, flag = .Bravo_Flag, pos = pos})
	case .Return_Red:   sim.emit(&g.events, sim.Flag_Return{player = m.who, flag = .Alpha_Flag, pos = pos})
	case .Return_Blue:  sim.emit(&g.events, sim.Flag_Return{player = m.who, flag = .Bravo_Flag, pos = pos})
	}
}

// ---- drawing ----

// Where a soldier is drawn this frame: between its last two ticks.
drawn_pos :: proc(g: ^Game, slot: int, alpha: f32) -> sim.Vec2 {
	s := &g.world.soldiers[slot]
	if s.dead {
		if r := &g.world.ragdolls[slot]; r.active do return r.old_pos[sim.RAGDOLL_HEAD] + (r.pos[sim.RAGDOLL_HEAD] - r.old_pos[sim.RAGDOLL_HEAD]) * alpha
		return s.pos
	}
	return g.prev[slot] + (s.pos - g.prev[slot]) * alpha
}
