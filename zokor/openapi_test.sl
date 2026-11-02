import "http";
import "strings";

fn api_test_handler(c: Ctx[int]) -> http.Response { return text(200, "ok"); }

fn api_test_spec() -> OpenApi {
    let api = new_openapi("Users API", "1.0.0");
    api.schema("User", "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"},\"name\":{\"type\":\"string\"}},\"required\":[\"id\",\"name\"]}");
    api.schema("ZokorError", api_default_error_schema());
    api.error_schema = "ZokorError";
    let op = api_operation(Method.GET, "/users/:id");
    op.operation_id = "getUser";
    push(op.parameters, api_parameter("id", "path", "integer"));
    push(op.responses, api_response(200, "User"));
    push(op.errors, "not_found");
    api.operation(op);
    return api;
}

fn test_openapi_uses_registered_routes_dtos_and_error_codes() {
    let r = new_router(0);
    r.get("/users/:id", api_test_handler);
    let compiled = openapi_document(r.routes_list(), r.errors, api_test_spec());
    guard let text_ = compiled else let e = err_of(compiled) { panic(e); }
    let doc = jparsed(text_);
    assert(doc.get("openapi").str_or("") == "3.1.1");
    let op = doc.get("paths").get("/users/{id}").get("get");
    assert(op.get("operationId").str_or("") == "getUser");
    assert(op.get("parameters").at(0).get("required").bool_or(false));
    assert(op.get("parameters").at(0).get("schema").get("type").str_or("") == "integer");
    assert(op.get("responses").get("200").get("content").get("application/json").get("schema").get("$ref").str_or("") == "#/components/schemas/User");
    assert(op.get("responses").get("404").get("content").get("application/json").get("schema").get("$ref").str_or("") == "#/components/schemas/ZokorError");
    assert(doc.get("x-zokor-error-codes").get("not_found").get("status").int_or(0) == 404);
    assert(doc.get("components").get("schemas").get("User").get("required").size() == 2);
}

fn test_openapi_gathers_schema_route_and_operation_problems() {
    let r = new_router(0);
    r.get("/users/:id", api_test_handler);
    r.post("/users/:name", api_test_handler);
    r.get("/files/*rest", api_test_handler);
    let api = new_openapi("", "");
    api.schema("Bad/Name", "{\"type\":\"unknown\",\"required\":4,\"properties\":{\"next\":{\"$ref\":\"#/components/schemas/Missing\"}}}");
    api.schema("Broken", "{oops}");
    let op = api_operation(Method.GET, "/users/:id");
    op.request_schema = "MissingBody";
    push(op.parameters, api_parameter("absent", "path", "string"));
    let bad = api_parameter("q", "invalid", "NoType");
    push(op.parameters, bad);
    push(op.responses, api_response(204, "string"));
    push(op.errors, "missing_error");
    api.operation(op);
    let compiled = openapi_document(r.routes_list(), r.errors, api);
    guard let _doc = compiled else let e = err_of(compiled) {
        for field in ["title", "version", "schemas.Bad/Name", "schemas.Broken", ".type", ".required", ".next.$ref", "MissingBody", ".parameters", ".location", "NoType", ".responses", "missing_error", "different parameter names", "wildcard"] {
            assert(strings.contains(e, field), "missing " + field + " in " + e);
        }
        return;
    }
    panic("invalid metadata produced a document");
}

fn test_openapi_omissions_are_explicit_and_metadata_cannot_add_routes() {
    let r = new_router(0);
    r.get("/files/*rest", api_test_handler);
    r.connect("/tunnel", api_test_handler);
    r.get("/health", api_test_handler);
    let api = new_openapi("API", "1");
    api.omit(Method.GET, "/files/*rest");
    api.omit(Method.CONNECT, "/tunnel");
    let made = openapi_document(r.routes_list(), r.errors, api);
    let doc = jparsed(made ?? "");
    assert(doc.get("paths").size() == 1 && doc.get("paths").has_key("/health"));
    let response = doc.get("paths").get("/health").get("get").get("responses");
    assert(response.has_key("default") && !response.has_key("200"), "undeclared successes are not guessed");
    api.operation(api_operation(Method.POST, "/not-registered"));
    api.omit(Method.GET, "/also-missing");
    let bad = openapi_document(r.routes_list(), r.errors, api);
    guard let _bad = bad else let e = err_of(bad) {
        assert(strings.contains(e, "not-registered") && strings.contains(e, "also-missing")); return;
    }
    panic("metadata created a route");
}

