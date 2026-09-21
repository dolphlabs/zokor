// Socket.IO, over Engine.IO, over WebSocket.
//
// A socket.io client does not speak WebSocket directly: it speaks
// Engine.IO, which is a one-character packet type followed by a
// payload, and Socket.IO sits inside Engine.IO's "message" packet as
// another digit plus a JSON array. So `42["chat","hi"]` on the wire is
//
//     4          Engine.IO MESSAGE
//      2         Socket.IO EVENT
//       ["chat","hi"]   the event name and its arguments
//
// Everything here is that encoding and nothing else: no sockets, no
// sessions, no timers. The protocol numbers are Engine.IO v4 and
// Socket.IO v5, which is what socket.io-client 3 and 4 speak.

pub enum Eio {
    Open,     // 0: the server's handshake payload
    Close,    // 1
    Ping,     // 2
    Pong,     // 3
    Message,  // 4: carries a Socket.IO packet
    Upgrade,  // 5
    Noop,     // 6
}

pub enum Sio {
    Connect,       // 0
    Disconnect,    // 1
    Event,         // 2
    Ack,           // 3
    ConnectError,  // 4
    BinaryEvent,   // 5
    BinaryAck,     // 6
}

pub gc struct Packet {
    eio: Eio,
    sio: Sio,
    // Set only when eio is Message: the namespace ("/" by default), the
    // acknowledgement id (-1 when there is none) and the raw JSON array
    // of arguments, which the caller decodes or forwards as it likes.
    namespace: str,
    ack: int,
    payload: str,
    // For a non-message packet: whatever followed the type character.
    data: str,
}

pub fn eio_code(t: Eio) -> int {
    if t == Eio.Open { return 0; }
    if t == Eio.Close { return 1; }
    if t == Eio.Ping { return 2; }
    if t == Eio.Pong { return 3; }
    if t == Eio.Message { return 4; }
    if t == Eio.Upgrade { return 5; }
    return 6;
}

fn eio_of(c: int) -> result[Eio, str] {
    if c == 48 { return ok(Eio.Open); }
    if c == 49 { return ok(Eio.Close); }
    if c == 50 { return ok(Eio.Ping); }
    if c == 51 { return ok(Eio.Pong); }
    if c == 52 { return ok(Eio.Message); }
    if c == 53 { return ok(Eio.Upgrade); }
    if c == 54 { return ok(Eio.Noop); }
    return err("unknown Engine.IO packet type");
}

fn sio_of(c: int) -> result[Sio, str] {
    if c == 48 { return ok(Sio.Connect); }
    if c == 49 { return ok(Sio.Disconnect); }
    if c == 50 { return ok(Sio.Event); }
    if c == 51 { return ok(Sio.Ack); }
    if c == 52 { return ok(Sio.ConnectError); }
    if c == 53 { return ok(Sio.BinaryEvent); }
    if c == 54 { return ok(Sio.BinaryAck); }
    return err("unknown Socket.IO packet type");
}

pub fn sio_code(t: Sio) -> int {
    if t == Sio.Connect { return 0; }
    if t == Sio.Disconnect { return 1; }
    if t == Sio.Event { return 2; }
    if t == Sio.Ack { return 3; }
    if t == Sio.ConnectError { return 4; }
    if t == Sio.BinaryEvent { return 5; }
    return 6;
}

// ---------------------------------------------------------------- //
// Decoding                                                           //
// ---------------------------------------------------------------- //

pub fn decode(text: str) -> result[Packet, str] {
    let b = to_bytes(text);
    let n = len(b);
    if n == 0 {
        return err("an empty Engine.IO packet");
    }
    let er = eio_of(b[0]);
    guard let eio = er else let e = err_of(er) {
        return err(e);
    }
    let rest = "";
    if n > 1 {
        rest = to_str(b[1..n]);
    }
    if eio != Eio.Message {
        return ok(Packet {
            eio: eio,
            sio: Sio.Event,
            namespace: "/",
            ack: -1,
            payload: "",
            data: rest
        });
    }
    return decode_message(rest);
}

