package server

import "core:fmt"
import enet "vendor:ENet"
import "../shared/net"
import "../shared/sim"

// The server, as OpenSoldat's is (ServerLoop.pas, NetworkServer*.pas). Each client
// owns its soldier: its movement packets set the soldier's position, velocity, keys
// and aim as they say, unchecked, and between packets the soldier is stepped on with
// the keys held. Every tick the world steps, the hits become wounds here and nowhere
// else, and the messages go out on their schedules: every soldier to everyone in the
// snapshots, each movement packet relayed to those who can see the soldier, the
// dead's timers, the tally, the things, the pings. A slow weapon's shot arrives as a
// bullet, is checked, made here and relayed; a fast weapon's is made here from the
// keys like everywhere else. The bots are the server's own players.
Game :: struct {
	ctx:       sim.Context,
	level:     sim.Level,
	anims:     ^sim.Anims,
	skeletons: ^sim.Skeletons,
	world:     sim.World,
	events:    sim.Events,
	map_name:  string,
	clients:   [sim.MAX_PLAYERS]Client,
	dodge:     bool, // the bots dodge

	// what everyone was last told, for the change gates
	old_snapshot:      [sim.MAX_PLAYERS]net.Server_Sprite_Snapshot,
	time_snapshot:     [sim.MAX_PLAYERS]u32, // when a client's last snapshot came (Time_SpriteSnapshot)
	time_snapshot_mov: [sim.MAX_PLAYERS]u32, // and its last movement packet
	old_movement:      [sim.MAX_PLAYERS][sim.MAX_PLAYERS]net.Delta_Movement, // [receiver][soldier]
	old_weapons:       [sim.MAX_PLAYERS][sim.MAX_PLAYERS]net.Delta_Weapons,
	thing_was:         [sim.MAX_THINGS]Thing_Was, // a tick ago: what appeared, what moved
	relayed_seed:      [sim.MAX_PLAYERS]u16,      // a bot's newest shot relayed: one message per shot

	writer: net.Writer,
}

Thing_Was :: struct {
	style: sim.Thing_Style,
	pos:   sim.Vec2,
}

Client :: struct {
	connected:      bool,
	bot:            Maybe(Bot),  // played by the server itself: no peer, no packets
	cmd:            sim.Command, // the keys and aim it last sent, held on (DecodeKeys)
	prone:          bool,        // its Position said prone, or no longer: the toggle for the next tick
	fire_forced:    bool,        // a shot arrived: the next tick fires, for the recoil and the ammo (Control.Fire)
	camera:         sim.Vec2,    // the midpoint of its view: its soldier and its aim
	ping_time:      [net.PING_SLOTS]u32,
	ping_num:       u8,
	no_update_time: u32,         // ticks since its last pong
	seeds:          [net.BULLET_CHECK_SEEDS]u16, // its last shots' numbers
	seed_at:        int,
	last_fire:      u32,
	warnings:       int,
}

game_init :: proc(g: ^Game, base, map_name: string, bots: int, dodge: bool) {
	g.map_name = map_name
	g.dodge = dodge
	if level, ok := sim.level_load_file(base, map_name); ok do g.level = level
	if anims, ok := sim.anims_load_files(base); ok do g.anims = anims
	if sk, ok := sim.skeletons_load_files(base); ok do g.skeletons = sk
	g.ctx.level = &g.level
	g.ctx.anims = g.anims
	g.ctx.skeletons = g.skeletons
	sim.weapons_default(&g.ctx.weapons)
	sim.world_init(&g.world, 1)
	g.world.net.server = true
	sim.round_init(&g.world.round)
	sim.things_spawn(&g.ctx, &g.world)
	for _ in 0 ..< bots do add_bot(g)
}

// ---- receiving ----

