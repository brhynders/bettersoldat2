// Package net is the wire protocol: OpenSoldat's, copied message for message from the
// upstream source (commit c993a44 of the fork, its NetworkClient*/NetworkServer* and
// Net.pas), with its message ids, fields and sizes, and its rules for when each goes.
// The transport is ENet in place of GameNetworkingSockets, with the same two kinds of
// delivery the original uses: unreliable for everything that moves, reliable for the
// rest. A message is one packed record behind its id byte, and a packet whose size is
// not exactly the record's is dropped (VerifyPacket).
//
// The model: a client owns its own soldier and tells the server where it is, which
// the server takes as the truth. The server sends everyone every soldier now and then
// (the snapshots), and relays each client's movement packet to those who can see it
// (the deltas); a client steps everyone else on from the last keys it heard. Slow
// weapons' shots cross the wire as bullets; fast weapons' are made everywhere from the
// Fire key. Only the server wounds; a client learns its health from the snapshots.
package net

import "../sim"

VERSION      :: 4
DEFAULT_PORT :: 23073

CHANNEL_UNRELIABLE :: 0
CHANNEL_RELIABLE   :: 1
CHANNEL_COUNT      :: 2

// The layout the state crosses the wire in, checked at the hello.
LAYOUT :: u32(size_of(sim.Soldier)) << 16 | u32(size_of(sim.Thing)) << 8 | u32(size_of(sim.Bullet))

// OpenSoldat's MsgID_ numbers. The handshake reuses RequestGame, PlayersList and
// UnAccepted; the rest are the gameplay messages, by their numbers.
Msg :: enum u8 {
	Heart_Beat                   = 2,
	Server_Sprite_Snapshot       = 3,
	Client_Sprite_Snapshot       = 4,
	Bullet_Snapshot              = 5, // both ways, two records: the size tells them apart
	Server_Skeleton_Snapshot     = 7,
	Server_Thing_Snapshot        = 9,
	Thing_Taken                  = 12,
	Sprite_Death                 = 13,
	Welcome                      = 16, // PlayersList
	New_Player                   = 17,
	Player_Disconnect            = 19,
	Delta_Movement               = 21,
	Delta_Weapons                = 25,
	Ping                         = 30,
	Pong                         = 31,
	Flag_Info                    = 32,
	Server_Thing_Must_Snapshot   = 33,
	Server_Sprite_Snapshot_Major = 41,
	Client_Sprite_Snapshot_Mov   = 42,
	Client_Sprite_Snapshot_Dead  = 43,
	Denied                       = 44, // UnAccepted
	Hello                        = 58, // RequestGame
}

// ---- the constants the rules use (Constants.pas, Cvar.pas) ----

POS_DELTA        :: 60.0 // a client sends its movement when it moved further than this...
VEL_DELTA        :: 0.27 // ...or its velocity changed more than this
MOUSE_AIM_DELTA  :: 30   // ...or its aim moved more than this on the screen
MIN_MOVE_DELTA   :: 0.63 // a thing that moved less is not sent
MAX_GAME_WIDTH   :: 480 * 1.78 // the server's guess of a client's view: half its width...
GAME_HEIGHT      :: 480.0      // ...and half its height, about the camera
MUZZLE_REACH     :: 366.0      // a shot born further from its shooter is refused

// Every so many ticks, on the Internet (the LAN rates are not copied).
T_SNAPSHOT       :: 35  // net_t1_snapshot
T_MAJOR_SNAPSHOT :: 19  // net_t1_majorsnapshot
T_DEAD_SNAPSHOT  :: 50  // net_t1_deadsnapshot
T_HEARTBEAT      :: 135 // net_t1_heartbeat
T_DELTA          :: 4   // net_t1_delta: the bots' deltas
T_PING           :: 21  // net_t1_ping
T_THING_SNAPSHOT :: 31  // net_t1_thingsnapshot

CLIENT_STOP_MOVE_RETRYS :: 90  // ticks without a ping before a client freezes, and the server stops stepping it
CONNECTION_PROBLEM_TIME :: 240 // ticks without a heartbeat before a client freezes for good
DISCONNECTION_TIME      :: 900 // ticks without a pong before the server drops a client
PING_SLOTS              :: 8   // pings in flight per client
PING_TICKS_ADD          :: 2   // a client adds this to a shooter's ping when flying its bullet on
BULLET_CHECK_SEEDS      :: 20  // a shot's seed must not be among the last so many
BULLET_WARNINGS         :: 3   // shots too soon after the last, before they are refused
MAX_OLD_POS             :: 125 // ticks of lag a bullet may carry

