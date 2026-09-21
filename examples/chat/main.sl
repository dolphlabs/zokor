// A WebSocket chat service, and the same thing for socket.io clients.
//
// Read "the service": that is everything a real one writes. `serve_ws`
// is the function a serve loop will call with whatever bytes arrived on
// a connection; it returns the bytes to write back. Until
// `listen_and_serve` lands (it needs generic functions in slang), the
// section after it plays the part of a client so you can see the
// exchange.
import "http";
import "../../src" as zokor;

// ---------------------------------------------------------------- //
// the service                                                        //
// ---------------------------------------------------------------- //

gc struct App {
    name: str,
    history: [str],
    errors: zokor.Registry,
}

// One connection's state: the protocol machine, plus whatever the
// application wants to remember about this client.
gc struct Client {
    conn: zokor.Conn,
    app: App,
    who: str,
    joined: bool,
}

fn new_client(app: App, who: str) -> Client {
    return Client {
        conn: zokor.new_conn(zokor.default_ws()),
        app: app,
        who: who,
        joined: false
    };
}

// The HTTP side: a route that turns into a WebSocket.
fn ws_route(c: zokor.Ctx[App]) -> http.Response {
    let r = zokor.upgrade(c.req, zokor.ws_allowing(["chat"]));
    guard let resp = r else let why = err_of(r) {
        // not a WebSocket request, or one this server cannot accept
        return zokor.respond_with(c.state.errors, "bad_request", why,
                                  c.request_id);
    }
    return resp;
}

// The connection side. A serve loop calls this with each chunk it
// reads and writes whatever comes back; when the connection is closed
// it stops reading. Nothing here touches a socket, which is why the
// demo below can drive it directly.
fn serve_ws(cl: Client, chunk: bytes) -> bytes {
    let got = zokor.receive(cl.conn, chunk);
    guard let messages = got else let why = err_of(got) {
        // a protocol error: say so and hang up
        return zokor.close_because(cl.conn, why);
    }

    let out: bytes = b"";
    let i = 0;
    while i < len(messages) {
        let m = messages[i];
        if m.kind == zokor.Incoming.Text {
            out = out + on_text(cl, m.text);
        } else if m.kind == zokor.Incoming.Binary {
            out = out + zokor.text_frame("binary of " +
                                         to_str(len(m.data)) + " bytes");
        } else if m.kind == zokor.Incoming.Close {
            // the echo is already in `out`; the loop stops after this
            println("  [" + cl.who + " closed: " + to_str(m.code) + " " +
                    m.reason + "]");
        }
        i = i + 1;
    }
    // whatever the protocol itself owed -- pong answers, the close echo
    // -- taken LAST, because handling a message can add to it
    return zokor.pending(cl.conn) + out;
}

fn on_text(cl: Client, text: str) -> bytes {
    if !cl.joined {
        cl.joined = true;
        push(cl.app.history, cl.who + " joined");
        return zokor.text_frame("welcome to " + cl.app.name + ", " + cl.who);
    }
    if text == "/history" {
        return zokor.text_frame(join_lines(cl.app.history));
    }
    let line = cl.who + ": " + text;
    push(cl.app.history, line);
    // a real service would write this frame to every other client
    return zokor.text_frame(line);
}

fn join_lines(xs: [str]) -> str {
    let out = "";
    let i = 0;
    while i < len(xs) {
        if i > 0 {
            out = out + " | ";
        }
        out = out + xs[i];
        i = i + 1;
    }
    return out;
}

// ---------------------------------------------------------------- //
// the service, for socket.io clients                                 //
//                                                                    //
//     const socket = io("http://localhost:8080", {                   //
//         transports: ["websocket"]                                  //
//     });                                                            //
//     socket.emit("chat message", "hi");                             //
// ---------------------------------------------------------------- //

fn serve_sio(cl: Client, chunk: bytes) -> bytes {
    let got = zokor.receive(cl.conn, chunk);
    guard let messages = got else let why = err_of(got) {
        return zokor.close_because(cl.conn, why);
    }
    let out: bytes = b"";
    let i = 0;
    while i < len(messages) {
        let ev = zokor.sio_receive(cl.conn, messages[i]);
        guard let e = ev else let why = err_of(ev) {
            out = out + zokor.close_because(cl.conn, why);
            i = len(messages);
            continue;
        }
        out = out + on_sio(cl, e);
        i = i + 1;
    }
    // sio_receive answers an Engine.IO ping into the outbox, so this
    // comes last too
    return zokor.pending(cl.conn) + out;
}

fn on_sio(cl: Client, e: zokor.SioEvent) -> bytes {
    if e.kind == zokor.SioKind.Connect {
        // a v5 client waits for this before it emits anything
        return zokor.sio_connect_ok(cl.conn, e.namespace);
    }
    if e.kind == zokor.SioKind.Event {
        if e.name == "chat message" {
            push(cl.app.history, cl.who + " said " + e.args_json);
            let echo = zokor.sio_emit(e.namespace, "chat message", e.args_json);
            if e.ack >= 0 {
                // the client used socket.emit(..., callback)
                return echo + zokor.sio_ack(e.namespace, e.ack, "[\"delivered\"]");
            }
            return echo;
        }
        return zokor.sio_emit(e.namespace, "error",
                              "[\"unknown event: " + e.name + "\"]");
    }
    if e.kind == zokor.SioKind.Disconnect {
        println("  [" + cl.who + " disconnected from " + e.namespace + "]");
    }
    // Ping was already answered for us
    return b"";
}