// Every packet since the last tick. Peers that left leave.
receive_client_messages :: proc(g: ^Game, host: ^Host) {
	for p in host_receive(host) {
		r := net.reader_make(p.data)
		id := net.Msg(net.read_u8(&r))
		if p.slot == NO_SLOT {
			if id == .Hello {
				if m, ok := net.decode_hello(&r); ok do join(g, host, p.peer, m)
			}
			continue
		}
		c := &g.clients[p.slot]
		s := &g.world.soldiers[p.slot]
		#partial switch id {
		case .Client_Sprite_Snapshot:
			m: net.Client_Sprite_Snapshot
			if net.get(&r, &m) do receive_snapshot(g, host, p.slot, &m)
		case .Client_Sprite_Snapshot_Mov:
			m: net.Client_Sprite_Snapshot_Mov
			if net.get(&r, &m) do receive_movement(g, host, p.slot, &m)
		case .Client_Sprite_Snapshot_Dead:
			m: net.Client_Sprite_Snapshot_Dead
			_ = net.get(&r, &m) // it says it is dead; the server knows
		case .Bullet_Snapshot:
			m: net.Client_Bullet_Snapshot
			if net.get(&r, &m) do receive_bullet(g, host, p.slot, &m)
		case .Pong:
			m: net.Pong
			if net.get(&r, &m) && m.ping_num < net.PING_SLOTS {
				s.ping_ticks = u8(min(g.world.tick - c.ping_time[m.ping_num], 255))
				c.no_update_time = 0
			}
		}
	}
	for slot in host.left do leave(g, host, slot)
}

// What the client holds: taken as it says. Prone is a toggle: pressed for the next
// tick when its position and the server's disagree.
receive_snapshot :: proc(g: ^Game, host: ^Host, slot: u8, m: ^net.Client_Sprite_Snapshot) {
	s := &g.world.soldiers[slot]
	if !s.active || s.dead || int(m.weapon) >= len(sim.Weapon_Id) || int(m.secondary_weapon) >= len(sim.Weapon_Id) do return
	if m.weapon != s.weapon.id do s.weapon = sim.weapon_state(&g.ctx, m.weapon)
	if m.secondary_weapon != s.secondary.id do s.secondary = sim.weapon_state(&g.ctx, m.secondary_weapon)
	s.weapon.ammo = i32(m.ammo)
	s.secondary.ammo = i32(m.secondary_ammo)
	g.clients[slot].prone = (m.position == .Prone) != (s.stance == .Prone)
	sprite_deltas(g, host, slot)
	g.time_snapshot[slot] = g.world.tick
}

// Where the client is: taken as it says (CheckOutOfBounds only keeps it on the map,
// ten maps wide). Relayed at once to those who can see it.
receive_movement :: proc(g: ^Game, host: ^Host, slot: u8, m: ^net.Client_Sprite_Snapshot_Mov) {
	c := &g.clients[slot]
	s := &g.world.soldiers[slot]
	if !s.active || s.dead do return
	s.pos = in_bounds(g, m.pos)
	s.vel = in_bounds(g, m.vel)
	c.cmd.aim = in_bounds(g, net.aim_in(m.aim_x, m.aim_y))
	c.cmd.buttons = net.decode_keys(m.keys)
	c.camera = (s.pos + c.cmd.aim) / 2
	sprite_deltas(g, host, slot)
	g.time_snapshot_mov[slot] = g.world.tick
}

in_bounds :: proc(g: ^Game, v: sim.Vec2) -> sim.Vec2 {
	bound := f32(10 * g.level.sectors_num * g.level.sectors_division - 50)
	v := v
	if abs(v.x) > bound do v.x = 1
	if abs(v.y) > bound do v.y = 1
	return v
}

