// Checked redirects for variable destinations; redirect remains the raw constructor.
import "internal/location" as locationwire;
import "http";
import "strings";

pub gc struct RedirectRules {
    max_location_bytes: int,
    allow_external: bool,
}

// Relative references by default. Enable external destinations explicitly.
pub fn redirect_rules() -> RedirectRules {
    return RedirectRules { max_location_bytes: 8192, allow_external: false };
}

// Validate status and destination together without including destination secrets in errors.
pub fn redirect_checked(status: i32, location: str, rules: RedirectRules) -> result[http.Response, str] {
    let problems: [str] = [];
    if status != 301 && status != 302 && status != 303 && status != 307 && status != 308 {
        push(problems, "status must be 301, 302, 303, 307 or 308");
    }
    let checked = locationwire.check(location, rules.max_location_bytes, rules.allow_external);
    if let _valid = checked {} else let e = err_of(checked) { push(problems, e); }
    if len(problems) > 0 { return err("redirect: " + strings.join(problems, "; ")); }
    return ok(redirect(status, location));
}

// A checked 303 for the usual POST/redirect/GET flow, using relative references.
pub fn redirect_to(location: str) -> result[http.Response, str] {
    return redirect_checked(303, location, redirect_rules());
}
