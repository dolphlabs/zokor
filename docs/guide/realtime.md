# Realtime connections

> A WebSocket route is a handshake handler plus the handlers for what happens after it.

## WebSocket

A WebSocket route is a handshake handler plus the handlers for what
happens after it. The handshake goes through the router like any request
-- its `before`s run, so authentication, rate limits and CORS apply --
and once the `101` is written the connection belongs to the socket:

```slang
fn chat_open(c: zokor.Ctx[App]) -> http.Response {
    if c.local("user") == "" {                      // set by an auth before
        return zokor.respond(c.errors, "unauthorized", c.request_id);
    }
    let s = c.socket();                              // not yet open
    s.set_local("user", c.local("user"));
    c.state.hub.join_room(s, "lobby");
    return c.accept_ws();                            // the 101; anything else refuses
}

fn chat_message(app: App, s: zokor.Socket, m: zokor.Message) {
    app.hub.to_room("lobby", s.local("user") + ": " + m.text, s.id);
}

fn chat_left(app: App, s: zokor.Socket, code: int, reason: str) { ... }

r.websocket("/chat", chat_open,
            zokor.ws_route(zokor.ws_allowing(["chat"]), chat_message)
                .on_close(chat_left));
```

`s.send_text`, `s.send_binary` and `s.close(code, reason)` work from any
task -- this socket's handler, another connection's, a background job --
and never wait: a send queues the message, and the connection's writer
task puts it on the wire. A **`Hub`** holds sockets by id and in rooms:
`add`, `join_room`, `leave_room`, `broadcast`, `to_room`, `get`, `count`,
`room_size`. A socket leaves every hub it was in when its connection ends.
The hub is in-process; several instances need their own fan-out between
them (Redis pub/sub, say).

Each connection is two tasks: one reads, decodes and calls the handlers in
order, one message at a time; the other writes. What the settings in
`WsRules` bound, and what happens at each:

- **A client that stops reading** fills its queue (`max_queue`, 256
  messages) and is closed instead of holding memory, or the broadcaster,
  hostage.
- **A peer that vanished** without a FIN is pinged after `ping_interval`
  (25s) of silence and closed `pong_timeout` (20s) later.
- **A handler that panics** closes its connection with 1011; every other
  connection carries on. `on_close` runs once however the connection
  ended, with the peer's code, ours, 1002 for a protocol error or 1006
  when the peer vanished.
- **SIGTERM** closes every open socket with 1001 ("server shutting down"),
  so clients reconnect elsewhere, before the drain.
- **Over TLS** (`TLS_CERT_FILE`) the same route serves `wss://`.

Underneath, a connection is a **state machine, not a socket** (`new_conn`,
`receive`, `pending`): bytes in, whole messages and bytes to send out. That
is what the tests drive without a network, and what refuses, with 1002, an
unmasked client frame, a reserved bit or opcode, a fragmented or oversized
control frame, a length that is not minimally encoded, a continuation with
nothing to continue, a new message before the last finished, text that is
not UTF-8, an invalid close code, and anything over `max_frame_bytes` /
`max_message_bytes`. Ping/pong and the closing handshake are answered by
the connection, because they are protocol rather than application.

### Socket.IO

socket.io clients (socket.io-client 3 and 4: Engine.IO v4, Socket.IO v5)
on the same server, with the same handshake handler shape:

```slang
fn on_chat(app: App, s: zokor.Socket, e: zokor.SioEvent) {
    if e.name == "chat message" {
        app.hub.emit_to_room("lobby", e.namespace, "chat message", e.args_json, s.id);
        if e.ack >= 0 {
            s.ack(e.namespace, e.ack, "[\"delivered\"]");    // the client's callback
        }
    }
}

r.socketio("/socket.io/", chat_open,
           zokor.sio_route(on_chat).on_connect(joined).on_disconnect(left));
```

`on_connect(app, s, namespace, auth_json)` accepts a namespace with
`ok(true)` or refuses it with `err(message)`, which the client sees as a
`connect_error`; without one every namespace is accepted. Events for a
namespace the client is not connected to are dropped. `s.emit`,
`s.emit_with_ack` (the answer arrives as an `Ack` event), `s.ack` and
`s.disconnect_ns` send; `hub.emit_all` and `hub.emit_to_room` encode an
event once for every Socket.IO session they reach. A hub can hold
WebSockets and Socket.IO sessions together: `to_room` reaches the first,
`emit_to_room` the second, so a chat open to both calls both.
`on_disconnect(app, s, namespace, reason)` runs once per connected
namespace with socket.io's reasons (`client namespace disconnect`,
`transport close`, `ping timeout`, `server shutting down`, `server error`
for a panicking handler). The Engine.IO heartbeat is run for you on
`route.settings` (`ping_interval_ms`, `ping_timeout_ms`, `max_payload`).

Both of socket.io's transports are served, so a client needs no options:
it starts on **HTTP long-polling** (a GET that waits for packets, a POST
that carries its own) and moves to WebSocket once a probe over it succeeds,
or stays on polling where WebSockets do not get through. The session -- its
id, hubs, namespaces and locals -- is the same `Socket` throughout, and
handlers cannot tell which transport a packet came by. Polling sessions
live between requests: they are capped by `max_polling_sessions` (10,000;
past it the handshake is answered 503), and one heartbeat task per route
pings them and ends those that stop answering. Two GETs or two POSTs at
once for one session end it, as Engine.IO requires. A polling POST is one
HTTP request, so it is bounded by `MAX_REQUEST_BYTES` (16KB by default):
raise it towards `max_payload` if clients send large events over polling.

**Binary attachments** work both ways. An event's attachments arrive in
`e.attachments` (in order; `args_json` holds a placeholder where each
was), and `s.emit_binary(namespace, name, args_json, [data])` /
`hub.emit_binary_to_room(..)` send them: binary frames over WebSocket,
base64 over polling. An event may carry up to `max_attachments` (16).

`examples/chat` is one room for both kinds of client, served for real:
`make example-chat` runs it against stand-in clients, and
`slangc examples/chat/main.sl --run -- serve` serves it on :8080 for a
browser. Checked against socket.io-client 4.7.5 and the `ws` package.