// A slow weapon's shot, checked before it is made (NetworkServerBullet.pas): not a
// shot it already sent, a weapon it holds, no faster than the weapon shoots, from
// where it stands, not sooner after the last than the weapon allows (three strikes),
// a grenade not within six ticks of the last. Then made here, with the pellets
// rebuilt from the shot's seed, and relayed to those who can see it.
receive_bullet :: proc(g: ^Game, host: ^Host, slot: u8, m: ^net.Client_Bullet_Snapshot) {
	c := &g.clients[slot]
	s := &g.world.soldiers[slot]
	w := &g.world
	if !s.active || s.dead || int(m.weapon) >= len(sim.Weapon_Id) do return
	for seed in c.seeds do if seed == m.seed do return
	c.seeds[c.seed_at] = m.seed
	c.seed_at = (c.seed_at + 1) % net.BULLET_CHECK_SEEDS
	info := &g.ctx.weapons[m.weapon]
	grenade := m.weapon == .Frag || m.weapon == .Cluster_Nade
	thrown := m.weapon == .Thrown_Knife && s.weapon.id == .Knife
	if !grenade && !thrown && m.weapon != s.weapon.id do return
	if !grenade && sim.vec2_length(m.vel) > info.speed + 10 * info.inherit do return
	if sim.vec2_length(m.pos - s.pos) > net.MUZZLE_REACH do return
	if grenade {
		if w.tick - c.last_fire < 6 do return
	} else if f32(w.tick - c.last_fire) < f32(info.fire_interval) * 0.85 {
		c.warnings += 1
		if c.warnings > net.BULLET_WARNINGS do return
	}
	c.last_fire = w.tick
	lag := u8(clamp(i64(w.tick) - i64(m.client_ticks), 0, net.MAX_OLD_POS)) // PingTicksB
	s.bullet_count = m.seed
	index, ok := sim.bullet_spawn(&g.ctx, w, m.pos, m.vel, m.weapon, slot, info.damage, &g.events, lag)
	if !ok do return
	spawn_pellets(&g.ctx, w, m.weapon, m.pos, m.vel, m.seed, slot, lag, &g.events)
	c.fire_forced = true
	relay_bullet(g, host, &w.bullets[index], forced = false)
}

// The rest of a shot's pellets, from its seed: the Eagles' second, the shotgun's five
// more. The one that came is spread already; the seed gives that spread back first,
// so the straight shot is recovered, and then the others'.
spawn_pellets :: proc(ctx: ^sim.Context, w: ^sim.World, weapon: sim.Weapon_Id, pos, vel: sim.Vec2, seed: u16, owner: u8, lag: u8, events: ^sim.Events) {
	info := &ctx.weapons[weapon]
	more := weapon == .Eagle ? 1 : info.style == .Shotgun ? 5 : 0
	if more == 0 do return
	rng := u64(seed) << 32 | u64(seed) | 1
	straight := vel - sim.bullet_spread(&rng, {}, info.spread)
	for _ in 0 ..< more {
		if _, ok := sim.bullet_spawn(ctx, w, pos, sim.bullet_spread(&rng, straight, info.spread), weapon, owner, info.damage, events, lag); !ok do return
	}
}

// A newcomer: a slot, a soldier on the smaller team's spawn, the welcome with who is
// playing, the things as they stand, and the others told of it.
join :: proc(g: ^Game, host: ^Host, peer: ^enet.Peer, m: net.Hello) {
	if m.version != net.VERSION || m.layout != net.LAYOUT {
		net.encode_denied(&g.writer, m.version != net.VERSION ? "wrong version" : "different build")
		peer_send(peer, net.writer_bytes(&g.writer), reliable = true)
		return
	}
	slot := free_slot(g)
	if slot == NO_SLOT {
		net.encode_denied(&g.writer, "server full")
		peer_send(peer, net.writer_bytes(&g.writer), reliable = true)
		return
	}
	host_bind(host, slot, peer)
	g.clients[slot] = {connected = true}
	g.old_snapshot[slot] = {}
	g.time_snapshot[slot], g.time_snapshot_mov[slot] = 0, 0
	for i in 0 ..< sim.MAX_PLAYERS {
		g.old_movement[slot][i], g.old_movement[i][slot] = {}, {}
		g.old_weapons[slot][i], g.old_weapons[i][slot] = {}, {}
	}
	team := spawn_newcomer(g, slot)
	g.clients[slot].camera = g.world.soldiers[slot].pos
	fmt.printfln("%s joined as slot %d on %v", m.name, slot, team)

	welcome := net.Welcome{slot = slot, server_ticks = i32(g.world.tick), map_name = g.map_name}
	for &s, i in g.world.soldiers do if s.active do welcome.teams[i] = s.team
	g.writer.len = 0
	g.writer.overflow = false
	net.encode_welcome(&g.writer, &welcome)
	host_send(host, slot, net.writer_bytes(&g.writer), reliable = true)
	for &t, i in g.world.things do if t.style != .None do send_thing_must(g, host, slot, &t, u8(i))
	announce := net.New_Player{num = slot, team = team}
	for &c, j in g.clients do if c.connected && c.bot == nil && u8(j) != slot do send(g, host, u8(j), .New_Player, &announce)
}