fn test_openapi_supports_recursive_schemas_and_preserves_examples() {
    let api = new_openapi("API", "1");
    api.schema("Node", "{\"type\":\"object\",\"properties\":{\"child\":{\"anyOf\":[{\"$ref\":\"#/components/schemas/Node\"},{\"type\":\"null\"}]},\"tag\":{\"type\":[\"string\",\"null\"]}},\"examples\":[{\"$ref\":\"an ordinary example value\"}]}");
    api.schema("False", "false");
    let made = openapi_document([], new_registry(), api);
    guard let text_ = made else let e = err_of(made) { panic(e); }
    let schema = jparsed(text_).get("components").get("schemas").get("Node");
    assert(schema.get("examples").at(0).get("$ref").str_or("") == "an ordinary example value");
    assert(schema.get("properties").get("child").get("anyOf").size() == 2);
}

fn test_openapi_order_is_deterministic_and_generation_is_private() {
    let a = new_openapi("Quotes \" and\nnewlines", "1");
    let b = new_openapi(a.title, "1");
    a.schema("Z", "true"); a.schema("A", "{\"type\":\"string\"}");
    b.schema("A", "{\"type\":\"string\"}"); b.schema("Z", "true");
    let reg_a = new_registry();
    let reg_b = new_registry();
    register(reg_a, "z.last", 404, "last"); register(reg_a, "a.first", 404, "first");
    register(reg_b, "a.first", 404, "first"); register(reg_b, "z.last", 404, "last");
    let one = openapi_document(["GET /"], reg_a, a) ?? "";
    let two = openapi_document(["GET /"], reg_b, b) ?? "missing";
    assert(one == two && jparsed(one).get("info").get("title").str_or("") == a.title);
    assert(a.schemas["A"] == "{\"type\":\"string\"}" && len(a.operations) == 0);
    let before = one;
    a.schema("A", "{\"type\":\"integer\"}");
    assert(one == before && strings.contains(one, "\"type\":\"string\""));
}

fn test_openapi_custom_error_contract_is_explicit_and_same_status_codes_group() {
    let api = new_openapi("API", "1");
    let op = api_operation(Method.POST, "/users");
    op.request_schema = "User"; op.request_required = false;
    push(op.responses, api_response(201, "User"));
    push(op.errors, "bad_request"); push(op.errors, "malformed_json");
    api.schema("User", "{\"type\":\"object\"}");
    api.operation(op);
    let reg = new_registry();
    set_renderer(reg, tracing_custom_renderer);
    let made = openapi_document(["POST /users"], reg, api);
    let doc = jparsed(made ?? "");
    let generated = doc.get("paths").get("/users").get("post");
    assert(!generated.get("requestBody").get("required").bool_or(true));
    let error_ = generated.get("responses").get("400");
    assert(error_.get("x-zokor-error-codes").size() == 2 && !error_.has_key("content"));
    api.error_schema = "string";
    api.error_media_type = "text/plain";
    let bound = jparsed(openapi_document(["POST /users"], reg, api) ?? "");
    assert(bound.get("paths").get("/users").get("post").get("responses").get("400").get("content").get("text/plain").get("schema").get("type").str_or("") == "string");
}

fn test_openapi_duplicates_and_ignored_headers_are_reported() {
    let api = api_test_spec();
    let op = api_operation(Method.GET, "/users/:id");
    op.operation_id = "getUser";
    push(op.parameters, api_parameter("Authorization", "header", "string"));
    push(op.parameters, api_parameter("X-Id", "header", "string"));
    push(op.parameters, api_parameter("x-id", "header", "string"));
    api.operation(op);
    let made = openapi_document(["GET /users/:id", "GET /users//:id"], new_registry(), api);
    guard let _doc = made else let e = err_of(made) {
        assert(strings.contains(e, "duplicate operation metadata") && strings.contains(e, "operation_id") && strings.contains(e, "ignores this header") && strings.contains(e, "duplicate parameter") && strings.contains(e, "normalization"), e);
        return;
    }
    panic("duplicate metadata accepted");
}

