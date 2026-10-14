// Startup OpenAPI generation from registered routes and explicit wire schemas.
import "internal/openapi" as apiwire;

// Resource limits for startup metadata and the generated document.
pub gc struct OpenApiLimits {
    max_routes: int,
    max_schemas: int,
    max_schema_bytes: int,
    max_total_schema_bytes: int,
    max_schema_depth: int,
    max_document_bytes: int,
    max_collection_entries: int,
    max_metadata_bytes: int,
}

pub fn openapi_limits() -> OpenApiLimits {
    return OpenApiLimits { max_routes: 1000, max_schemas: 1000,
        max_schema_bytes: 1048576, max_total_schema_bytes: 16777216,
        max_schema_depth: 32, max_document_bytes: 16777216,
        max_collection_entries: 1000, max_metadata_bytes: 16777216 };
}

// schema is a registered DTO name or a primitive JSON Schema type.
pub gc struct ApiParameter {
    name: str, location: str, schema: str, required: bool, description: str,
}

// An empty schema declares a response without a body.
pub gc struct ApiResponse {
    status: i32, description: str, schema: str, media_type: str,
}

// Metadata cannot create routes: method/pattern must occur in routes_list.
pub gc struct ApiOperation {
    method: Method, pattern: str, operation_id: str, summary: str,
    description: str, tags: [str], parameters: [ApiParameter],
    request_schema: str, request_media_type: str, request_required: bool,
    responses: [ApiResponse], errors: [str],
}

// Configure before generation. Schemas describe JSON wire fields, not slang fields.
pub gc struct OpenApi {
    title: str, version: str, description: str, server_urls: [str],
    schemas: map[str]str, operations: [ApiOperation], omitted: [str],
    error_schema: str, error_media_type: str, limits: OpenApiLimits,
}

pub fn new_openapi(title: str, version: str) -> OpenApi {
    let schemas: map[str]str = {};
    return OpenApi { title: title, version: version, description: "", server_urls: [],
        schemas: schemas, operations: [], omitted: [], error_schema: "",
        error_media_type: "application/json", limits: openapi_limits() };
}

pub fn api_operation(method: Method, pattern: str) -> ApiOperation {
    return ApiOperation { method: method, pattern: pattern, operation_id: "",
        summary: "", description: "", tags: [], parameters: [], request_schema: "",
        request_media_type: "application/json", request_required: true,
        responses: [], errors: [] };
}

pub fn api_parameter(name: str, location: str, schema: str) -> ApiParameter {
    return ApiParameter { name: name, location: location, schema: schema,
        required: location == "path", description: "" };
}

pub fn api_response(status: i32, schema: str) -> ApiResponse {
    return ApiResponse { status: status, description: status_text(status),
        schema: schema, media_type: "application/json" };
}

impl OpenApi {
    // A JSON Schema definition, parsed within limits at generation. Replaces a name.
    pub fn schema(self: OpenApi, name: str, definition: str) -> int {
        self.schemas[name] = definition;
        return len(self.schemas);
    }
    pub fn operation(self: OpenApi, op: ApiOperation) -> int {
        push(self.operations, op);
        return len(self.operations);
    }
    // Explicitly exclude an unsupported or private route from this document.
    pub fn omit(self: OpenApi, method: Method, pattern: str) -> int {
        push(self.omitted, to_str(method) + " " + pattern);
        return len(self.omitted);
    }
}

fn api_primitive(name: str) -> bool {
    return name == "string" || name == "integer" || name == "number" ||
        name == "boolean" || name == "object" || name == "array" || name == "null";
}