// A bot, in the first free slot, on the smaller team.
add_bot :: proc(g: ^Game) {
	slot := free_slot(g)
	if slot == NO_SLOT do return
	brain: Bot
	bot_init(&brain, g.dodge)
	g.clients[slot] = {connected = true, bot = brain}
	team := spawn_newcomer(g, slot)
	g.world.net.mine += {int(slot)} // its shots are the server's to make
	fmt.printfln("a bot joined as slot %d on %v", slot, team)
}

free_slot :: proc(g: ^Game) -> u8 {
	for &c, i in g.clients do if !c.connected do return u8(i)
	return NO_SLOT
}

spawn_newcomer :: proc(g: ^Game, slot: u8) -> sim.Team {
	alpha, bravo := 0, 0
	for &s in g.world.soldiers {
		if !s.active do continue
		if s.team == .Alpha do alpha += 1
		if s.team == .Bravo do bravo += 1
	}
	team := alpha <= bravo ? sim.Team.Alpha : sim.Team.Bravo
	pos := sim.level_spawn_point(g.ctx.level, team, &g.world.rng)
	sim.soldier_spawn(&g.ctx, &g.world.soldiers[slot], pos, team, .AK74, .Colt)
	return team
}

leave :: proc(g: ^Game, host: ^Host, slot: u8) {
	g.world.soldiers[slot].active = false
	g.clients[slot] = {}
	fmt.printfln("slot %d left", slot)
	gone := net.Player_Disconnect{num = slot}
	for &c, j in g.clients do if c.connected && c.bot == nil do send(g, host, u8(j), .Player_Disconnect, &gone)
}

// ---- the tick ----

// Every soldier stepped on its keys: a client's as it last sent them, held on, unless
// its pongs stopped coming (then it stands, and after long enough it is dropped); a
// bot's from its brain. Then the hits become wounds, the corpses start, and what
// happened goes out.
tick :: proc(g: ^Game, host: ^Host) {
	w := &g.world
	cmds: [sim.MAX_PLAYERS]sim.Command
	for &c, i in g.clients {
		if !c.connected do continue
		if brain, is_bot := &c.bot.?; is_bot {
			cmds[i] = bot_command(brain, &g.ctx, w, u8(i))
			c.cmd = cmds[i]
			c.camera = (w.soldiers[i].pos + cmds[i].aim) / 2
			continue
		}
		c.no_update_time += 1
		if c.no_update_time > net.DISCONNECTION_TIME {
			host_drop(host, u8(i))
			continue
		}
		if c.no_update_time >= net.CLIENT_STOP_MOVE_RETRYS do continue // stands still
		cmds[i] = c.cmd
		if c.prone {
			cmds[i].buttons += {.Prone}
			c.prone = false
		}
		if c.fire_forced {
			cmds[i].buttons += {.Fire}
			c.fire_forced = false
		}
	}
	sim.step(&g.ctx, w, cmds[:], &g.events)
	reported := g.events.count
	for i in 0 ..< reported {
		if hit, is_hit := g.events.items[i].(sim.Hit); is_hit do sim.damage_apply(&g.ctx, w, hit, &g.events)
	}
	sim.ragdolls_update(&g.ctx, w)
	tell_events(g, host)
	tell_things_appearing(g, host)
	for &was, i in g.thing_was do was = {g.world.things[i].style, g.world.things[i].pos[0]}
}