// The packet-rate scale by how many are playing: fewer players, more packets.
server_adjust :: proc(players: int) -> f32 { return players < 5 ? 0.66 : players < 9 ? 0.75 : 1 }
client_adjust :: proc(players: int) -> f32 { return players < 5 ? 0.75 : players < 9 ? 0.87 : 1 }

// A tick on a schedule: every `every` ticks, scaled.
due :: proc(tick: u32, every: int, adjust: f32, phase: u32 = 0) -> bool {
	period := u32(max(int(f32(every) * adjust + 0.5), 1))
	return tick % period == phase
}

// ---- the keys on the wire: Keys16 (NetworkUtils.pas EncodeKeys) ----

KEY_BITS := [?]struct { bit: u16, button: sim.Button }{
	{1 << 0, .Left}, {1 << 1, .Right}, {1 << 2, .Jump}, {1 << 3, .Crouch}, {1 << 4, .Fire},
	{1 << 5, .Jet}, {1 << 6, .Throw}, {1 << 7, .Change}, {1 << 8, .Drop}, {1 << 9, .Reload},
	{1 << 10, .Flag_Throw},
}
KEY_JET :: u16(1 << 5)

encode_keys :: proc(b: sim.Buttons) -> (k: u16) {
	for e in KEY_BITS do if e.button in b do k |= e.bit
	return
}

decode_keys :: proc(k: u16) -> (b: sim.Buttons) {
	for e in KEY_BITS do if k & e.bit != 0 do b += {e.button}
	return
}

// The aim on the wire: whole units, 16 bits each.
aim_out :: proc(v: sim.Vec2) -> (x, y: i16) {
	return i16(clamp(v.x, -32000, 32000)), i16(clamp(v.y, -32000, 32000))
}

aim_in :: proc(x, y: i16) -> sim.Vec2 {
	return {f32(x), f32(y)}
}

// ---- the handshake (reliable) ----

MAX_NAME :: 24

Hello :: struct {
	version: u16,
	layout:  u32,
	name:    string,
}

// PlayersList: the newcomer's slot, the server's tick, the map, and who is playing.
Welcome :: struct {
	slot:         u8,
	server_ticks: i32,
	map_name:     string,
	teams:        [sim.MAX_PLAYERS]sim.Team, // .None for an empty slot
}

encode_hello :: proc(w: ^Writer, name: string) {
	write_u8(w, u8(Msg.Hello))
	write_u16(w, VERSION)
	write_u32(w, LAYOUT)
	write_string(w, name[:min(len(name), MAX_NAME)])
}

decode_hello :: proc(r: ^Reader) -> (m: Hello, ok: bool) {
	m.version = read_u16(r)
	m.layout = read_u32(r)
	m.name = read_string(r)
	return m, r.ok
}

encode_welcome :: proc(w: ^Writer, m: ^Welcome) {
	write_u8(w, u8(Msg.Welcome))
	write_u8(w, m.slot)
	write_u32(w, u32(m.server_ticks))
	write_string(w, m.map_name)
	for t in m.teams do write_u8(w, u8(t))
}

decode_welcome :: proc(r: ^Reader) -> (m: Welcome, ok: bool) {
	m.slot = read_u8(r)
	m.server_ticks = i32(read_u32(r))
	m.map_name = read_string(r)
	for &t in m.teams do t = sim.Team(read_u8(r))
	return m, r.ok
}

encode_denied :: proc(w: ^Writer, reason: string) {
	write_u8(w, u8(Msg.Denied))
	write_string(w, reason)
}

// ---- the records: one packed struct per message, sent and read whole ----

Vec2 :: sim.Vec2 // x, y: two 32-bit floats

New_Player :: struct #packed { num: u8, team: sim.Team }
Player_Disconnect :: struct #packed { num: u8 }

// Client -> server. What I hold, when it changed; where I am, every few ticks; that I
// am dead, now and then; a slow weapon's shot, as it leaves; a pong to each ping.
Client_Sprite_Snapshot :: struct #packed {
	ammo, secondary_ammo:     u8,
	weapon, secondary_weapon: sim.Weapon_Id,
	position:                 sim.Stance,
}

Client_Sprite_Snapshot_Mov :: struct #packed {
	pos, vel:     Vec2,
	keys:         u16,
	aim_x, aim_y: i16,
}

Client_Sprite_Snapshot_Dead :: struct #packed { camera_focus: u8 }

Client_Bullet_Snapshot :: struct #packed {
	weapon:       sim.Weapon_Id,
	pos, vel:     Vec2,
	seed:         u16, // the shot's number: the pellets are rebuilt from it
	client_ticks: i32, // the client's tick, for the server to reckon its one-way lag
}

Pong :: struct #packed { ping_num: u8 }