// Embed this definition when the application's renderer uses the default envelope.
pub fn api_default_error_schema() -> str {
    let string_ = jobj().set_str("type", "string");
    let field = jobj().set_str("type", "object").set("properties",
        jobj().set("field", string_).set("reason", string_))
        .set("required", jarr().add_str("field").add_str("reason"));
    let error_ = jobj().set_str("type", "object").set("properties", jobj()
        .set("code", string_).set("message", string_)
        .set("status", jobj().set_str("type", "integer"))
        .set("request_id", string_).set("trace_id", string_)
        .set("fields", jobj().set_str("type", "array").set("items", field)))
        .set("required", jarr().add_str("code").add_str("message").add_str("status"));
    return jobj().set_str("type", "object").set("properties", jobj().set("error", error_))
        .set("required", jarr().add_str("error")).render();
}

// A self-contained reference, or an inline primitive schema.
pub fn api_ref(name: str) -> str {
    if api_primitive(name) { return jobj().set_str("type", name).render(); }
    return jobj().set_str("$ref", "#/components/schemas/" + name).render();
}

fn api_problem(problems: [str], field: str, why: str) { push(problems, field + ": " + why); }

fn api_reference(name: str, schemas: map[str]Json, field: str, problems: [str]) -> Json {
    if api_primitive(name) { return jobj().set_str("type", name); }
    if !has(schemas, name) { api_problem(problems, field, "unknown schema '" + name + "'; register its wire definition"); }
    return jobj().set_str("$ref", "#/components/schemas/" + name);
}

fn api_media(value: str, field: str, problems: [str]) {
    let slash = strings.find(value, "/");
    if slash < 1 || slash == len(value) - 1 {
        api_problem(problems, field, "use a concrete media type such as application/json"); return;
    }
    for c in to_bytes(value) {
        if c != 47 && !((c >= 65 && c <= 90) || (c >= 97 && c <= 122) ||
            (c >= 48 && c <= 57) || c == 33 || c == 35 || c == 36 || c == 37 ||
            c == 38 || c == 39 || c == 43 || c == 45 || c == 46 || c == 94 ||
            c == 95 || c == 96 || c == 124 || c == 126) {
            api_problem(problems, field, "use a concrete media type without whitespace or parameters"); return;
        }
    }
    if strings.find(strings.slice(value, slash + 1, len(value)), "/") >= 0 {
        api_problem(problems, field, "media type has more than one /");
    }
}

fn api_content(schema: str, media: str, schemas: map[str]Json, field: str, problems: [str]) -> Json {
    api_media(media, field + ".media_type", problems);
    return jobj().set(media, jobj().set("schema", api_reference(schema, schemas, field + ".schema", problems)));
}

// References stay inside this document; resolving a reference never follows it
// recursively, so a recursive DTO is valid without recursive expansion.
fn api_schema_target(ref_: str, schemas: map[str]Json) -> bool {
    let prefix = "#/components/schemas/";
    if !strings.has_prefix(ref_, prefix) { return false; }
    let parts = strings.split(strings.slice(ref_, len(prefix), len(ref_)), "/");
    if len(parts) == 0 || !has(schemas, parts[0]) { return false; }
    let node = schemas[parts[0]];
    let i = 1;
    while i < len(parts) {
        let part = parts[i];
        let at = 0;
        let bytes_ = to_bytes(part);
        while at < len(bytes_) {
            if bytes_[at] == 126 {
                if at + 1 >= len(bytes_) || (bytes_[at + 1] != 48 && bytes_[at + 1] != 49) { return false; }
                at += 1;
            }
            at += 1;
        }
        part = strings.replace(strings.replace(part, "~1", "/"), "~0", "~");
        if node.kind == JsonKind.Object && node.has_key(part) { node = node.get(part); }
        else if node.kind == JsonKind.Array {
            let idx = to_int(part) ?? -1;
            if idx < 0 || idx >= node.size() || to_str(idx) != part { return false; }
            node = node.at(idx);
        } else { return false; }
        i += 1;
    }
    return node.kind == JsonKind.Object || node.kind == JsonKind.Bool;
}