// What this tick decided: a death, with the corpse; a respawn, as a snapshot of the
// one soldier; a pickup; a flag scored or returned; and a bot's slow shot, relayed
// like a player's would be.
tell_events :: proc(g: ^Game, host: ^Host) {
	w := &g.world
	for e in sim.events_slice(&g.events) {
		#partial switch v in e {
		case sim.Kill:
			r := &w.ragdolls[v.target]
			m := net.Sprite_Death{num = v.target, killer = v.killer, weapon = v.weapon, part = v.part, torn = transmute(u32)r.torn,
				pos = r.pos, old_pos = r.old_pos, health = v.health, respawn_counter = i16(w.soldiers[v.target].respawn_counter)}
			send_all(g, host, .Sprite_Death, &m)
		case sim.Respawn:
			m := major_of(g, v.target)
			send_all(g, host, .Server_Sprite_Snapshot_Major, &m)
		case sim.Kit_Pickup:
			m := net.Thing_Taken{num = v.thing, who = v.player, style = v.kit}
			send_all(g, host, .Thing_Taken, &m)
		case sim.Weapon_Pickup:
			m := net.Thing_Taken{num = v.thing, who = v.player, style = .Weapon, ammo = u8(clamp(w.soldiers[v.player].weapon.ammo, 0, 255))}
			send_all(g, host, .Thing_Taken, &m)
		case sim.Flag_Grab:
			m := net.Thing_Taken{num = v.thing, who = v.player, style = v.flag}
			send_all(g, host, .Thing_Taken, &m)
		case sim.Flag_Score:
			m := net.Flag_Info{style = v.flag == .Alpha_Flag ? .Capture_Red : .Capture_Blue, who = v.player}
			send_all(g, host, .Flag_Info, &m)
		case sim.Flag_Return:
			m := net.Flag_Info{style = v.flag == .Alpha_Flag ? .Return_Red : .Return_Blue, who = v.player}
			send_all(g, host, .Flag_Info, &m)
		case sim.Bullet_Spawn:
			// a bot's shot from a slow weapon: relayed as a player's is, once per shot
			b := &w.bullets[v.id]
			if g.clients[v.player].bot == nil || g.ctx.weapons[v.weapon].fire_interval <= sim.FIRE_INTERVAL_NET do continue
			if b.seed == g.relayed_seed[v.player] do continue
			g.relayed_seed[v.player] = b.seed
			relay_bullet(g, host, b, forced = false)
		}
	}
}

// A thing that was not there a tick ago goes out whole.
tell_things_appearing :: proc(g: ^Game, host: ^Host) {
	for &t, i in g.world.things {
		if t.style == .None || t.style == g.thing_was[i].style do continue
		for &c, j in g.clients do if c.connected && c.bot == nil do send_thing_must(g, host, u8(j), &t, u8(i))
	}
}

// ---- sending ----

// On the schedules of ServerLoop.pas, scaled by how many are playing.
send_all_scheduled :: proc(g: ^Game, host: ^Host) {
	tick := g.world.tick
	a := net.server_adjust(player_count(g))
	snapshot := net.due(tick, net.T_SNAPSHOT, a)
	major := !snapshot && net.due(tick, net.T_MAJOR_SNAPSHOT, a)
	if snapshot do send_snapshots(g, host)
	if major do send_major_snapshots(g, host)
	if net.due(tick, net.T_DEAD_SNAPSHOT, a) do send_skeleton_snapshots(g, host)
	if net.due(tick, net.T_HEARTBEAT, a) do send_heartbeat(g, host)
	if !snapshot && !major && net.due(tick, net.T_DELTA, a) {
		for &c, i in g.clients do if c.connected && c.bot != nil do sprite_deltas(g, host, u8(i))
	}
	if net.due(tick, net.T_PING, a) do send_pings(g, host)
	if net.due(tick, net.T_THING_SNAPSHOT, a) do send_thing_snapshots(g, host)
}

player_count :: proc(g: ^Game) -> (n: int) {
	for &c in g.clients do if c.connected do n += 1
	return
}

snapshot_of :: proc(g: ^Game, i: u8) -> net.Server_Sprite_Snapshot {
	s := &g.world.soldiers[i]
	c := &g.clients[i]
	x, y := net.aim_out(c.cmd.aim)
	return {
		num = i, pos = s.pos, vel = s.vel, aim_x = x, aim_y = y, position = s.stance,
		keys = net.encode_keys(c.cmd.buttons), vest = s.vest, health = s.health,
		ammo = u8(clamp(s.weapon.ammo, 0, 255)), grenades = u8(clamp(s.grenades, 0, 255)),
		weapon = s.weapon.id, secondary_weapon = s.secondary.id, server_ticks = i32(g.world.tick),
	}
}

major_of :: proc(g: ^Game, i: u8) -> net.Server_Sprite_Snapshot_Major {
	s := &g.world.soldiers[i]
	c := &g.clients[i]
	x, y := net.aim_out(c.cmd.aim)
	return {num = i, pos = s.pos, vel = s.vel, health = s.health, aim_x = x, aim_y = y, position = s.stance,
		keys = net.encode_keys(c.cmd.buttons), server_ticks = i32(g.world.tick)}
}

