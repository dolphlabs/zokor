import "http";
import "zokor";
import "../../platform/app" as app;
import "../service" as __feature__;

// The __feature__ feature's error codes, registered once at startup. A failure
// is answered through these and nothing else, so every client sees the
// same envelope.
fn register_errors(r: zokor.Registry) {
    zokor.register(r, "__feature__.not_found", 404, "no such __entity__");
    zokor.register(r, "__feature__.unavailable", 503, "__feature__ are unavailable, try again");
}

// A use case's failure, as the answer to send. A store's own error is
// logged with the request id and never reaches the client.
fn failure(c: zokor.Ctx[app.App], f: __feature__.Failed) -> http.Response {
    if f.why == __feature__.Why.Invalid {
        let fields: [zokor.FieldError] = [];
        for p in f.problems {
            push(fields, zokor.field(p.field, p.reason));
        }
        return zokor.respond_fields(c.errors, "validation_failed", fields, c.request_id);
    }
    if f.why == __feature__.Why.NotFound {
        return zokor.respond(c.errors, "__feature__.not_found", c.request_id);
    }
    c.state.settings.server.logger.error("__feature__", "store failed (" + c.request_id + "): " + f.detail);
    return zokor.respond(c.errors, "__feature__.unavailable", c.request_id);
}
