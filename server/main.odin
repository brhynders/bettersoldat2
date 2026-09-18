// The dedicated server. Headless: imports the sim and the net, never raylib.
//
//   init
//   while running:
//     receive client messages
//     tick accumulator:
//       tick            everyone stepped on their keys, the hits applied, the deaths told
//       send            the snapshots, deltas, tally, things and pings on their schedules
//     sleep until the next tick
//   cleanup
package server

import "core:os"
import "core:strconv"
import "core:time"
import "../shared/sim"

TICK :: sim.TICK

Server :: struct {
	options:     Options,
	game:        Game,
	host:        Host,
	accumulator: f64,
	last:        time.Tick,
	quit:        bool,
}

Options :: struct {
	base:     string,
	map_name: string,
	port:     u16,
	bots:     int,  // played by the server itself, from the start
	dodge:    bool, // the bots change direction and jet at random in a fight, as a person does
}

server: Server

main :: proc() {
	init()
	for !server.quit do server_loop()
	cleanup()
}

init :: proc() {
	server.options = parse_options()
	o := &server.options
	host_open(&server.host, o.port)
	game_init(&server.game, o.base, o.map_name, o.bots, o.dodge)
	server.last = time.tick_now()
}

server_loop :: proc() {
	receive_client_messages(&server.game, &server.host)
	now := time.tick_now()
	server.accumulator += time.duration_seconds(time.tick_diff(server.last, now))
	server.last = now
	for server.accumulator >= TICK {
		tick(&server.game, &server.host)
		send_all_scheduled(&server.game, &server.host)
		server.accumulator -= TICK
	}
	time.sleep(time.Millisecond)
}

cleanup :: proc() {
	host_close(&server.host)
}

parse_options :: proc() -> (o: Options) {
	o.base = "../opensoldat-base/shared"
	o.map_name = "ctf_Ash"
	o.port = 23073
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		next := i + 1 < len(args) ? args[i + 1] : ""
		switch args[i] {
		case "-base": o.base = next; i += 1
		case "-map":  o.map_name = next; i += 1
		case "-port": o.port = u16(strconv.parse_int(next) or_else 23073); i += 1
		case "-bots":  o.bots = strconv.parse_int(next) or_else 0; i += 1
		case "-dodge": o.dodge = true
		}
	}
	return
}
