// WebSocket, and Socket.IO on top of it.
//
// A connection is a state machine, not a socket: you hand it the bytes
// that arrived and it hands you back whole messages and the bytes to
// send. That is what makes it testable without a network, and it is
// what lets the same code serve a raw WebSocket client and a
// socket.io one.
//
//     let c = zokor.new_conn(zokor.default_ws());
//
//     // a client's bytes came in:
//     let r = zokor.receive(c, chunk);
//     guard let msgs = r else let e = err_of(r) {
//         return zokor.close_because(c, e);     // bytes to write, then hang up
//     }
//     for m in msgs {
//         if m.kind == zokor.Incoming.Text {
//             reply = reply + zokor.text_frame(m.text);
//         }
//     }
//     // anything the protocol itself owed (a pong, a close echo):
//     reply = zokor.pending(c) + reply;
//
// Ping/pong and the closing handshake are answered by the connection,
// because they are protocol, not application.

import "builder";
import "http";
import "internal/ws";
import "internal/sio";

pub gc struct WsRules {
    // The largest single frame, and the largest message once its
    // fragments are joined. A client can otherwise announce an enormous
    // frame, or send a million small ones, and make the server hold it.
    max_frame_bytes: int,
    max_message_bytes: int,
    // Subprotocols this server speaks, best first. Empty accepts any
    // client and selects none.
    protocols: [str],
}

pub fn default_ws() -> WsRules {
    let any: [str] = [];
    return WsRules {
        max_frame_bytes: 1048576,
        max_message_bytes: 8388608,
        protocols: any
    };
}

pub fn ws_allowing(protocols: [str]) -> WsRules {
    let r = default_ws();
    r.protocols = protocols;
    return r;
}

pub enum Incoming {
    Text,
    Binary,
    Ping,
    Pong,
    Close,
}

pub gc struct Message {
    kind: Incoming,
    text: str,
    data: bytes,
    // For Close: the code and reason the peer sent.
    code: int,
    reason: str,
}

pub gc struct Conn {
    rules: WsRules,
    // Bytes received that are not yet a whole frame, and how many
    // bytes the frame being waited for needs in all. While `have` is
    // below `need` a read costs one copy of that read and nothing else:
    // no assembly, no decode, no re-copying what arrived before.
    // (Every read used to copy everything received so far, which is
    // quadratic in the size of a frame arriving in small reads.)
    inbox: builder.Bytes,
    have: int,
    need: int,
    // A message being assembled from fragments. A builder, not `+`:
    // joining n fragments by concatenation copies the growing message n
    // times, and the number of fragments is the client's to choose.
    partial: builder.Bytes,
    partial_op: ws.Op,
    fragmenting: bool,
    // Bytes the protocol owes the peer: pong answers, the close echo.
    outbox: bytes,
    closed: bool,
    // Socket.IO only: the session id handed to the client.
    sid: str,
}

pub fn new_conn(rules: WsRules) -> Conn {
    return Conn {
        rules: rules,
        inbox: builder.new_bytes(),
        have: 0,
        need: 2,
        partial: builder.new_bytes(),
        partial_op: ws.Op.Text,
        fragmenting: false,
        outbox: b"",
        closed: false,
        sid: ""
    };
}

// ---------------------------------------------------------------- //
// The handshake                                                      //
// ---------------------------------------------------------------- //

// Is this request asking to become a WebSocket? Cheap enough to call
// on every request, so a route can serve both.
pub fn is_upgrade(req: http.Request) -> bool {
    let r = ws.read(req);
    guard let _h = r else {
        return false;
    }
    return true;
}

// The 101 to send back, or the failure to report. The selected
// subprotocol is whichever of the client's the server also speaks.
pub fn upgrade(req: http.Request, rules: WsRules) -> result[http.Response, str] {
    let r = ws.read(req);
    guard let h = r else let e = err_of(r) {
        return err(e);
    }
    let chosen = "";
    if len(rules.protocols) > 0 {
        chosen = ws.choose(h.protocols, rules.protocols);
    }
    return ok(ws.response(h.key, chosen));
}

// ---------------------------------------------------------------- //
// Receiving                                                          //
// ---------------------------------------------------------------- //