fn test_openapi_limits_and_config_errors_are_named() {
    let api = new_openapi("", "");
    api.limits.max_routes = 0; api.limits.max_schemas = 0;
    api.limits.max_schema_bytes = 0; api.limits.max_total_schema_bytes = 0;
    api.limits.max_schema_depth = 65; api.limits.max_document_bytes = 0;
    api.limits.max_collection_entries = 0; api.limits.max_metadata_bytes = 0;
    let made = openapi_document([], new_registry(), api);
    guard let _doc = made else let e = err_of(made) {
        for field in ["title", "version", "max_routes", "max_schemas", "max_schema_bytes", "max_total_schema_bytes", "max_schema_depth", "max_document_bytes", "max_collection_entries", "max_metadata_bytes"] { assert(strings.contains(e, field), e); }
        let bounded = new_openapi("API", "1");
        bounded.limits.max_schema_bytes = 4;
        bounded.schema("User", "{\"type\":\"object\"}");
        let too_big = openapi_document([], new_registry(), bounded);
        guard let _big = too_big else let be = err_of(too_big) {
            assert(strings.contains(be, "max_schema_bytes"));
            bounded.schemas = {};
            bounded.limits.max_document_bytes = 1;
            let output = openapi_document([], new_registry(), bounded);
            guard let _out = output else let oe = err_of(output) { assert(strings.contains(oe, "max_document_bytes")); return; }
            panic("document cap ignored");
        }
        panic("schema cap ignored");
    }
    panic("bad limits accepted");
}

fn test_openapi_schema_depth_totals_and_collection_limits() {
    let api = new_openapi("API", "1");
    api.limits.max_total_schema_bytes = 8;
    api.schema("One", "true"); api.schema("Two", "false");
    let total = openapi_document([], new_registry(), api);
    guard let _total = total else let e = err_of(total) {
        assert(strings.contains(e, "max_total_schema_bytes"));
        api.schemas = {};
        api.limits.max_total_schema_bytes = 1048576;
        api.limits.max_schema_depth = 1;
        api.schema("Deep", "{\"type\":\"object\",\"properties\":{\"child\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}");
        let deep = openapi_document([], new_registry(), api);
        guard let _deep = deep else let de = err_of(deep) {
            assert(strings.contains(de, "max_schema_depth"));
            api.schemas = {};
            api.limits.max_collection_entries = 1;
            let capped = openapi_document([], new_registry(), api);
            guard let _cap = capped else let ce = err_of(capped) {
                assert(strings.contains(ce, "error_codes") && strings.contains(ce, "max_collection_entries"));
                api.limits.max_collection_entries = 1000;
                api.limits.max_metadata_bytes = 1;
                let bytes_ = openapi_document([], new_registry(), api);
                guard let _bytes = bytes_ else let be = err_of(bytes_) { assert(strings.contains(be, "max_metadata_bytes")); return; }
                panic("metadata byte cap ignored");
            }
            panic("collection cap ignored");
        }
        panic("schema depth cap ignored");
    }
    panic("total schema byte cap ignored");
}

fn test_openapi_local_pointer_references_and_invalid_media_types() {
    let api = new_openapi("API", "1");
    api.schema("Fields", "{\"type\":\"object\",\"properties\":{\"odd/key~\":{\"type\":\"string\"},\"alias\":{\"$ref\":\"#/components/schemas/Fields/properties/odd~1key~0\"}}}");
    let valid = openapi_document([], new_registry(), api);
    guard let _valid = valid else let e = err_of(valid) { panic(e); }
    api.schema("Remote", "{\"$ref\":\"https://example.invalid/schema\"}");
    let op = api_operation(Method.GET, "/");
    let response = api_response(200, "string");
    response.media_type = "appli\"cation/json";
    push(op.responses, response);
    api.operation(op);
    let bad = openapi_document(["GET /"], new_registry(), api);
    guard let _bad = bad else let e = err_of(bad) {
        assert(strings.contains(e, "schemas.Remote.$ref") && strings.contains(e, ".media_type")); return;
    }
    panic("remote reference or malformed media type accepted");
}

fn test_openapi_combined_automatic_and_declared_parameters_obey_cap() {
    let reg = new_registry();
    reg.codes = {};
    let api = new_openapi("API", "1");
    api.limits.max_collection_entries = 1;
    let op = api_operation(Method.GET, "/:id");
    push(op.parameters, api_parameter("q", "query", "string"));
    api.operation(op);
    let made = openapi_document(["GET /:id"], reg, api);
    guard let _doc = made else let e = err_of(made) { assert(strings.contains(e, "combined parameters exceed max_collection_entries")); return; }
    panic("combined parameter cap ignored");
}