// Every living soldier, to everyone, when it changed since it was last told or has
// not been told for 30 ticks (ServerSpriteSnapshot's gate).
send_snapshots :: proc(g: ^Game, host: ^Host) {
	tick := g.world.tick
	for &s, i in g.world.soldiers {
		if !s.active || s.dead || s.team == .Spectator do continue
		m := snapshot_of(g, u8(i))
		old := &g.old_snapshot[i]
		changed := sim.vec2_length(m.vel - old.vel) > net.VEL_DELTA ||
			tick - g.time_snapshot_mov[i] > 30 || tick - g.time_snapshot[i] > 30 ||
			m.health != old.health || m.position != old.position || m.keys != old.keys ||
			m.weapon != old.weapon || m.secondary_weapon != old.secondary_weapon ||
			m.ammo != old.ammo || m.grenades != old.grenades || m.vest != old.vest
		if !changed do continue
		old^ = m
		send_all(g, host, .Server_Sprite_Snapshot, &m)
	}
}

send_major_snapshots :: proc(g: ^Game, host: ^Host) {
	tick := g.world.tick
	for &s, i in g.world.soldiers {
		if !s.active || s.dead || s.team == .Spectator do continue
		m := major_of(g, u8(i))
		old := &g.old_snapshot[i]
		changed := sim.vec2_length(m.vel - old.vel) > net.VEL_DELTA || tick - g.time_snapshot_mov[i] > 30 ||
			m.position != old.position || m.health != old.health || m.keys != old.keys
		if !changed do continue
		old.pos, old.vel, old.health, old.keys = m.pos, m.vel, m.health, m.keys // the major keeps only these of the old
		send_all(g, host, .Server_Sprite_Snapshot_Major, &m)
	}
}

send_skeleton_snapshots :: proc(g: ^Game, host: ^Host) {
	for &s, i in g.world.soldiers {
		if !s.active || !s.dead || s.team == .Spectator do continue
		m := net.Server_Skeleton_Snapshot{num = u8(i), respawn_counter = i16(s.respawn_counter)}
		send_all(g, host, .Server_Skeleton_Snapshot, &m)
	}
}

// A soldier's movement to everyone who can see it (its box about their camera), and
// its weapons when they changed. A player's goes always; a bot's when it moved or
// turned enough and its keys changed.
sprite_deltas :: proc(g: ^Game, host: ^Host, i: u8) {
	s := &g.world.soldiers[i]
	ci := &g.clients[i]
	x, y := net.aim_out(ci.cmd.aim)
	mov := net.Delta_Movement{num = i, pos = s.pos, vel = s.vel, keys = net.encode_keys(ci.cmd.buttons), aim_x = x, aim_y = y, server_tick = i32(g.world.tick)}
	weapons := net.Delta_Weapons{num = i, weapon = s.weapon.id, secondary_weapon = s.secondary.id, ammo = u8(clamp(s.weapon.ammo, 0, 255))}
	for &c, j in g.clients {
		if !c.connected || c.bot != nil || u8(j) == i || !point_visible(s.pos, c.camera) do continue
		old := &g.old_movement[j][i]
		if ci.bot == nil || ((sim.vec2_length(mov.pos - old.pos) > net.POS_DELTA || sim.vec2_length(mov.vel - old.vel) > net.VEL_DELTA) && mov.keys != old.keys) {
			old^ = mov
			send(g, host, u8(j), .Delta_Movement, &mov)
		}
		oldw := &g.old_weapons[j][i]
		if weapons.weapon != oldw.weapon || weapons.secondary_weapon != oldw.secondary_weapon {
			oldw^ = weapons
			send(g, host, u8(j), .Delta_Weapons, &weapons)
		}
	}
}

// Whether a point is within a client's view, as the server guesses it (PointVisible).
point_visible :: proc(p, camera: sim.Vec2) -> bool {
	return abs(p.x - camera.x) < net.MAX_GAME_WIDTH && abs(p.y - camera.y) < net.GAME_HEIGHT
}