fn api_schema_strings(value: Json, field: str, problems: [str]) {
    if value.kind != JsonKind.Array { api_problem(problems, field, "must be an array of unique strings"); return; }
    let seen: map[str]bool = {};
    for member in value.items {
        if member.kind != JsonKind.String { api_problem(problems, field, "must contain only strings"); continue; }
        if has(seen, member.text) { api_problem(problems, field, "contains a duplicate name"); }
        seen[member.text] = true;
    }
}

// Check schema structure and local references; unknown vocabulary is preserved.
// Full JSON Schema dialect validation belongs in the service's contract checks.
fn api_check_schema(value: Json, schemas: map[str]Json, field: str,
                    depth: int, cap: int, problems: [str]) {
    if depth > cap { api_problem(problems, field, "exceeds max_schema_depth"); return; }
    if value.kind == JsonKind.Bool { return; }
    if value.kind != JsonKind.Object { api_problem(problems, field, "a schema must be an object or boolean"); return; }
    let member_index = 0;
    for member in value.keys {
        let v = value.values[member_index];
        member_index += 1;
        let label = field + "." + member;
        if member == "$ref" {
            if v.kind != JsonKind.String || !api_schema_target(v.text, schemas) {
                api_problem(problems, label, "use an existing #/components/schemas/ reference");
            }
        } else if member == "$id" || member == "$dynamicRef" || member == "$dynamicAnchor" {
            api_problem(problems, label, "use self-contained component references without a changed base URI or dynamic scope");
        } else if member == "type" {
            if v.kind == JsonKind.String {
                if !api_primitive(v.text) { api_problem(problems, label, "unknown JSON Schema type"); }
            } else if v.kind == JsonKind.Array && v.size() > 0 {
                api_schema_strings(v, label, problems);
                for type_ in v.items { if type_.kind != JsonKind.String || !api_primitive(type_.text) { api_problem(problems, label, "unknown JSON Schema type"); } }
            } else { api_problem(problems, label, "must be a JSON Schema type or nonempty array of types"); }
        } else if member == "properties" || member == "patternProperties" || member == "$defs" || member == "definitions" || member == "dependentSchemas" {
            if v.kind != JsonKind.Object { api_problem(problems, label, "must be an object of schemas"); continue; }
            let i = 0;
            while i < len(v.keys) { api_check_schema(v.values[i], schemas, label + "." + v.keys[i], depth + 1, cap, problems); i += 1; }
        } else if member == "allOf" || member == "anyOf" || member == "oneOf" || member == "prefixItems" {
            if v.kind != JsonKind.Array || v.size() == 0 { api_problem(problems, label, "must be a nonempty array of schemas"); continue; }
            let i = 0;
            for child in v.items { api_check_schema(child, schemas, label + "[" + to_str(i) + "]", depth + 1, cap, problems); i += 1; }
        } else if member == "items" || member == "contains" || member == "additionalProperties" || member == "unevaluatedProperties" || member == "unevaluatedItems" || member == "propertyNames" || member == "not" || member == "if" || member == "then" || member == "else" || member == "contentSchema" {
            api_check_schema(v, schemas, label, depth + 1, cap, problems);
        } else if member == "required" { api_schema_strings(v, label, problems); }
        else if member == "enum" {
            if v.kind != JsonKind.Array || v.size() == 0 { api_problem(problems, label, "must be a nonempty array"); }
        } else if member == "readOnly" || member == "writeOnly" || member == "deprecated" || member == "uniqueItems" {
            if v.kind != JsonKind.Bool { api_problem(problems, label, "must be a boolean"); }
        } else if member == "format" || member == "title" || member == "description" || member == "pattern" || member == "contentEncoding" || member == "contentMediaType" || member == "$schema" || member == "$anchor" || member == "$comment" {
            if v.kind != JsonKind.String { api_problem(problems, label, "must be a string"); }
        } else if member == "minimum" || member == "maximum" || member == "exclusiveMinimum" || member == "exclusiveMaximum" || member == "multipleOf" {
            if v.kind != JsonKind.Number { api_problem(problems, label, "must be a number"); }
        } else if member == "minLength" || member == "maxLength" || member == "minItems" || member == "maxItems" || member == "minProperties" || member == "maxProperties" || member == "minContains" || member == "maxContains" {
            if v.kind != JsonKind.Number || (to_int(v.raw) ?? -1) < 0 { api_problem(problems, label, "must be a nonnegative integer"); }
        }
    }
}

