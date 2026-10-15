# Chat service

> A chat service: the same room for WebSocket clients and socket.io clients, on one server.

# Chat service

A chat service: the same room for WebSocket clients and socket.io clients, on one server.

Run from the repository root: `make example-chat`.

## `examples/chat/main.sl`

```slang
// A chat service: the same room for WebSocket clients and socket.io
// clients, on one server.
//
//     slangc examples/chat/main.sl --run            the scripted demo below
//     slangc examples/chat/main.sl --run -- serve   a real server on :8080
//
// With `serve`, point a browser at it:
//
//     const ws = new WebSocket("ws://localhost:8080/ws?name=ada", "chat");
//     ws.onmessage = (m) => console.log(m.data);
//     ws.send("hello");
//
//     const socket = io("http://localhost:8080", { query: { name: "leo" } });
//     socket.on("chat message", (m) => console.log(m));
//     socket.emit("chat message", "hi", (reply) => console.log(reply));
//
// Read "the service": that is everything a real one writes. The demo after
// it is a stand-in browser -- real connections to a real server on a free
// port -- so `make example-chat` shows the exchange without one.
import "http";
import "proc";
import "time";
import "../../zokor" as zokor;

// ---------------------------------------------------------------- //
// the service                                                        //
// ---------------------------------------------------------------- //

gc struct App {
    name: str,
    // everyone in the chat, WebSocket and socket.io alike
    hub: zokor.Hub,
    history: [str],
    lock: mutex,
}

fn remember(app: App, line: str) {
    mutex_lock(app.lock);
    push(app.history, line);
    mutex_unlock(app.lock);
}

// The handshake, for both kinds of client. Every `before` has run by now
// (an auth hook would have set c.local("user")); this one only wants a name.
fn arrive(c: zokor.Ctx[App]) -> http.Response {
    let name = c.query("name");
    if name == "" {
        return zokor.respond_with(c.errors, "unauthorized", "say who you are: ?name=",
                                  c.request_id);
    }
    let s = c.socket();
    s.set_local("name", name);
    c.state.hub.join_room(s, "chat");
    return c.accept_ws();
}

// WebSocket clients: every text message goes to the room.
fn on_text(app: App, s: zokor.Socket, m: zokor.Message) {
    if m.kind != zokor.Incoming.Text {
        s.send_text("only text, please");
        return;
    }
    if m.text == "/history" {
        mutex_lock(app.lock);
        let h = join_lines(app.history);
        mutex_unlock(app.lock);
        s.send_text(h);
        return;
    }
    let line = s.local("name") + ": " + m.text;
    remember(app, line);
    // to WebSocket clients as text, to socket.io clients as an event
    app.hub.to_room("chat", line, s.id);
    app.hub.emit_to_room("chat", "/", "chat message", zokor.jstr(line).render(), s.id);
}

fn on_ws_close(app: App, s: zokor.Socket, code: int, reason: str) {
    remember(app, s.local("name") + " left (" + to_str(code) + ")");
}

// socket.io clients.
fn on_event(app: App, s: zokor.Socket, e: zokor.SioEvent) {
    if e.kind != zokor.SioKind.Event {
        return;
    }
    if e.name == "chat message" {
        remember(app, s.local("name") + " said " + e.args_json);
        app.hub.emit_to_room("chat", e.namespace, "chat message", e.args_json, s.id);
        let said = "";
        let pr = zokor.parse(e.args_json);
        if let args = pr {
            said = args.at(0).str_or("");
        }
        app.hub.to_room("chat", s.local("name") + ": " + said, s.id);
        if e.ack >= 0 {
            // the client used socket.emit(..., callback)
            s.ack(e.namespace, e.ack, "[\"delivered\"]");
        }
        return;
    }
    s.emit(e.namespace, "error", "\"unknown event: " + e.name + "\"");
}

fn on_sio_leave(app: App, s: zokor.Socket, ns: str, why: str) {
    remember(app, s.local("name") + " left " + ns + " (" + why + ")");
}

fn chat_router(app: App) -> zokor.Router[App] {
    let r = zokor.new_router(app);
    r.websocket("/ws", arrive,
                zokor.ws_route(zokor.ws_allowing(["chat"]), on_text).on_close(on_ws_close));
    r.socketio("/socket.io/", arrive,
               zokor.sio_route(on_event).on_disconnect(on_sio_leave));
    return r;
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

fn new_app() -> App {
    return App { name: "zokor chat", hub: zokor.new_hub(), history: [], lock: make_mutex() };
}

// ---------------------------------------------------------------- //
// the demo: a stand-in browser, printed                              //
//                                                                    //
// Real connections to the server above. Nothing below is part of     //
// zokor's API: a browser does all of this for you.                   //
// ---------------------------------------------------------------- //

import "../../zokor/internal/ws" as frames;

fn soon() -> until {
    return until_of(time.mono() + 2000000000);
}

// A client's frames are masked, which the server requires.
fn client_frame(op: int, payload: bytes) -> bytes {
    let n = len(payload);
    let head: bytes = b"..";
    head[0] = 128 | op;
    head[1] = 128 | n;
    let key = b"\x2a\x07\x63\x01";
    let body = b"";
    let one: bytes = b".";
    let i = 0;
    while i < n {
        one[0] = payload[i] ^ key[i % 4];
        body = body + one;
        i = i + 1;
    }
    return head + key + body;
}

fn says(c: &mut link, s: str) {
    let _s = c.send_bytes(client_frame(1, to_bytes(s)), soon());
}

fn bye(c: &mut link) {
    let b: bytes = b"..";
    b[0] = 3;
    b[1] = 232;
    let _s = c.send_bytes(client_frame(8, b), soon());
}

// Sends the upgrade request and returns the status line; whatever came
// after the response head is kept in `got`.
gc struct Inbox {
    got: bytes,
}

fn open(c: &mut link, path: str, box: Inbox) -> str {
    let req = "GET " + path + " HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" +
              "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" +
              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
              "Sec-WebSocket-Protocol: chat\r\n\r\n";
    let _s = c.send_bytes(to_bytes(req), soon());
    let a = arena_new(4096);
    let w = a.wire(4096);
    let got = b"";
    while true {
        let rr = c.recv(w, soon());
        guard let n = rr else { return "no answer"; }
        if n == 0 { return "closed"; }
        got = got + to_bytes(w[0..n]);
        let i = 0;
        while i + 3 < len(got) {
            if got[i] == 13 && got[i + 1] == 10 && got[i + 2] == 13 && got[i + 3] == 10 {
                box.got = got[i + 4..len(got)];
                let j = 0;
                while got[j] != 13 { j = j + 1; }
                return to_str(got[0..j]);
            }
            i = i + 1;
        }
    }
    return "no answer";
}

// The next frame from the server, printed as a browser would see it.
fn hears(label: str, c: &mut link, box: Inbox) {
    let a = arena_new(4096);
    let w = a.wire(4096);
    while true {
        let dr = frames.decode(box.got, 0, 1048576, false);
        guard let d = dr else { println(label + " <- (undecodable)"); return; }
        if d.kind == frames.Decoded.Frame {
            let f = d.frame;
            box.got = box.got[f.size..len(box.got)];
            if f.op == frames.Op.Text {
                println(label + " <- " + to_str(f.payload));
            } else if f.op == frames.Op.Close {
                let cr = frames.decode_close(f.payload);
                if let body = cr {
                    println(label + " <- close " + to_str(body.code) + " " + body.reason);
                } else {
                    println(label + " <- close");
                }
            } else {
                println(label + " <- frame " + to_str(frames.code_of(f.op)));
            }
            return;
        }
        let rr = c.recv(w, soon());
        guard let n = rr else { println(label + " <- (nothing)"); return; }
        if n == 0 { println(label + " <- (connection closed)"); return; }
        box.got = box.got + to_bytes(w[0..n]);
    }
}

fn serve_all(ln: link, r: zokor.Router[App]) {
    let sc = zokor.default_server_config();
    sc.logger = zokor.no_logger();
    let mut_ln = ln;
    while true {
        let ar = mut_ln.accept(until_never());
        guard let c = ar else { return; }
        spawn zokor.serve_conn(r, c, sc);
    }
}

// Waits until the server has finished with a client that left, so the
// history printed at the end is complete.
fn settle(app: App, lines: int) {
    let waited = 0;
    while waited < 200 {
        mutex_lock(app.lock);
        let n = len(app.history);
        mutex_unlock(app.lock);
        if n >= lines { return; }
        time.sleep(10000000);
        waited = waited + 1;
    }
}

fn demo() {
    let app = new_app();
    let r = chat_router(app);
    let lr = link_listen(0);
    guard let ln = lr else { panic("cannot listen"); }
    let port = ln.port();
    spawn serve_all(ln, r);

    println("websocket:");
    let ada = link_dial("127.0.0.1", port, soon()) ?? panic_link();
    let ab = Inbox { got: b"" };
    println("  ada  handshake -> " + open(&mut ada, "/ws?name=ada", ab));
    let bo = link_dial("127.0.0.1", port, soon()) ?? panic_link();
    let bb = Inbox { got: b"" };
    println("  bo   handshake -> " + open(&mut bo, "/ws?name=bo", bb));
    let anon = link_dial("127.0.0.1", port, soon()) ?? panic_link();
    let nb = Inbox { got: b"" };
    println("  anon handshake -> " + open(&mut anon, "/ws", nb));
    says(&mut ada, "hello");
    hears("  bo  ", &mut bo, bb);
    says(&mut bo, "hi ada");
    hears("  ada ", &mut ada, ab);
    println("");

    println("socket.io:");
    let leo = link_dial("127.0.0.1", port, soon()) ?? panic_link();
    let lb = Inbox { got: b"" };
    println("  leo  handshake -> " +
            open(&mut leo, "/socket.io/?EIO=4&transport=websocket&name=leo", lb));
    // the session id is random; the rest of the open packet is not
    let a = arena_new(4096);
    let w = a.wire(4096);
    let opened = false;
    while !opened {
        let dr = frames.decode(lb.got, 0, 1048576, false);
        guard let d = dr else { break; }
        if d.kind == frames.Decoded.Frame {
            let f = d.frame;
            lb.got = lb.got[f.size..len(lb.got)];
            let text = to_str(f.payload);
            let at = 0;
            let tb = to_bytes(text);
            while at < len(tb) && tb[at] != 44 { at = at + 1; }
            println("  leo  <- 0{\"sid\":\"...\"" + to_str(tb[at..len(tb)]));
            opened = true;
        } else {
            let rr = a_recv(&mut leo, w);
            lb.got = lb.got + rr;
        }
    }
    says(&mut leo, "40");
    let _ok = skip_one(&mut leo, lb);
    println("  leo  -> 40           (connected to /)");
    says(&mut leo, "421[\"chat message\",\"hi from socket.io\"]");
    hears("  ada ", &mut ada, ab);
    hears("  bo  ", &mut bo, bb);
    hears("  leo ", &mut leo, lb);
    says(&mut ada, "and back");
    hears("  bo  ", &mut bo, bb);
    hears("  leo ", &mut leo, lb);
    says(&mut leo, "42[\"whatever\"]");
    hears("  leo ", &mut leo, lb);
    println("");

    println("leaving:");
    bye(&mut ada);
    hears("  ada ", &mut ada, ab);
    settle(app, 5);
    says(&mut leo, "41");
    settle(app, 6);
    says(&mut bo, "/history");
    hears("  bo  ", &mut bo, bb);
}

fn a_recv(c: &mut link, w: wire) -> bytes {
    let rr = c.recv(w, soon());
    guard let n = rr else { return b""; }
    return to_bytes(w[0..n]);
}

// The CONNECT answer carries the random session id too: read past it.
fn skip_one(c: &mut link, box: Inbox) -> bool {
    let a = arena_new(4096);
    let w = a.wire(4096);
    while true {
        let dr = frames.decode(box.got, 0, 1048576, false);
        guard let d = dr else { return false; }
        if d.kind == frames.Decoded.Frame {
            box.got = box.got[d.frame.size..len(box.got)];
            return true;
        }
        let rr = c.recv(w, soon());
        guard let n = rr else { return false; }
        if n == 0 { return false; }
        box.got = box.got + to_bytes(w[0..n]);
    }
    return false;
}

fn panic_link() -> link {
    panic("cannot connect");
}

let args = proc.args();
if len(args) > 1 && args[len(args) - 1] == "serve" {
    let r = chat_router(new_app());
    let sr = zokor.listen_and_serve(r, 8080);
    guard let _ok = sr else let e = err_of(sr) {
        println(e);
        exit(1);
    }
} else {
    demo();
}
```
