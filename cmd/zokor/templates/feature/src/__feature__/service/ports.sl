import "../domain" as domain;

// What the service needs from storage, as function values: store/
// implements them, fakes_test.sl fakes them. C is the adapter's own
// state, passed explicitly (slang has no closures). An err is the store
// failing -- logged, never shown to a client; absence is none, not an err.
pub gc struct __Entity__Store[C] {
    context: C,
    insert: fn(C, domain.__Entity__) -> result[bool, str],
    // tenant id, __entity__ id
    find: fn(C, str, str) -> result[opt[domain.__Entity__], str],
    // tenant id, offset, limit
    list: fn(C, str, int, int) -> result[[domain.__Entity__], str],
}