fn api_has(names: [str], name: str) -> bool {
    for value in names { if value == name { return true; } }
    return false;
}

fn api_parameters(op: ApiOperation, route_: apiwire.Route, schemas: map[str]Json, field: str, cap: int, problems: [str]) -> Json {
    let params = jobj();
    for name in route_.names {
        params.set("path " + name, jobj().set_str("name", name).set_str("in", "path")
            .set_bool("required", true).set("schema", jobj().set_str("type", "string")));
    }
    let seen: map[str]bool = {};
    let i = 0;
    for p in op.parameters {
        let label = field + ".parameters[" + to_str(i) + "]";
        if len(p.name) == 0 { api_problem(problems, label + ".name", "must not be empty"); }
        if p.location != "path" && p.location != "query" && p.location != "header" && p.location != "cookie" { api_problem(problems, label + ".location", "must be path, query, header or cookie"); }
        if p.location == "path" && (!api_has(route_.names, p.name) || !p.required) { api_problem(problems, label, "path parameters must name a route parameter and be required"); }
        let key = p.location + " " + p.name;
        if p.location == "header" {
            let lower = strings.to_lower(p.name);
            key = p.location + " " + lower;
            if lower == "accept" || lower == "content-type" || lower == "authorization" { api_problem(problems, label + ".name", "OpenAPI ignores this header parameter; use content metadata or a security scheme"); }
        }
        if has(seen, key) { api_problem(problems, label, "duplicate parameter name/location"); }
        seen[key] = true;
        let param = jobj().set_str("name", p.name).set_str("in", p.location).set_bool("required", p.required)
            .set("schema", api_reference(p.schema, schemas, label + ".schema", problems));
        if len(p.description) > 0 { param.set_str("description", p.description); }
        params.set(key, param);
        i += 1;
    }
    if params.size() > cap { api_problem(problems, field + ".parameters", "combined parameters exceed max_collection_entries"); }
    let out = jarr();
    for value in params.values { out.add(value); }
    return out;
}

fn api_responses(op: ApiOperation, reg: Registry, api: OpenApi, schemas: map[str]Json, field: str, problems: [str]) -> Json {
    let out = jobj();
    let i = 0;
    for response in op.responses {
        let label = field + ".responses[" + to_str(i) + "]";
        let key = to_str(response.status);
        if response.status < 100 || response.status > 599 { api_problem(problems, label + ".status", "must be 100..599"); }
        if out.has_key(key) { api_problem(problems, label, "duplicate response status"); }
        if len(response.description) == 0 { api_problem(problems, label + ".description", "must not be empty"); }
        let item = jobj().set_str("description", response.description);
        if len(response.schema) > 0 {
            if response.status < 200 || response.status == 204 || response.status == 304 { api_problem(problems, label + ".schema", "this status cannot carry a body"); }
            item.set("content", api_content(response.schema, response.media_type, schemas, label, problems));
        }
        out.set(key, item);
        i += 1;
    }
    let seen: map[str]bool = {};
    let error_statuses: map[str]Json = {};
    for code in op.errors {
        let label = field + ".errors." + code;
        if has(seen, code) { api_problem(problems, label, "duplicate error code"); }
        seen[code] = true;
        if !has(reg.codes, code) { api_problem(problems, label, "register this error code first"); continue; }
        let c = reg.codes[code];
        let key = to_str(c.status);
        if out.has_key(key) { api_problem(problems, label, "status already has an explicit response; describe both cases in that response's schema"); continue; }
        if !has(error_statuses, key) { error_statuses[key] = jarr(); }
        error_statuses[key].add(jobj().set_str("code", code).set_str("message", c.message));
    }
    let statuses: [str] = [];
    for key, _v in error_statuses { push(statuses, key); }
    for key in apiwire.ordered(statuses) {
        let response = jobj().set_str("description", "Registered errors")
            .set("x-zokor-error-codes", error_statuses[key]);
        if len(api.error_schema) > 0 { response.set("content", api_content(api.error_schema, api.error_media_type, schemas, field + ".errors", problems)); }
        out.set(key, response);
    }
    if out.size() == 0 { out.set("default", jobj().set_str("description", "Response metadata not declared")); }
    return out;
}