// ---------------------------------------------------------------- //
// the demo: a stand-in client, printed                               //
//                                                                    //
// Only because there is no serve loop yet. A browser sends these      //
// bytes; nothing below is part of zokor's API.                       //
// ---------------------------------------------------------------- //

// A browser decodes the server's frames; this demo does the same, only
// to print them. A service never needs this -- it writes the bytes
// zokor hands it.
import "../../src/internal/ws" as frames;

// A client's frames are masked, which the server requires.
fn client_frame(op: int, payload: bytes, fin: bool) -> bytes {
    let n = len(payload);
    let out: bytes = b"";
    let one: bytes = b".";
    let b0 = op;
    if fin {
        b0 = b0 | 128;
    }
    one[0] = b0;
    out = out + one;
    one[0] = 128 | n;
    out = out + one;
    let key = [42, 7, 99, 1];
    let i = 0;
    while i < 4 {
        one[0] = key[i];
        out = out + one;
        i = i + 1;
    }
    i = 0;
    while i < n {
        one[0] = payload[i] ^ key[i % 4];
        out = out + one;
        i = i + 1;
    }
    return out;
}

fn client_says(s: str) -> bytes {
    return client_frame(1, to_bytes(s), true);
}

// Prints what the server wrote, by decoding its own frames back.
fn show_written(label: str, written: bytes) {
    if len(written) == 0 {
        println(label + " -> (nothing)");
        return;
    }
    let at = 0;
    while at < len(written) {
        let r = frames.decode(written, at, 1048576, false);
        guard let d = r else {
            println(label + " -> (undecodable)");
            return;
        }
        if d.kind != frames.Decoded.Frame {
            return;
        }
        let f = d.frame;
        if f.op == frames.Op.Text {
            println(label + " -> text: " + to_str(f.payload));
        } else if f.op == frames.Op.Pong {
            println(label + " -> pong");
        } else if f.op == frames.Op.Close {
            let cr = frames.decode_close(f.payload);
            guard let body = cr else {
                println(label + " -> close");
                return;
            }
            println(label + " -> close " + to_str(body.code) + " " + body.reason);
        } else {
            println(label + " -> frame " + to_str(frames.code_of(f.op)));
        }
        at = at + f.size;
    }
}

let reg = zokor.new_registry();
let app = App { name: "zokor chat", history: [], errors: reg };

let r = zokor.Router[App] {
    routes: [],
    befores: [],
    afters: [],
    state: app,
    errors: reg,
    auto_options: true,
    auto_head: true
};
r.get("/ws", ws_route);

// 1. the handshake, over the ordinary router
let h: map[str]str = {};
h["upgrade"] = "websocket";
h["connection"] = "Upgrade";
h["sec-websocket-version"] = "13";
h["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ==";
h["sec-websocket-protocol"] = "chat";
let handshake = http.Request {
    method: "GET",
    path: "/ws",
    version: "HTTP/1.1",
    headers: h,
    body: b""
};
let resp = r.serve(handshake);
println("handshake -> " + to_str(resp.status) + " " + resp.status_text);
println("  sec-websocket-accept: " + resp.headers["sec-websocket-accept"]);
println("  sec-websocket-protocol: " + resp.headers["sec-websocket-protocol"]);
println("");

// a request that is not an upgrade gets a normal error, same route
let plain: map[str]str = {};
let not_ws = http.Request {
    method: "GET",
    path: "/ws",
    version: "HTTP/1.1",
    headers: plain,
    body: b""
};
let bad = r.serve(not_ws);
println("plain GET /ws -> " + to_str(bad.status) + " " + to_str(bad.body));
println("");

// 2. the conversation
println("websocket:");
let ada = new_client(app, "ada");
show_written("  hello", serve_ws(ada, client_says("hello")));
show_written("  chat", serve_ws(ada, client_says("is anyone there?")));
show_written("  ping", serve_ws(ada, client_frame(9, to_bytes("beat"), true)));
// a message split into two frames, arriving in one read
show_written("  fragments",
             serve_ws(ada, client_frame(1, to_bytes("split "), false) +
                           client_frame(0, to_bytes("message"), true)));
show_written("  /history", serve_ws(ada, client_says("/history")));
// a client that breaks the protocol is closed, not tolerated
let rude = new_client(app, "rude");
let unmasked: bytes = b".....";
unmasked[0] = 129;
unmasked[1] = 3;
unmasked[2] = 97;
unmasked[3] = 98;
unmasked[4] = 99;
show_written("  unmasked frame", serve_ws(rude, unmasked));
// a well-behaved goodbye
let bye: bytes = b"..";
bye[0] = 3;
bye[1] = 232;
show_written("  close", serve_ws(ada, client_frame(8, bye + to_bytes("bye"), true)));
println("");

// 3. the same service, for a socket.io client
println("socket.io:");
let sio_client = new_client(app, "leo");
show_written("  open", zokor.sio_open(sio_client.conn, "sid-42",
                                      zokor.default_sio()));
show_written("  connect", serve_sio(sio_client, client_says("40")));
show_written("  emit", serve_sio(sio_client,
                                 client_says("42[\"chat message\",\"hi\"]")));
show_written("  emit with ack", serve_sio(sio_client,
                                 client_says("421[\"chat message\",\"again\"]")));
show_written("  unknown event", serve_sio(sio_client,
                                 client_says("42[\"whatever\"]")));
show_written("  keepalive", serve_sio(sio_client, client_says("2")));
show_written("  disconnect", serve_sio(sio_client, client_says("41")));
println("");
println("history: " + join_lines(app.history));