// The tally, packed: the k-th entry is the k-th active soldier's.
send_heartbeat :: proc(g: ^Game, host: ^Host) {
	m: net.Heart_Beat
	m.team_score[0] = u16(clamp(g.world.round.scores[.Alpha], 0, 65535))
	m.team_score[1] = u16(clamp(g.world.round.scores[.Bravo], 0, 65535))
	k := 0
	for &s in g.world.soldiers {
		if !s.active do continue
		m.active[k] = true
		m.kills[k] = u16(clamp(s.kills, 0, 65535))
		m.deaths[k] = u16(clamp(s.deaths, 0, 65535))
		m.caps[k] = u8(clamp(s.flags, 0, 255))
		m.team[k] = s.team
		m.ping[k] = s.ping_ticks
		m.real_ping[k] = u16(s.ping_ticks) * 1000 / sim.TICK_RATE
		k += 1
	}
	send_all(g, host, .Heart_Beat, &m)
}

// A ping to each player, reliably, its slot remembered: the pong measures the trip.
send_pings :: proc(g: ^Game, host: ^Host) {
	for &c, i in g.clients {
		if !c.connected || c.bot != nil do continue
		c.ping_time[c.ping_num] = g.world.tick
		m := net.Ping{ping_ticks = g.world.soldiers[i].ping_ticks, ping_num = c.ping_num}
		send(g, host, u8(i), .Ping, &m)
		c.ping_num = (c.ping_num + 1) % net.PING_SLOTS
	}
}

// The things to each player: the flags always, the rest when they move and are in
// view; and only when they moved since the last tick, or, every other tick, a flag.
send_thing_snapshots :: proc(g: ^Game, host: ^Host) {
	even := g.world.tick % 2 == 0
	for &c, j in g.clients {
		if !c.connected || c.bot != nil do continue
		for &t, i in g.world.things {
			if t.style == .None do continue
			flag := sim.is_flag(t.style)
			if !flag && ((t.static && t.style != .Stat_Gun) || !point_visible(t.pos[0], c.camera)) do continue
			moved := sim.vec2_length(t.pos[0] - g.thing_was[i].pos) > net.MIN_MOVE_DELTA
			if !moved && !(even && flag) do continue
			m := net.Server_Thing_Snapshot{num = u8(i), owner = t.owner, style = t.style, holder = t.holder, pos = t.pos, old_pos = t.old_pos}
			send(g, host, u8(j), .Server_Thing_Snapshot, &m)
		}
	}
}

send_thing_must :: proc(g: ^Game, host: ^Host, to: u8, t: ^sim.Thing, index: u8) {
	m := net.Server_Thing_Must_Snapshot{num = index, owner = t.owner, style = t.style, holder = t.holder, pos = t.pos, old_pos = t.old_pos,
		timeout = t.timeout, weapon = t.weapon, ammo = i16(clamp(t.ammo, -32768, 32767))}
	send(g, host, to, .Server_Thing_Must_Snapshot, &m)
}

// A bullet to every player who can see it (or to everyone, forced), not its owner.
// The owner's ammo goes down here, as in the original (a forced one costs nothing).
relay_bullet :: proc(g: ^Game, host: ^Host, b: ^sim.Bullet, forced: bool) {
	m := net.Bullet_Snapshot{owner = b.owner, weapon = b.weapon, pos = b.pos, vel = b.vel, seed = b.seed, forced = forced}
	if !forced {
		s := &g.world.soldiers[b.owner]
		if s.weapon.ammo > 0 do s.weapon.ammo -= 1
	}
	for &c, j in g.clients {
		if !c.connected || c.bot != nil || (u8(j) == b.owner && !forced) do continue
		if !forced && !sim.bullet_visible(b.pos, b.vel, c.camera, {net.MAX_GAME_WIDTH, net.GAME_HEIGHT}) do continue
		send(g, host, u8(j), .Bullet_Snapshot, &m)
	}
}

send :: proc(g: ^Game, host: ^Host, to: u8, id: net.Msg, m: ^$T) {
	net.put(&g.writer, id, m)
	host_send(host, to, net.writer_bytes(&g.writer), net.reliable(id))
}

send_all :: proc(g: ^Game, host: ^Host, id: net.Msg, m: ^$T) {
	for &c, j in g.clients do if c.connected && c.bot == nil do send(g, host, u8(j), id, m)
}