// Server -> client. A soldier whole (the snapshot), or its movement and health (the
// major one), or its bones' timer while dead; a movement packet relayed to those who
// can see it (the delta), and a weapon change; a relayed shot; a death, with the
// corpse's points; the tally, now and then; a ping; the things.
Server_Sprite_Snapshot :: struct #packed {
	num:                      u8,
	pos, vel:                 Vec2,
	aim_x, aim_y:             i16,
	position:                 sim.Stance,
	keys:                     u16,
	look:                     u8, // the helmet and the cigar: nothing here, kept for the size
	vest, health:             f32,
	ammo, grenades:           u8,
	weapon, secondary_weapon: sim.Weapon_Id,
	server_ticks:             i32,
}

Server_Sprite_Snapshot_Major :: struct #packed {
	num:          u8,
	pos, vel:     Vec2,
	health:       f32,
	aim_x, aim_y: i16,
	position:     sim.Stance,
	keys:         u16,
	server_ticks: i32,
}

Server_Skeleton_Snapshot :: struct #packed { num: u8, respawn_counter: i16 }

Delta_Movement :: struct #packed {
	num:          u8,
	pos, vel:     Vec2,
	keys:         u16,
	aim_x, aim_y: i16,
	server_tick:  i32,
}

Delta_Weapons :: struct #packed { num: u8, weapon, secondary_weapon: sim.Weapon_Id, ammo: u8 }

Bullet_Snapshot :: struct #packed {
	owner:    u8,
	weapon:   sim.Weapon_Id,
	pos, vel: Vec2,
	seed:     u16,
	forced:   bool, // the server's own (a script's): to everyone, its owner too
}

// The corpse as the server started it, so every client starts it the same.
Sprite_Death :: struct #packed {
	num, killer:     u8,
	weapon:          sim.Weapon_Id, // KillBullet
	part:            u8,
	torn:            u32,           // Constraints
	pos, old_pos:    [sim.RAGDOLL_POINTS]Vec2,
	health:          f32,
	respawn_counter: i16,
}

// The tally. The entries are packed: the k-th entry is the k-th active soldier's, on
// both ends (the client counts its own active soldiers to unpack them).
Heart_Beat :: struct #packed {
	map_id:             u32,
	team_score:         [4]u16,
	active:             [sim.MAX_PLAYERS]bool,
	kills:              [sim.MAX_PLAYERS]u16,
	caps:               [sim.MAX_PLAYERS]u8,
	team:               [sim.MAX_PLAYERS]sim.Team,
	deaths:             [sim.MAX_PLAYERS]u16,
	ping:               [sim.MAX_PLAYERS]u8, // ticks, and a byte: a round trip past 255 wraps
	real_ping:          [sim.MAX_PLAYERS]u16,
	connection_quality: [sim.MAX_PLAYERS]u8,
	flags:              [sim.MAX_PLAYERS]u8,
}

Ping :: struct #packed { ping_ticks: u8, ping_num: u8 }

Server_Thing_Snapshot :: struct #packed {
	num, owner:   u8,
	style:        sim.Thing_Style,
	holder:       u8, // HoldingSprite: index + 1, 0 loose
	pos, old_pos: [4]Vec2,
}

// A thing that just appeared, whole: and which gun it is, which the original's
// styles carry and ours do not.
Server_Thing_Must_Snapshot :: struct #packed {
	num, owner:   u8,
	style:        sim.Thing_Style,
	holder:       u8,
	pos, old_pos: [4]Vec2,
	timeout:      i32,
	weapon:       sim.Weapon_Id,
	ammo:         i16,
}

Thing_Taken :: struct #packed {
	num, who: u8, // who 255: the thing is gone
	style:    sim.Thing_Style,
	ammo:     u8,
}

THING_GONE :: 255

Flag_Style :: enum u8 { Return_Red = 1, Return_Blue = 2, Capture_Red = 3, Capture_Blue = 4 }
Flag_Info :: struct #packed { style: Flag_Style, who: u8 }

// ---- writing and reading the records ----

// A record behind its id, into a fresh writer: the packet.
put :: proc(w: ^Writer, id: Msg, m: ^$T) {
	w.len = 0
	w.overflow = false
	write_u8(w, u8(id))
	write_raw(w, m, size_of(T))
}

// A record out of a packet, which must be exactly its size (VerifyPacket).
get :: proc(r: ^Reader, m: ^$T) -> bool {
	if len(r.data) - r.pos != size_of(T) do return false
	read_raw(r, m, size_of(T))
	return r.ok
}

reliable :: proc(id: Msg) -> bool {
	#partial switch id {
	case .Hello, .Welcome, .Denied, .New_Player, .Player_Disconnect, .Ping, .Pong, .Flag_Info:
		return true
	}
	return false
}