// `2/admin,7["ev",{...}]` -- type, optional namespace ending in a
// comma, optional ack id, then the JSON array.
fn decode_message(s: str) -> result[Packet, str] {
    let b = to_bytes(s);
    let n = len(b);
    if n == 0 {
        return err("an Engine.IO message with no Socket.IO packet");
    }
    let sr = sio_of(b[0]);
    guard let sio = sr else let e = err_of(sr) {
        return err(e);
    }
    let i = 1;
    // binary packets announce their attachment count as "<n>-"
    if sio == Sio.BinaryEvent || sio == Sio.BinaryAck {
        let saw = false;
        while i < n && b[i] >= 48 && b[i] <= 57 {
            saw = true;
            i = i + 1;
        }
        if !saw || i >= n || b[i] != 45 {
            return err("a binary Socket.IO packet needs an attachment count");
        }
        i = i + 1;
    }
    let namespace = "/";
    if i < n && b[i] == 47 {
        let start = i;
        while i < n && b[i] != 44 {
            i = i + 1;
        }
        namespace = to_str(b[start..i]);
        if i < n {
            i = i + 1;   // the comma
        }
    }
    let ack = -1;
    if i < n && b[i] >= 48 && b[i] <= 57 {
        let start = i;
        while i < n && b[i] >= 48 && b[i] <= 57 {
            i = i + 1;
        }
        ack = to_int(to_str(b[start..i])) ?? -1;
    }
    let payload = "";
    if i < n {
        payload = to_str(b[i..n]);
    }
    return ok(Packet {
        eio: Eio.Message,
        sio: sio,
        namespace: namespace,
        ack: ack,
        payload: payload,
        data: ""
    });
}

// The event name out of `["name", arg, ...]`, without decoding the
// whole array: the name is always the first element and always a
// string, and a service routes on it.
pub fn event_name(payload: str) -> str {
    let b = to_bytes(payload);
    let n = len(b);
    let i = 0;
    while i < n && (b[i] == 32 || b[i] == 9) {
        i = i + 1;
    }
    if i >= n || b[i] != 91 {
        return "";
    }
    i = i + 1;
    while i < n && (b[i] == 32 || b[i] == 9) {
        i = i + 1;
    }
    if i >= n || b[i] != 34 {
        return "";
    }
    i = i + 1;
    let out: bytes = b"";
    while i < n {
        if b[i] == 92 && i + 1 < n {
            out = out + b[i + 1..i + 2];
            i = i + 2;
            continue;
        }
        if b[i] == 34 {
            return to_str(out);
        }
        out = out + b[i..i + 1];
        i = i + 1;
    }
    return "";
}

// Everything after the event name: `["ev",1,2]` -> `[1,2]`, ready to be
// forwarded to another client or parsed by the handler.
pub fn event_args(payload: str) -> str {
    let b = to_bytes(payload);
    let n = len(b);
    let i = 0;
    while i < n && b[i] != 91 {
        i = i + 1;
    }
    if i >= n {
        return "[]";
    }
    i = i + 1;
    // skip the first element (the name), respecting escapes
    while i < n && (b[i] == 32 || b[i] == 9) {
        i = i + 1;
    }
    if i < n && b[i] == 34 {
        i = i + 1;
        while i < n {
            if b[i] == 92 && i + 1 < n {
                i = i + 2;
                continue;
            }
            if b[i] == 34 {
                i = i + 1;
                break;
            }
            i = i + 1;
        }
    }
    while i < n && (b[i] == 32 || b[i] == 9) {
        i = i + 1;
    }
    if i < n && b[i] == 44 {
        i = i + 1;
    }
    let end = n;
    while end > i && b[end - 1] != 93 {
        end = end - 1;
    }
    if end <= i {
        return "[]";
    }
    return "[" + to_str(b[i..end - 1]) + "]";
}

// ---------------------------------------------------------------- //
// Encoding                                                           //
// ---------------------------------------------------------------- //

fn digit(n: int) -> str {
    let one: bytes = b".";
    one[0] = 48 + n;
    return to_str(one);
}

pub fn encode_eio(t: Eio, data: str) -> str {
    return digit(eio_code(t)) + data;
}

// The server's first packet: the session id, which transports may be
// upgraded to, and the two timers a client uses to decide the
// connection is dead. Over WebSocket there is nothing to upgrade TO,
// so `upgrades` is empty.
pub fn open_packet(sid: str, ping_interval_ms: int, ping_timeout_ms: int,
                   max_payload: int) -> str {
    return encode_eio(Eio.Open,
        "{\"sid\":\"" + escape(sid) + "\",\"upgrades\":[]," +
        "\"pingInterval\":" + to_str(ping_interval_ms) +
        ",\"pingTimeout\":" + to_str(ping_timeout_ms) +
        ",\"maxPayload\":" + to_str(max_payload) + "}");
}

pub fn ping() -> str {
    return encode_eio(Eio.Ping, "");
}