// Feeds bytes in and takes whole messages out.
//
// A protocol error comes back as an error: the caller sends
// `close_because` and hangs up, which is what RFC 6455 requires -- a
// connection that has been desynchronised cannot be recovered by
// carrying on.
pub fn receive(c: Conn, chunk: bytes) -> result[[Message], str] {
    let out: [Message] = [];
    let total = c.have + len(chunk);
    // Not enough for the next frame yet: keep it, and do nothing else.
    if total < c.need {
        if len(chunk) > 0 {
            c.inbox.write(chunk);
            c.have = total;
        }
        return ok(out);
    }
    // Enough to try. With nothing kept from before, decode straight
    // from what arrived; otherwise assemble what was kept, once.
    let buf = chunk;
    if c.have > 0 {
        c.inbox.write(chunk);
        buf = c.inbox.take();
    }
    c.have = 0;
    c.need = 2;
    let at = 0;
    while true {
        let dr = ws.decode(buf, at, c.rules.max_frame_bytes, true);
        guard let d = dr else let e = err_of(dr) {
            return err(e);
        }
        if d.kind == ws.Decoded.Incomplete {
            keep(c, buf, at, d.need);
            return ok(out);
        }
        let f = d.frame;
        at = at + f.size;

        if ws.is_control(f.op) {
            let mr = control(c, f);
            guard let m = mr else let e = err_of(mr) {
                return err(e);
            }
            push(out, m);
            continue;
        }

        // A data frame: either a whole message, or part of one.
        if f.op == ws.Op.Continuation {
            if !c.fragmenting {
                return err("a continuation frame with nothing to continue");
            }
        } else {
            if c.fragmenting {
                return err("a new message started before the last one finished");
            }
            c.partial_op = f.op;
            c.partial.reset();
        }
        if c.partial.size() + len(f.payload) > c.rules.max_message_bytes {
            return err("message exceeds the " +
                       to_str(c.rules.max_message_bytes) + "-byte limit");
        }
        c.partial.write(f.payload);
        c.fragmenting = !f.fin;
        if f.fin {
            let body = c.partial.take();
            if c.partial_op == ws.Op.Text {
                if !ws.valid_utf8(body) {
                    return err("a text message must be valid UTF-8");
                }
                push(out, Message {
                    kind: Incoming.Text,
                    text: to_str(body),
                    data: body,
                    code: 0,
                    reason: ""
                });
            } else {
                push(out, Message {
                    kind: Incoming.Binary,
                    text: "",
                    data: body,
                    code: 0,
                    reason: ""
                });
            }
        }
    }
    return ok(out);
}

// What is left over after the last whole frame, kept for the next read,
// together with how many bytes that partial frame needs in all.
fn keep(c: Conn, buf: bytes, at: int, need: int) -> int {
    let n = len(buf);
    if at >= n {
        c.have = 0;
        c.need = 2;
        return 0;
    }
    c.inbox.reset();
    c.inbox.write(buf[at..n]);
    c.have = n - at;
    c.need = need;
    return 0;
}

fn control(c: Conn, f: ws.Frame) -> result[Message, str] {
    if f.op == ws.Op.Ping {
        // answered here: a pong is protocol, not application
        c.outbox = c.outbox + ws.encode(ws.Op.Pong, f.payload, true);
        return ok(Message {
            kind: Incoming.Ping,
            text: "",
            data: f.payload,
            code: 0,
            reason: ""
        });
    }
    if f.op == ws.Op.Pong {
        return ok(Message {
            kind: Incoming.Pong,
            text: "",
            data: f.payload,
            code: 0,
            reason: ""
        });
    }
    let br = ws.decode_close(f.payload);
    guard let body = br else let e = err_of(br) {
        return err(e);
    }
    // the closing handshake: echo the code back, then the caller hangs up
    if !c.closed {
        c.outbox = c.outbox + ws.encode_close(body.code, "");
        c.closed = true;
    }
    return ok(Message {
        kind: Incoming.Close,
        text: "",
        data: b"",
        code: body.code,
        reason: body.reason
    });
}

// Bytes the connection owes the peer (pongs, the close echo), taken
// out: call it after `receive` and write whatever it returns.
pub fn pending(c: Conn) -> bytes {
    let out = c.outbox;
    c.outbox = b"";
    return out;
}

pub fn is_closed(c: Conn) -> bool {
    return c.closed;
}

// ---------------------------------------------------------------- //
// Sending                                                            //
// ---------------------------------------------------------------- //

pub fn text_frame(s: str) -> bytes {
    return ws.encode(ws.Op.Text, to_bytes(s), true);
}

pub fn binary_frame(b: bytes) -> bytes {
    return ws.encode(ws.Op.Binary, b, true);
}

pub fn ping_frame(payload: bytes) -> bytes {
    return ws.encode(ws.Op.Ping, payload, true);
}

pub fn pong_frame(payload: bytes) -> bytes {
    return ws.encode(ws.Op.Pong, payload, true);
}

pub fn close_frame(code: int, reason: str) -> bytes {
    return ws.encode_close(code, reason);
}

// The close a protocol error calls for: 1002, with the reason, and the
// connection marked shut so nothing else is sent.
pub fn close_because(c: Conn, why: str) -> bytes {
    if c.closed {
        return b"";
    }
    c.closed = true;
    return ws.encode_close(1002, why);
}

