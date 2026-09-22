# Performance audit results

`slangc bench/audit/main.sl --run`, one Mac, one run per size — treat as
an order of magnitude, not a guarantee. Sizes are 16 KB / 32 KB / 64 KB /
128 KB unless noted; the router case counts routes, not bytes.

## Before

Every case below grew far faster than its input doubled — several were
outright quadratic. The worst: parsing a 128 KB JSON string containing one
long string field took **5.9 seconds**; rewriting the keys of an
8,000-field object took **797 ms**; parsing 128 KB of escaped text inside
a JSON string took **2.8 seconds**.

## After

| case | 16 KB | 128 KB | growth per doubling |
|---|---|---|---|
| `json.parse`, one long string | 203us | 1.6ms | ~2x (linear) |
| `json.parse`, string with escapes | 1.9ms | 29.5ms | ~2-3x |
| `json.parse`, array of ints | 3.6ms | 60.8ms | ~2-3x |
| `json.parse` + `render`, long string | 390us | 3.4ms | ~2x (linear) |
| `snake_keys` (parse + rekey + render) | 23.1ms | 137ms | ~2-3x |
| `errors.quote` (long detail string) | 206us | 1.6ms | ~2x (linear) |
| multipart, one big file | 237us | 1.7ms | ~2x (linear) |
| multipart, many small fields | 6.0ms | 44.6ms | ~2-3x |
| `percent_decode` (all escapes) | 1.2ms | 25.5ms | ~2-3x |
| WebSocket, one message in 4 KB reads | 375us | 2.9ms | ~2x (linear) |
| WebSocket, one message, 1 KB fragments | 368us | 3.1ms | ~2x (linear) |
| router, 200 requests to the last of *n* routes | 12.1ms (64) | 110.6ms (512) | ~2x (linear) |

Everything that was seconds is now single- or double-digit milliseconds.
The purely linear cases (render, quote, one whole frame, one big file, the
router scan) hit ~2x per doubling, which is what O(n) looks like on real
hardware. The 2-3x cases are still doing more small allocations than a
tight C loop would — real cost, not a second algorithmic bug — and are
listed here rather than hidden.

## What changed, and why

- **`strings.join_bytes`** [slang]: the `[bytes]` counterpart of
  `strings.join`, one allocation and one copy of each piece.
- **`builder` package** [slang]: `Str` and `Bytes`, linear-time assembly.
  See `bench/builder/` in the slang repository.
- **`errors.quote`**: rewritten over a builder, walking the input once and
  copying the stretches between escapes as slices rather than appending
  one byte at a time.
- **`json.parse_string`**: the common case (no escape) is now one slice;
  with escapes, clean stretches are copied as slices between them.
- **`json.render`**: one builder for the whole document, instead of each
  level returning a string its parent joins (which copied every byte once
  per level of nesting).
- **`json.parse_object`** and **`json.rekey`** (used by `snake_keys` /
  `camel_keys`): duplicate-key detection was a linear scan per key, so
  building or rewriting a k-key object cost O(k^2). Past 12 keys both now
  use a `map[str]int` of key to position, built lazily so small objects
  (nearly all of them) pay nothing extra.
- **`internal/path.percent_decode`** and **`internal/multipart`**'s copy:
  span-based, like `parse_string`.
- **`internal/sio.escape`**: same span technique, since a
  `connect_error` message is developer-supplied text of unbounded length.
- **`router.match_segs`**: the wildcard tail was joined with one
  concatenation per path segment; now one `strings.join`.
- **`ws.Conn.receive`**: two remaining causes of quadratic behaviour on a
  connection receiving many small reads or many fragments:
  - Every call used to re-copy the ENTIRE buffered prefix, even when only
    a few new bytes had arrived and the frame was nowhere near complete.
    `ws.decode`'s `Incomplete` result now reports how many bytes the
    frame needs; `Conn` keeps that count and only assembles a buffer once
    enough has arrived, so a message arriving in n small reads costs O(n)
    instead of O(n^2). A frame arriving whole in one read is decoded
    directly from it, copying nothing.
  - A fragmented message's pieces were joined with `+` as each fragment
    arrived, copying the growing message on every fragment. Fragments now
    accumulate in a `builder.Bytes`.

## Not fixed here, and why

- **`http` package internals** (request/response parsing, header maps):
  outside zokor, in slang's stdlib. Not audited this pass.
- **The 2-3x-per-doubling cases** above: not zero-cost, still linear.
  Revisit if a real workload shows them as the bottleneck; chasing every
  allocation here would be premature.
