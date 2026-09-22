// Building a request, and reading a response.
//
// Every test and every example was writing the same twelve lines to
// make an http.Request by hand, which is both tedious and the reason
// test fixtures drift from what a real client sends. This is the
// equivalent of MockMvc or supertest: build a request, hand it to the
// router, read what came back.
//
//     let resp = r.serve(zokor.request(zokor.Method.POST, "/orgs")
//         .bearer("token")
//         .json_body("{\"name\":\"acme\"}")
//         .build());
//
//     assert(zokor.resp_status(resp) == 201);
//     assert(zokor.resp_json(resp).get("id").str_or("") == "org_7");
//
// It is in the package rather than in a test file because an
// application's own tests need it too.

import "http";

pub gc struct TestRequest {
    method: Method,
    path: str,
    headers: map[str]str,
    body: bytes,
}

pub fn request(method: Method, path: str) -> TestRequest {
    let h: map[str]str = {};
    return TestRequest {
        method: method,
        path: path,
        headers: h,
        body: b""
    };
}

pub fn get_request(path: str) -> TestRequest {
    return request(Method.GET, path);
}

impl TestRequest {
    pub fn header(self: TestRequest, name: str, value: str) -> TestRequest {
        self.headers[lower_name(name)] = value;
        return self;
    }

    pub fn bearer(self: TestRequest, token: str) -> TestRequest {
        return self.header("authorization", "Bearer " + token);
    }

    pub fn basic(self: TestRequest, credentials: str) -> TestRequest {
        return self.header("authorization", "Basic " + credentials);
    }

    pub fn content_type(self: TestRequest, ct: str) -> TestRequest {
        return self.header("content-type", ct);
    }

    pub fn body_str(self: TestRequest, body: str) -> TestRequest {
        self.body = to_bytes(body);
        return self;
    }

    pub fn body_bytes(self: TestRequest, body: bytes) -> TestRequest {
        self.body = body;
        return self;
    }

    // Sets the content type too, because a body without one is a body
    // a real client would not send.
    pub fn json_body(self: TestRequest, body: str) -> TestRequest {
        self.body = to_bytes(body);
        return self.content_type("application/json");
    }

    pub fn json(self: TestRequest, body: Json) -> TestRequest {
        return self.json_body(body.render());
    }

    // A multipart body, built from the parts given: each file is
    // `name:filename:content-type:content`, each field `name:value`.
    pub fn multipart(self: TestRequest, boundary: str, fields: map[str]str,
                     files: [Upload]) -> TestRequest {
        let out = "";
        for k, v in fields {
            out = out + "--" + boundary + "\r\n" +
                  "Content-Disposition: form-data; name=\"" + k + "\"\r\n\r\n" +
                  v + "\r\n";
        }
        let i = 0;
        while i < len(files) {
            let f = files[i];
            out = out + "--" + boundary + "\r\n" +
                  "Content-Disposition: form-data; name=\"" + f.field +
                  "\"; filename=\"" + f.raw_filename + "\"\r\n";
            if len(f.content_type) > 0 {
                out = out + "Content-Type: " + f.content_type + "\r\n";
            }
            out = out + "\r\n" + to_str(f.data) + "\r\n";
            i = i + 1;
        }
        out = out + "--" + boundary + "--\r\n";
        self.body = to_bytes(out);
        return self.content_type("multipart/form-data; boundary=" + boundary);
    }

    pub fn build(self: TestRequest) -> http.Request {
        return http.Request {
            method: to_str(self.method),
            path: self.path,
            version: "HTTP/1.1",
            headers: self.headers,
            body: self.body
        };
    }
}

// One part for `multipart`, without going near a real encoder.
pub fn upload_part(field: str, filename: str, content_type: str,
                   content: str) -> Upload {
    return Upload {
        field: field,
        filename: safe_filename(filename),
        raw_filename: filename,
        content_type: content_type,
        data: to_bytes(content)
    };
}

// ---------------------------------------------------------------- //
// Reading a response                                                 //
// ---------------------------------------------------------------- //

// `status_of` is taken by the registry, so responses read as
// `resp_status`, `resp_text`, `resp_header`, `resp_json`.
pub fn resp_status(r: http.Response) -> int {
    return r.status as int;
}

pub fn resp_text(r: http.Response) -> str {
    return to_str(r.body);
}

pub fn resp_header(r: http.Response, name: str) -> str {
    let k = lower_name(name);
    if has(r.headers, k) {
        return r.headers[k];
    }
    return "";
}

// The body as JSON, or Null when it is not JSON at all -- so an
// assertion reads `json_of(resp).get("id")` without a guard.
pub fn resp_json(r: http.Response) -> Json {
    let p = parse(to_str(r.body));
    guard let j = p else {
        return jnull();
    }
    return j;
}

// The error code in zokor's envelope: "not_found", "validation_failed".
// "" when the body is not one.
pub fn resp_error_code(r: http.Response) -> str {
    return resp_json(r).path("error.code").str_or("");
}

// The field names an error envelope complains about, in order, so a
// test asserts on the shape rather than on an exact string.
pub fn resp_error_fields(r: http.Response) -> [str] {
    let out: [str] = [];
    let fields = resp_json(r).path("error.fields");
    let items = fields.items_of();
    let i = 0;
    while i < len(items) {
        push(out, items[i].get("field").str_or(""));
        i = i + 1;
    }
    return out;
}

fn lower_name(s: str) -> str {
    let b = to_bytes(s);
    let i = 0;
    while i < len(b) {
        if b[i] >= 65 && b[i] <= 90 {
            b[i] = b[i] + 32;
        }
        i = i + 1;
    }
    return to_str(b);
}