// ---------------------------------------------------------------- //
// Socket.IO                                                          //
// ---------------------------------------------------------------- //
//
// A socket.io client speaks Engine.IO inside WebSocket text frames.
// Give the connection a session id, answer its CONNECT, and then
// `emit` events at it.
//
// The client must be told to use this transport directly:
//
//     io("http://host", { transports: ["websocket"] })
//
// because by default it opens an HTTP long-polling session first and
// upgrades, and polling is a separate transport zokor does not serve
// yet.

pub gc struct SioSettings {
    ping_interval_ms: int,
    ping_timeout_ms: int,
    max_payload: int,
}

pub fn default_sio() -> SioSettings {
    return SioSettings {
        ping_interval_ms: 25000,
        ping_timeout_ms: 20000,
        max_payload: 1000000
    };
}

pub enum SioKind {
    Open,        // the client wants a session
    Connect,     // CONNECT for a namespace
    Event,       // an event, with its name and arguments
    Ack,         // a reply to an event this server asked to be acked
    Ping,        // Engine.IO keepalive, already answered
    Disconnect,
    Other,
}

pub gc struct SioEvent {
    kind: SioKind,
    namespace: str,
    name: str,
    args_json: str,
    ack: int,
}

// The first thing a socket.io connection needs: its session id and the
// keepalive timings, as a text frame.
pub fn sio_open(c: Conn, sid: str, s: SioSettings) -> bytes {
    c.sid = sid;
    return text_frame(sio.open_packet(sid, s.ping_interval_ms,
                                      s.ping_timeout_ms, s.max_payload));
}

// Turns one WebSocket text message into a socket.io event. An
// Engine.IO ping is answered into the connection's outbox, so a
// service that ignores `Ping` events still keeps the client alive.
pub fn sio_receive(c: Conn, m: Message) -> result[SioEvent, str] {
    if m.kind != Incoming.Text {
        return err("a socket.io packet must arrive in a text frame");
    }
    let pr = sio.decode(m.text);
    guard let p = pr else let e = err_of(pr) {
        return err(e);
    }
    if p.eio == sio.Eio.Ping {
        c.outbox = c.outbox + text_frame(sio.pong());
        return ok(one(SioKind.Ping, "/", "", "[]", -1));
    }
    if p.eio == sio.Eio.Close {
        return ok(one(SioKind.Disconnect, "/", "", "[]", -1));
    }
    if p.eio != sio.Eio.Message {
        return ok(one(SioKind.Other, "/", "", "[]", -1));
    }
    if p.sio == sio.Sio.Connect {
        return ok(one(SioKind.Connect, p.namespace, "", p.payload, -1));
    }
    if p.sio == sio.Sio.Disconnect {
        return ok(one(SioKind.Disconnect, p.namespace, "", "[]", -1));
    }
    if p.sio == sio.Sio.Ack {
        return ok(one(SioKind.Ack, p.namespace, "", p.payload, p.ack));
    }
    if p.sio == sio.Sio.Event || p.sio == sio.Sio.BinaryEvent {
        return ok(one(SioKind.Event, p.namespace,
                      sio.event_name(p.payload),
                      sio.event_args(p.payload), p.ack));
    }
    return ok(one(SioKind.Other, p.namespace, "", "[]", -1));
}

fn one(k: SioKind, ns: str, name: str, args: str, ack: int) -> SioEvent {
    return SioEvent {
        kind: k,
        namespace: ns,
        name: name,
        args_json: args,
        ack: ack
    };
}

// The answer to a CONNECT. A client that does not receive this waits
// forever without reporting anything.
pub fn sio_connect_ok(c: Conn, namespace: str) -> bytes {
    return text_frame(sio.connect_ok(namespace, c.sid));
}

pub fn sio_connect_error(namespace: str, why: str) -> bytes {
    return text_frame(sio.connect_error(namespace, why));
}

// `emit(name, args)`. `args_json` is the inside of a JSON array, which
// the caller has already encoded.
pub fn sio_emit(namespace: str, name: str, args_json: str) -> bytes {
    return text_frame(sio.event(namespace, name, args_json));
}

pub fn sio_emit_with_ack(namespace: str, name: str, args_json: str,
                         id: int) -> bytes {
    return text_frame(sio.event_with_ack(namespace, name, args_json, id));
}

// The reply to an event that carried an ack id.
pub fn sio_ack(namespace: str, id: int, args_json: str) -> bytes {
    return text_frame(sio.ack(namespace, id, args_json));
}

pub fn sio_disconnect(namespace: str) -> bytes {
    return text_frame(sio.disconnect(namespace));
}
