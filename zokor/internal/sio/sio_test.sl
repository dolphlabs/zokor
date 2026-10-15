fn dec(s: str) -> Packet {
    let r = decode(s);
    guard let p = r else let e = err_of(r) {
        panic("expected a packet from '" + s + "': " + e);
    }
    return p;
}

fn bad(s: str) -> str {
    let r = decode(s);
    guard let _p = r else let e = err_of(r) {
        return e;
    }
    return "";
}

// The shapes socket.io-client actually puts on the wire.
fn test_engineio_control_packets() {
    assert(dec("2").eio == Eio.Ping);
    assert(dec("3").eio == Eio.Pong);
    assert(dec("1").eio == Eio.Close);
    assert(dec("5").eio == Eio.Upgrade);
    assert(dec("6").eio == Eio.Noop);
    assert(dec("2probe").eio == Eio.Ping);
    assert(dec("2probe").data == "probe");
}

fn test_socketio_connect() {
    let p = dec("40");
    assert(p.eio == Eio.Message);
    assert(p.sio == Sio.Connect);
    assert(p.namespace == "/");
    assert(p.ack == -1);

    let ns = dec("40/admin,");
    assert(ns.sio == Sio.Connect);
    assert(ns.namespace == "/admin");

    let with_auth = dec("40{\"token\":\"abc\"}");
    assert(with_auth.sio == Sio.Connect);
    assert(with_auth.payload == "{\"token\":\"abc\"}");
}

fn test_socketio_event() {
    let p = dec("42[\"chat message\",\"hi\"]");
    assert(p.eio == Eio.Message);
    assert(p.sio == Sio.Event);
    assert(p.namespace == "/");
    assert(p.ack == -1);
    assert(p.payload == "[\"chat message\",\"hi\"]");
    assert(event_name(p.payload) == "chat message");
    assert(event_args(p.payload) == "[\"hi\"]");
}

fn test_event_in_a_namespace_with_an_ack() {
    let p = dec("42/admin,7[\"kick\",{\"id\":3}]");
    assert(p.sio == Sio.Event);
    assert(p.namespace == "/admin");
    assert(p.ack == 7);
    assert(event_name(p.payload) == "kick");
    assert(event_args(p.payload) == "[{\"id\":3}]");
}

fn test_ack_and_disconnect() {
    let a = dec("431[\"ok\"]");
    assert(a.sio == Sio.Ack);
    assert(a.ack == 1);
    assert(a.payload == "[\"ok\"]");

    let d = dec("41/admin,");
    assert(d.sio == Sio.Disconnect);
    assert(d.namespace == "/admin");
}

fn test_binary_packets_declare_attachments() {
    let p = dec("451-[\"file\",{\"_placeholder\":true,\"num\":0}]");
    assert(p.sio == Sio.BinaryEvent);
    assert(event_name(p.payload) == "file");
    assert(bad("45[\"file\"]") ==
           "a binary Socket.IO packet needs an attachment count");
}

fn test_event_name_and_args_edge_cases() {
    assert(event_name("[\"with \\\"quotes\\\"\",1]") == "with \"quotes\"");
    assert(event_args("[\"only\"]") == "[]");
    assert(event_args("[\"ev\",1,2,3]") == "[1,2,3]");
    assert(event_args("[\"ev\",{\"a\":[1,2]}]") == "[{\"a\":[1,2]}]");
    assert(event_name("not an array") == "");
    assert(event_args("") == "[]");
}

fn test_decode_refusals() {
    assert(bad("") == "an empty Engine.IO packet");
    assert(bad("9") == "unknown Engine.IO packet type");
    assert(bad("4") == "an Engine.IO message with no Socket.IO packet");
    assert(bad("49") == "unknown Socket.IO packet type");
}

fn test_open_packet() {
    let s = open_packet("abc123", 25000, 20000, 1000000);
    assert(s == "0{\"sid\":\"abc123\",\"upgrades\":[],\"pingInterval\":25000,\"pingTimeout\":20000,\"maxPayload\":1000000}");
    assert(dec(s).eio == Eio.Open);
}

fn test_encoding_matches_what_clients_expect() {
    assert(ping() == "2");
    assert(pong() == "3");
    assert(close_packet() == "1");
    assert(connect_ok("/", "abc") == "40{\"sid\":\"abc\"}");
    assert(connect_ok("/admin", "abc") == "40/admin,{\"sid\":\"abc\"}");
    assert(connect_error("/", "nope") == "44{\"message\":\"nope\"}");
    assert(disconnect("/") == "41");
    assert(disconnect("/admin") == "41/admin,");
    assert(event("/", "chat", "[\"hi\"]") == "42[\"chat\",\"hi\"]");
    assert(event("/", "tick", "") == "42[\"tick\"]");
    assert(event("/", "tick", "[]") == "42[\"tick\"]");
    assert(event("/admin", "kick", "[3]") == "42/admin,[\"kick\",3]");
    assert(event("/", "one", "5") == "42[\"one\",5]");
    assert(event_with_ack("/", "ask", "[1]", 7) == "427[\"ask\",1]");
    assert(ack("/", 7, "[\"done\"]") == "437[\"done\"]");
    assert(ack("/admin", 2, "") == "43/admin,2[]");
}

fn test_a_round_trip_through_the_codec() {
    let out = event("/room", "message", "[{\"text\":\"hi\"}]");
    let p = dec(out);
    assert(p.eio == Eio.Message);
    assert(p.sio == Sio.Event);
    assert(p.namespace == "/room");
    assert(event_name(p.payload) == "message");
    assert(event_args(p.payload) == "[{\"text\":\"hi\"}]");
}

fn test_names_are_escaped() {
    let out = event("/", "with \"quote\"", "[]");
    assert(out == "42[\"with \\\"quote\\\"\"]");
    assert(event_name(dec(out).payload) == "with \"quote\"");
}

// The count a binary packet announces is kept: the server has to know
// how many attachments to wait for.
fn test_binary_packets_keep_their_attachment_count() {
    let p = dec("452-[\"upload\",{\"_placeholder\":true,\"num\":0},{\"_placeholder\":true,\"num\":1}]");
    assert(p.sio == Sio.BinaryEvent);
    assert(p.attachments == 2, "attachments " + to_str(p.attachments));
    let a = dec("461-/files,9[{\"_placeholder\":true,\"num\":0}]");
    assert(a.sio == Sio.BinaryAck && a.attachments == 1 && a.ack == 9 && a.namespace == "/files");
    assert(dec("42[\"x\"]").attachments == 0);
    assert(len(bad("45999999999-[\"x\"]")) > 0, "an absurd attachment count was accepted");
}

// What socket.io-client's decoder reconstructs ArrayBuffers from.
fn test_binary_event_encoding() {
    assert(binary_event("/", "file", "\"a.png\"", 1, -1) ==
           "451-[\"file\",\"a.png\",{\"_placeholder\":true,\"num\":0}]");
    assert(binary_event("/up", "two", "", 2, 4) ==
           "452-/up,4[\"two\",{\"_placeholder\":true,\"num\":0},{\"_placeholder\":true,\"num\":1}]");
}

fn test_open_packet_offers_websocket_to_polling_sessions() {
    assert(open_packet_with("s1", "[\"websocket\"]", 25000, 20000, 1000000) ==
           "0{\"sid\":\"s1\",\"upgrades\":[\"websocket\"],\"pingInterval\":25000,\"pingTimeout\":20000,\"maxPayload\":1000000}");
}