// Charge source strings before constructing Json nodes or long diagnostics.
gc struct ApiByteBudget { used: int, cap: int }

fn api_charge(budget: ApiByteBudget, value: str, field: str, problems: [str]) {
    if len(value) > budget.cap - budget.used { api_problem(problems, field, "exceeds max_metadata_bytes"); return; }
    budget.used += len(value);
}

fn api_metadata_budget(routes: [str], reg: Registry, api: OpenApi, problems: [str]) {
    let budget = ApiByteBudget { used: 0, cap: api.limits.max_metadata_bytes };
    api_charge(budget, api.title, "title", problems);
    api_charge(budget, api.version, "version", problems);
    api_charge(budget, api.description, "description", problems);
    api_charge(budget, api.error_schema, "error_schema", problems);
    api_charge(budget, api.error_media_type, "error_media_type", problems);
    for line in routes { api_charge(budget, line, "routes", problems); }
    for line in api.omitted { api_charge(budget, line, "omitted", problems); }
    for url in api.server_urls { api_charge(budget, url, "server_urls", problems); }
    for name, definition in api.schemas { api_charge(budget, name, "schemas.name", problems); api_charge(budget, definition, "schemas.definition", problems); }
    for name, c in reg.codes { api_charge(budget, name, "error_codes.name", problems); api_charge(budget, c.message, "error_codes.message", problems); }
    let i = 0;
    for op in api.operations {
        let field = "operations[" + to_str(i) + "]";
        for value in [op.pattern, op.operation_id, op.summary, op.description, op.request_schema, op.request_media_type] { api_charge(budget, value, field, problems); }
        for value in op.tags { api_charge(budget, value, field + ".tags", problems); }
        for value in op.errors { api_charge(budget, value, field + ".errors", problems); }
        for p in op.parameters { for value in [p.name, p.location, p.schema, p.description] { api_charge(budget, value, field + ".parameters", problems); } }
        for response in op.responses { for value in [response.description, response.schema, response.media_type] { api_charge(budget, value, field + ".responses", problems); } }
        i += 1;
    }
}

