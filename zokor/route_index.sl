// The route index: a segment trie over Router.routes, so matching costs
// the path's depth instead of the route count.
//
// The list stays the source of truth -- registration order, "first
// registered wins", routes_list -- and the trie only finds candidates:
// each node keeps the indices of the routes ending there, and of the
// `*rest` routes taking the rest from there. A lookup walks the literal
// child and the `:param` child of every node on the path and returns
// the SMALLEST matching index whose method fits, which is exactly the
// route a scan in registration order would have picked.
//
// Below INDEX_FROM routes the router keeps scanning: a short list beats
// splitting the path, and the frame path's no-allocation fast paths stay
// as they were. Measured in bench/audit's router case (200 requests to the
// last of n one-parameter routes) -- see the numbers in todo.md.

gc struct RNode {
    lit: map[str]RNode,
    // the `:param` child, when one exists: a list of 0 or 1
    param: [RNode],
    ends: [int],
    wilds: [int],
}

fn rnode() -> RNode {
    let lit: map[str]RNode = {};
    let p: [RNode] = [];
    let e: [int] = [];
    let w: [int] = [];
    return RNode { lit: lit, param: p, ends: e, wilds: w };
}

// Routes up to this many are scanned.
fn index_from() -> int {
    return 16;
}

// Adds route `i` (its pattern's segments, param names and wildcard
// position) under `root`.
fn rindex_insert(root: RNode, i: int, segs: [str], names: [str], wild: int) {
    let node = root;
    let k = 0;
    while k < len(segs) {
        if k == wild {
            push(node.wilds, i);
            return;
        }
        if len(names[k]) > 0 {
            if len(node.param) == 0 {
                push(node.param, rnode());
            }
            node = node.param[0];
        } else {
            let s = segs[k];
            if !has(node.lit, s) {
                node.lit[s] = rnode();
            }
            node = node.lit[s];
        }
        k = k + 1;
    }
    push(node.ends, i);
}

fn route_fits(m: Method, want: Method, head_of_get: bool) -> bool {
    return m == want || (head_of_get && m == Method.GET);
}

fn smaller(a: int, b: int) -> int {
    if a < 0 {
        return b;
    }
    if b < 0 || a < b {
        return a;
    }
    return b;
}

// The first registered route matching `segs` whose method fits, or -1.
fn rindex_best[S](routes: [Route[S]], node: RNode, segs: [str], d: int, want: Method,
                  head_of_get: bool) -> int {
    let best = -1;
    for i in node.wilds {
        if route_fits(routes[i].method, want, head_of_get) {
            best = smaller(best, i);
        }
    }
    if d == len(segs) {
        for i in node.ends {
            if route_fits(routes[i].method, want, head_of_get) {
                best = smaller(best, i);
            }
        }
        return best;
    }
    let s = segs[d];
    if has(node.lit, s) {
        best = smaller(best, rindex_best(routes, node.lit[s], segs, d + 1, want, head_of_get));
    }
    if len(node.param) > 0 {
        best = smaller(best, rindex_best(routes, node.param[0], segs, d + 1, want, head_of_get));
    }
    return best;
}

// Whether any route matches `segs`, whatever its method (for 405 vs 404).
fn rindex_any(node: RNode, segs: [str], d: int) -> bool {
    if len(node.wilds) > 0 {
        return true;
    }
    if d == len(segs) {
        return len(node.ends) > 0;
    }
    let s = segs[d];
    if has(node.lit, s) && rindex_any(node.lit[s], segs, d + 1) {
        return true;
    }
    return len(node.param) > 0 && rindex_any(node.param[0], segs, d + 1);
}
