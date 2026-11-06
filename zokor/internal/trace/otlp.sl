// OTLP/HTTP JSON, the wire form of a finished span. Pure: it takes values
// and returns text, so every field of the format has a test and none
// needs a collector.
import "builder";
import "json";

pub let KIND_SERVER = 2;
pub let KIND_CLIENT = 3;
pub let KIND_INTERNAL = 1;

let STATUS_ERROR = 2;

pub struct Attr {
    key: str,
    text: str,
    // Set instead of `text` when `is_int`.
    num: int,
    is_int: bool,
}

pub fn attr_str(key: str, value: str) -> Attr {
    return Attr { key: key, text: value, num: 0, is_int: false };
}

pub fn attr_int(key: str, value: int) -> Attr {
    return Attr { key: key, text: "", num: value, is_int: true };
}

pub gc struct SpanData {
    trace_id: str,
    span_id: str,
    parent_id: str,
    name: str,
    kind: int,
    start_ns: int,
    end_ns: int,
    attrs: [Attr],
    failed: bool,
    message: str,
}

fn text_of(s: str) -> str {
    return json.encode(s);
}

// OTLP's JSON mapping writes 64-bit integers as strings, so nothing
// between here and the collector can round them through a double.
fn attr_into(sb: builder.Str, a: Attr) {
    sb.write("{\"key\":");
    sb.write(text_of(a.key));
    if a.is_int {
        sb.write(",\"value\":{\"intValue\":\"");
        sb.write(to_str(a.num));
        sb.write("\"}}");
        return;
    }
    sb.write(",\"value\":{\"stringValue\":");
    sb.write(text_of(a.text));
    sb.write("}}");
}

// One span as an element of OTLP's `spans` array.
pub fn span_json(s: SpanData) -> str {
    let sb = builder.new_str();
    sb.write("{\"traceId\":\"");
    sb.write(s.trace_id);
    sb.write("\",\"spanId\":\"");
    sb.write(s.span_id);
    sb.write("\",");
    if len(s.parent_id) > 0 {
        sb.write("\"parentSpanId\":\"");
        sb.write(s.parent_id);
        sb.write("\",");
    }
    sb.write("\"name\":");
    sb.write(text_of(s.name));
    sb.write(",\"kind\":");
    sb.write(to_str(s.kind));
    sb.write(",\"startTimeUnixNano\":\"");
    sb.write(to_str(s.start_ns));
    sb.write("\",\"endTimeUnixNano\":\"");
    sb.write(to_str(s.end_ns));
    sb.write("\",\"attributes\":[");
    let i = 0;
    for a in s.attrs {
        if i > 0 {
            sb.write(",");
        }
        attr_into(sb, a);
        i = i + 1;
    }
    sb.write("]");
    if s.failed {
        sb.write(",\"status\":{\"code\":");
        sb.write(to_str(STATUS_ERROR));
        sb.write(",\"message\":");
        sb.write(text_of(s.message));
        sb.write("}");
    }
    sb.write("}");
    return sb.finish();
}

// The body of one POST to /v1/traces: `spans` are span_json results.
pub fn export_json(service: str, spans: [str]) -> str {
    let sb = builder.new_str();
    sb.write("{\"resourceSpans\":[{\"resource\":{\"attributes\":[");
    attr_into(sb, attr_str("service.name", service));
    sb.write("]},\"scopeSpans\":[{\"scope\":{\"name\":\"zokor\"},\"spans\":[");
    let i = 0;
    for s in spans {
        if i > 0 {
            sb.write(",");
        }
        sb.write(s);
        i = i + 1;
    }
    sb.write("]}]}]}");
    return sb.finish();
}

fn hex_digit(c: int) -> int {
    if c >= 48 && c <= 57 { return c - 48; }
    if c >= 97 && c <= 102 { return c - 87; }
    return 0;
}

// Whether a new trace is sampled, from the trace id alone: its last 28
// bits as a fraction. Every service, given the same ratio, decides alike.
pub fn sampled(trace_id: str, ratio: float) -> bool {
    if ratio <= 0.0 {
        return false;
    }
    if ratio >= 1.0 {
        return true;
    }
    let b = to_bytes(trace_id);
    let v = 0;
    let i = len(b) - 7;
    if i < 0 {
        i = 0;
    }
    while i < len(b) {
        v = v * 16 + hex_digit(b[i] as int);
        i = i + 1;
    }
    return (v as float) < ratio * 268435456.0;
}

// The host of a URL, without its scheme, credentials, path or query: what
// may be written on a span, since a URL can hold a secret.
pub fn url_host(url: str) -> str {
    let b = to_bytes(url);
    let n = len(b);
    let i = 0;
    let start = 0;
    while i + 2 < n {
        if b[i] == 58 && b[i + 1] == 47 && b[i + 2] == 47 {
            start = i + 3;
            break;
        }
        i = i + 1;
    }
    let end = start;
    while end < n && b[end] != 47 && b[end] != 63 && b[end] != 35 {
        end = end + 1;
    }
    let at = end - 1;
    while at >= start {
        if b[at] == 64 {
            start = at + 1;
            break;
        }
        at = at - 1;
    }
    return to_str(b[start..end]);
}