// Generate at startup; returns every detected metadata problem together.
// Output contains only registered routes, explicit DTOs and registered error codes.
pub fn openapi_document(routes: [str], reg: Registry, api: OpenApi) -> result[str, str] {
    let problems: [str] = [];
    let limits = api.limits;
    if len(strings.trim(api.title)) == 0 { api_problem(problems, "title", "must not be empty"); }
    if len(strings.trim(api.version)) == 0 { api_problem(problems, "version", "must not be empty"); }
    let identity_problems = len(problems);
    if limits.max_routes < 1 { api_problem(problems, "limits.max_routes", "must be positive"); }
    if limits.max_schemas < 1 { api_problem(problems, "limits.max_schemas", "must be positive"); }
    if limits.max_schema_bytes < 1 { api_problem(problems, "limits.max_schema_bytes", "must be positive"); }
    if limits.max_total_schema_bytes < 1 { api_problem(problems, "limits.max_total_schema_bytes", "must be positive"); }
    if limits.max_schema_depth < 1 || limits.max_schema_depth > 64 { api_problem(problems, "limits.max_schema_depth", "must be 1..64 (the JSON parser's depth limit)"); }
    if limits.max_document_bytes < 1 { api_problem(problems, "limits.max_document_bytes", "must be positive"); }
    if limits.max_collection_entries < 1 { api_problem(problems, "limits.max_collection_entries", "must be positive"); }
    if limits.max_metadata_bytes < 1 { api_problem(problems, "limits.max_metadata_bytes", "must be positive"); }
    if len(problems) > identity_problems { return err("OpenAPI: " + strings.join(problems, "; ")); }
    let before_caps = len(problems);
    if len(routes) > limits.max_routes || len(api.operations) > limits.max_routes || len(api.omitted) > limits.max_routes { api_problem(problems, "routes", "exceeds max_routes"); }
    if len(api.schemas) > limits.max_schemas { api_problem(problems, "schemas", "exceeds max_schemas"); }
    if len(reg.codes) > limits.max_collection_entries { api_problem(problems, "error_codes", "exceeds max_collection_entries"); }
    if len(api.server_urls) > limits.max_collection_entries { api_problem(problems, "server_urls", "exceeds max_collection_entries"); }
    let operation_index = 0;
    for op in api.operations {
        let field = "operations[" + to_str(operation_index) + "]";
        if len(op.parameters) > limits.max_collection_entries { api_problem(problems, field + ".parameters", "exceeds max_collection_entries"); }
        if len(op.responses) > limits.max_collection_entries { api_problem(problems, field + ".responses", "exceeds max_collection_entries"); }
        if len(op.errors) > limits.max_collection_entries { api_problem(problems, field + ".errors", "exceeds max_collection_entries"); }
        if len(op.tags) > limits.max_collection_entries { api_problem(problems, field + ".tags", "exceeds max_collection_entries"); }
        operation_index += 1;
    }
    if len(problems) > before_caps { return err("OpenAPI: " + strings.join(problems, "; ")); }
    let before_budget = len(problems);
    api_metadata_budget(routes, reg, api, problems);
    if len(problems) > before_budget { return err("OpenAPI: " + strings.join(problems, "; ")); }
    let schemas: map[str]Json = {};
    let schema_names: [str] = [];
    let total = 0;
    for name, definition in api.schemas { push(schema_names, name); }
    schema_names = apiwire.ordered(schema_names);
    for name in schema_names {
        let field = "schemas." + name;
        if !apiwire.name_ok(name) || api_primitive(name) { api_problem(problems, field, "use a nonempty component name with letters, digits, _, - or .; primitive names are reserved"); }
        let definition = api.schemas[name];
        if len(definition) > limits.max_schema_bytes { api_problem(problems, field, "exceeds max_schema_bytes"); continue; }
        if len(definition) > limits.max_total_schema_bytes - total { api_problem(problems, field, "exceeds max_total_schema_bytes"); continue; }
        total += len(definition);
        let parsed = parse(definition);
        guard let schema = parsed else let e = err_of(parsed) { api_problem(problems, field, e); continue; }
        schemas[name] = schema;
    }
    for name in schema_names {
        if has(schemas, name) { api_check_schema(schemas[name], schemas, "schemas." + name, 0, limits.max_schema_depth, problems); }
    }
    if len(api.error_schema) > 0 { api_reference(api.error_schema, schemas, "error_schema", problems); api_media(api.error_media_type, "error_media_type", problems); }
    let registered: map[str]bool = {};
    for line in routes { registered[line] = true; }
    let omitted: map[str]bool = {};
    for line in api.omitted {
        if !has(registered, line) { api_problem(problems, "omitted." + line, "not a registered route"); }
        if has(omitted, line) { api_problem(problems, "omitted." + line, "duplicate omission"); }
        omitted[line] = true;
    }
    let operations: map[str]ApiOperation = {};
    let operation_ids: map[str]bool = {};
    for op in api.operations {
        let key = to_str(op.method) + " " + op.pattern;
        if !has(registered, key) || has(omitted, key) { api_problem(problems, "operations." + key, "must name a registered, included route"); }
        if has(operations, key) { api_problem(problems, "operations." + key, "duplicate operation metadata"); }
        if len(op.operation_id) > 0 {
            if has(operation_ids, op.operation_id) { api_problem(problems, "operations." + key + ".operation_id", "must be unique"); }
            operation_ids[op.operation_id] = true;
        }
        operations[key] = op;
    }
    let paths = jobj();
    let shapes: map[str]str = {};
    let included: map[str]bool = {};
    for line in routes {
        if has(omitted, line) || has(included, line) { continue; }
        included[line] = true;
        let parsed = apiwire.route(line, limits.max_collection_entries);
        guard let route_ = parsed else let e = err_of(parsed) { api_problem(problems, "routes." + line, e); continue; }
        if has(shapes, route_.shape) && shapes[route_.shape] != route_.template { api_problem(problems, "routes." + line, "same template hierarchy has different parameter names; use one set of names or omit a route"); }
        shapes[route_.shape] = route_.template;
        let path_item = paths.get(route_.template);
        if path_item.kind != JsonKind.Object { path_item = jobj(); paths.set(route_.template, path_item); }
        if path_item.has_key(route_.method) { api_problem(problems, "routes." + line, "duplicate operation after path normalization"); continue; }
        let op = api_operation(Method.GET, route_.pattern);
        if has(operations, line) { op = operations[line]; }
        let field = "operations." + line;
        let item = jobj().set_str("x-zokor-route-pattern", route_.pattern);
        if len(op.operation_id) > 0 { item.set_str("operationId", op.operation_id); }
        if len(op.summary) > 0 { item.set_str("summary", op.summary); }
        if len(op.description) > 0 { item.set_str("description", op.description); }
        if len(op.tags) > 0 { let tags = jarr(); for tag in op.tags { tags.add_str(tag); } item.set("tags", tags); }
        let params = api_parameters(op, route_, schemas, field, limits.max_collection_entries, problems);
        if params.size() > 0 { item.set("parameters", params); }
        if len(op.request_schema) > 0 {
            item.set("requestBody", jobj().set_bool("required", op.request_required)
                .set("content", api_content(op.request_schema, op.request_media_type, schemas, field + ".request", problems)));
        }
        item.set("responses", api_responses(op, reg, api, schemas, field, problems));
        path_item.set(route_.method, item);
    }
    let codes = jobj();
    let code_names: [str] = [];
    for name, _c in reg.codes { push(code_names, name); }
    for name in apiwire.ordered(code_names) {
        let c = reg.codes[name];
        if c.status < 100 || c.status > 599 { api_problem(problems, "error_codes." + name + ".status", "must be 100..599"); }
        codes.set(name, jobj().set_int("status", c.status as int).set_str("message", c.message));
    }
    let info = jobj().set_str("title", api.title).set_str("version", api.version);
    if len(api.description) > 0 { info.set_str("description", api.description); }
    let components = jobj();
    let schema_map = jobj();
    for name in schema_names { if has(schemas, name) { schema_map.set(name, schemas[name]); } }
    components.set("schemas", schema_map);
    let doc = jobj().set_str("openapi", "3.1.1").set("info", info)
        .set("paths", paths).set("components", components).set("x-zokor-error-codes", codes);
    if len(api.server_urls) > 0 {
        let servers = jarr();
        for url in api.server_urls {
            if len(strings.trim(url)) == 0 { api_problem(problems, "server_urls", "must not contain an empty URL"); }
            servers.add(jobj().set_str("url", url));
        }
        doc.set("servers", servers);
    }
    if len(problems) > 0 { return err("OpenAPI: " + strings.join(problems, "; ")); }
    let rendered = doc.render();
    if len(rendered) > limits.max_document_bytes { return err("OpenAPI: document exceeds max_document_bytes"); }
    return ok(rendered);
}