pub fn pong() -> str {
    return encode_eio(Eio.Pong, "");
}

pub fn close_packet() -> str {
    return encode_eio(Eio.Close, "");
}

fn message(sio: Sio, namespace: str, ack: int, payload: str) -> str {
    let out = digit(eio_code(Eio.Message)) + digit(sio_code(sio));
    if len(namespace) > 0 && namespace != "/" {
        out = out + namespace + ",";
    }
    if ack >= 0 {
        out = out + to_str(ack);
    }
    return out + payload;
}

// The answer to a client's CONNECT: v5 requires the session id back in
// a JSON object, and a client that does not get one waits forever.
pub fn connect_ok(namespace: str, sid: str) -> str {
    return message(Sio.Connect, namespace, -1,
                   "{\"sid\":\"" + escape(sid) + "\"}");
}

pub fn connect_error(namespace: str, why: str) -> str {
    return message(Sio.ConnectError, namespace, -1,
                   "{\"message\":\"" + escape(why) + "\"}");
}

// `emit(name, args)` where `args` is a JSON array's INSIDE: the caller
// has already encoded its arguments, because zokor does not choose a
// JSON encoder for anyone.
pub fn event(namespace: str, name: str, args_json: str) -> str {
    return message(Sio.Event, namespace, -1, array_of(name, args_json));
}

// The same, but asking the client to acknowledge: the client answers
// with an Ack carrying the same id.
pub fn event_with_ack(namespace: str, name: str, args_json: str,
                      ack: int) -> str {
    return message(Sio.Event, namespace, ack, array_of(name, args_json));
}

// The reply to a client event that asked for an acknowledgement.
pub fn ack(namespace: str, id: int, args_json: str) -> str {
    let body = args_json;
    if len(body) == 0 {
        body = "[]";
    }
    return message(Sio.Ack, namespace, id, body);
}

pub fn disconnect(namespace: str) -> str {
    return message(Sio.Disconnect, namespace, -1, "");
}

fn array_of(name: str, args_json: str) -> str {
    let inner = trim(args_json);
    if len(inner) == 0 || inner == "[]" {
        return "[\"" + escape(name) + "\"]";
    }
    if starts(inner, "[") && ends(inner, "]") {
        let b = to_bytes(inner);
        return "[\"" + escape(name) + "\"," + to_str(b[1..len(b) - 1]) + "]";
    }
    // a single value that is not already an array
    return "[\"" + escape(name) + "\"," + inner + "]";
}

pub fn escape(s: str) -> str {
    let b = to_bytes(s);
    let out = "";
    let i = 0;
    while i < len(b) {
        let c = b[i];
        if c == 34 {
            out = out + "\\\"";
        } else if c == 92 {
            out = out + "\\\\";
        } else if c == 10 {
            out = out + "\\n";
        } else if c == 13 {
            out = out + "\\r";
        } else if c == 9 {
            out = out + "\\t";
        } else if c < 32 {
            out = out + "\\u00" + hex2(c);
        } else {
            out = out + to_str(b[i..i + 1]);
        }
        i = i + 1;
    }
    return out;
}

fn hex2(c: int) -> str {
    let d = to_bytes("0123456789abcdef");
    let out: bytes = b"..";
    out[0] = d[(c / 16) % 16];
    out[1] = d[c % 16];
    return to_str(out);
}

fn trim(s: str) -> str {
    let b = to_bytes(s);
    let n = len(b);
    let a = 0;
    while a < n && (b[a] == 32 || b[a] == 9 || b[a] == 10 || b[a] == 13) {
        a = a + 1;
    }
    let e = n;
    while e > a && (b[e - 1] == 32 || b[e - 1] == 9 || b[e - 1] == 10 ||
                    b[e - 1] == 13) {
        e = e - 1;
    }
    if a == 0 && e == n {
        return s;
    }
    return to_str(b[a..e]);
}

fn starts(s: str, p: str) -> bool {
    let a = to_bytes(s);
    let b = to_bytes(p);
    if len(b) > len(a) {
        return false;
    }
    let i = 0;
    while i < len(b) {
        if a[i] != b[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

fn ends(s: str, p: str) -> bool {
    let a = to_bytes(s);
    let b = to_bytes(p);
    if len(b) > len(a) {
        return false;
    }
    let off = len(a) - len(b);
    let i = 0;
    while i < len(b) {
        if a[off + i] != b[i] {
            return false;
        }
        i = i + 1;
    }
    return true;
}
