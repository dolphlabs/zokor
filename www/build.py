#!/usr/bin/env python3
"""Build the Zokor documentation site from the repository's own sources.

README sections supply the guide, docs/api.txt supplies the signatures
generated from zokor/, and examples/ supplies the runnable programs. The
build uses only Python's standard library and writes the static site into
docs/ without removing the API and agent-guide files already there.

Usage: python3 www/build.py [--out docs] [--check]
"""

import argparse
import html
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
WWW = ROOT / "www"
DEFAULT_OUT = ROOT / "docs"
SITE_URL = "https://zokor.dolphlabs.com/"
GITHUB_SOURCE = "https://github.com/dolphlabs/zokor/blob/dev/"

GUIDE_PAGES = [
    {
        "path": "guide/start.html",
        "title": "Start here",
        "seo_title": "Getting Started with Zokor | Slang Backend Framework",
        "description": (
            "Create a Slang backend service with Zokor. Follow the setup guide for "
            "installation, project structure, requirements, and your first routes."),
        "nav": "Start",
        "sections": ["Starting a service", "Install", "Requirements"],
    },
    {
        "path": "guide/http.html",
        "title": "HTTP APIs",
        "seo_title": "Zokor HTTP APIs | Routing, Middleware & Security",
        "description": (
            "Build HTTP APIs with Zokor routing, middleware, authentication, validation, "
            "uploads, rate limits, caching, pagination, and content negotiation."),
        "nav": "HTTP",
        "sections": ["Authentication", "Operator injection (MongoDB)",
                     "Cookies", "Conditional requests", "Security headers",
                     "CORS", "Health and readiness", "Static files",
                     "Content negotiation and redirects", "Compression",
                     "Idempotency keys", "Pagination", "JSON", "Uploads",
                     "Rate limits and bearer tokens"],
    },
    {
        "path": "guide/data.html",
        "title": "Data and storage",
        "seo_title": "Zokor Data | PostgreSQL, Redis & Migrations",
        "description": (
            "Use PostgreSQL, Redis, and SQL migrations in Zokor, with typed row decoding, "
            "transactions, connection pools, and configuration guidance."),
        "nav": "Data",
        "sections": ["Postgres", "Redis", "Migrations"],
    },
    {
        "path": "guide/operations.html",
        "title": "Operations",
        "seo_title": "Zokor Operations | Configuration, Metrics & Deployment",
        "description": (
            "Configure and operate Zokor services with timeouts, graceful shutdown, "
            "HTTPS, logging, background jobs, metrics, tracing, and OpenAPI."),
        "nav": "Operations",
        "sections": ["Configuration", "Server timeouts, limits, and shutdown",
                     "HTTPS", "Logging", "Background jobs", "Errors",
                     "Metrics", "Tracing", "OpenAPI"],
    },
    {
        "path": "guide/realtime.html",
        "title": "Realtime connections",
        "seo_title": "Zokor WebSockets & Socket.IO | Realtime Guide",
        "description": (
            "Build WebSocket and Socket.IO services in Slang with Zokor's route "
            "integration and sans-I/O protocol handlers."),
        "nav": "Realtime",
        "sections": ["WebSocket"],
    },
    {
        "path": "guide/architecture.html",
        "title": "Project structure",
        "seo_title": "Zokor Architecture | Project Structure & Testing",
        "description": (
            "Explore Zokor's project structure, testing approach, dependency ports and "
            "fakes, agent guide, and framework design."),
        "nav": "Architecture",
        "sections": ["Testing", "Layout", "Tests",
                     "Dependencies: ports and fakes", "Agent guide", "Not yet",
                     "Contributing and licence"],
    },
]

PRIMARY_NAV = [
    {"path": "index.html", "title": "Home", "nav": "Home"},
    GUIDE_PAGES[0],
    {"path": "api/index.html", "title": "API reference", "nav": "API"},
    {"path": "examples/index.html", "title": "Examples", "nav": "Examples"},
]

EXAMPLE_PAGES = [
    {"name": "hello", "path": "examples/hello.html", "title": "Hello service",
     "seo_title": "Zokor Example: Hello HTTP Service",
     "description": (
         "A minimal Slang HTTP service built with Zokor. See how to configure the "
         "server, register a route, and return a JSON response."),
     "command": "make example", "files": ["examples/hello/main.sl"]},
    {"name": "chat", "path": "examples/chat.html", "title": "Chat service",
     "seo_title": "Zokor Example: WebSocket and Socket.IO Chat",
     "description": (
         "A Slang chat service using Zokor, with WebSocket and Socket.IO clients "
         "connected to the same room."),
     "command": "make example-chat", "files": ["examples/chat/main.sl"]},
    {"name": "ports", "path": "examples/ports.html", "title": "Ports and fakes",
     "seo_title": "Zokor Example: Ports and Fakes",
     "description": (
         "A runnable Slang example showing how to isolate dependencies behind ports "
         "and test Zokor services with fakes."),
     "command": "make example-ports", "files": []},
]

ASSETS = {
    "zokor-icon-64.png": ("image/png", (64, 64)),
    "zokor-header-256.png": ("image/png", (256, 256)),
    "zokor-card-1200x630.jpg": ("image/jpeg", (1200, 630)),
}

SLANG_KEYWORDS = {
    "let", "fn", "if", "else", "while", "return", "true", "false", "pub",
    "import", "guard", "for", "in", "as", "struct", "gc", "own", "mut",
    "impl", "extern", "link", "spawn", "break", "continue", "unsafe",
    "select", "switch", "case", "default",
}
SLANG_TYPES = {
    "int", "float", "str", "bool", "bytes", "i8", "i16", "i32", "i64",
    "u8", "u16", "u32", "u64", "f32", "map", "opt", "result", "duration",
    "rawptr", "arena", "chan", "join", "wire", "until", "fault", "peer",
    "trip", "mutex", "void", "ptr",
}
SLANG_BUILTINS = {
    "println", "print", "len", "push", "pop", "to_str", "inspect", "to_bytes",
    "some", "none", "ok", "err", "err_of", "exit", "make_chan",
    "chan_send", "chan_recv", "chan_close", "make_mutex", "mutex_lock",
    "mutex_unlock", "mutex_trylock", "join_wait", "spawn", "nullptr",
    "arena_new", "until_of", "until_never", "until_hit", "bytes_ptr",
    "to_le", "to_be", "from_le", "from_be", "has", "del",
}
TOKEN = re.compile(r"""
    (?P<comment>//[^\n]*)
  | (?P<string>"(?:\\.|[^"\\])*")
  | (?P<number>\b\d[\w.]*\b)
  | (?P<word>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>[{}()\[\];,.:=+\-*/%<>!&|^~?])
""", re.VERBOSE)


def read_markdown(path):
    return path.read_text(encoding="utf-8").splitlines()


def read_sections(lines):
    """Split Markdown at H2 headings, leaving each heading's H3s inside it."""
    headings = []
    fenced = False
    for index, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        match = re.match(r"^##\s+(.*?)\s*$", line)
        if match and not fenced:
            headings.append((index, match.group(1)))

    sections = {}
    for position, (start, title) in enumerate(headings):
        end = headings[position + 1][0] if position + 1 < len(headings) else len(lines)
        sections[title] = lines[start + 1:end]
    return sections


def read_preamble(lines):
    """Return README material before its first H2, excluding its HTML masthead."""
    preamble = []
    fenced = False
    html_block = False
    for line in lines:
        if line.lstrip().startswith("```"):
            fenced = not fenced
        if not fenced and re.match(r"^##\s+", line):
            break
        stripped = line.lstrip()
        if not html_block and stripped.startswith("<p"):
            html_block = "</p>" not in stripped
            continue
        if html_block:
            if "</p>" in line:
                html_block = False
            continue
        if stripped.startswith("<h1") or stripped.startswith("</h1"):
            continue
        preamble.append(line)
    return preamble


def brand_from_readme(lines):
    source = "\n".join(lines[:30])
    title = "zokor"
    title_match = re.search(r"<h1[^>]*>(.*?)</h1>", source, re.I | re.S)
    if title_match:
        title = html.unescape(re.sub(r"<[^>]+>", "", title_match.group(1))).strip()

    tagline = "A backend framework for slang."
    for match in re.finditer(r"<p[^>]*>(.*?)</p>", source, re.I | re.S):
        paragraph = html.unescape(re.sub(r"<[^>]+>", "", match.group(1)))
        paragraph = re.sub(r"\s+", " ", paragraph).strip()
        if "backend framework" in paragraph.lower():
            tagline = paragraph
            break
    return title, tagline


def slugify(text):
    text = re.sub(r"`", "", text).lower()
    return re.sub(r"[^a-z0-9]+", "-", text).strip("-") or "section"


def unique_id(text, used):
    base = slugify(text)
    value = base
    suffix = 2
    while value in used:
        value = "%s-%d" % (base, suffix)
        suffix += 1
    used.add(value)
    return value


def example_anchor(relative_path):
    return "source-" + slugify(relative_path)


def site_href(target, root):
    target = target.strip()
    parsed = urlsplit(target)
    if parsed.scheme or parsed.netloc:
        return target if parsed.scheme in ("http", "https", "mailto") else "#"
    if target.startswith("#"):
        return target

    path, marker, fragment = target.partition("#")
    path = path.removeprefix("./")
    known = {
        "README.md": "guide/start",
        "docs/api.txt": "api/",
        "docs/llms-small.txt": "llms-small.txt",
        "examples/hello/main.sl": "examples/hello#" +
            example_anchor("examples/hello/main.sl"),
        "examples/chat/main.sl": "examples/chat#" +
            example_anchor("examples/chat/main.sl"),
        "examples/ports/src/main.sl": "examples/ports#" +
            example_anchor("examples/ports/src/main.sl"),
    }
    if path in known:
        mapped = known[path]
        if marker and "#" not in mapped:
            mapped += "#" + fragment
        return root + mapped
    if not path:
        return "#" + fragment if marker else "#"
    if path.startswith("/"):
        return root + path.lstrip("/") + ("#" + fragment if marker else "")
    return GITHUB_SOURCE + path + ("#" + fragment if marker else "")


def inline(markdown, root, current_path):
    codes = []
    links = []

    def hold_code(match):
        codes.append(match.group(1))
        return "\x00C%d\x00" % (len(codes) - 1)

    def hold_link(match):
        label = inline(match.group(1), root, current_path)
        href = site_href(match.group(2), root)
        external = urlsplit(href).scheme in ("http", "https")
        rel = ' rel="noopener"' if external else ""
        links.append('<a href="%s"%s>%s</a>' % (
            html.escape(href, quote=True), rel, label))
        return "\x00L%d\x00" % (len(links) - 1)

    markdown = re.sub(r"`([^`]+)`", hold_code, markdown)
    markdown = re.sub(r"\[([^]]+)\]\(([^)]+)\)", hold_link, markdown)
    escaped = html.escape(markdown)
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    escaped = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", escaped)
    escaped = re.sub(r"\x00C(\d+)\x00", lambda m: "<code>%s</code>" %
                     html.escape(codes[int(m.group(1))]), escaped)
    escaped = re.sub(r"\x00L(\d+)\x00", lambda m: links[int(m.group(1))], escaped)
    return escaped


def highlight(code, language):
    if language not in ("slang", "sl", ""):
        return html.escape(code)
    out = []
    position = 0
    for match in TOKEN.finditer(code):
        out.append(html.escape(code[position:match.start()]))
        position = match.end()
        token = match.group(0)
        kind = match.lastgroup
        cls = None
        if kind == "comment":
            cls = "tok-comment"
        elif kind == "string":
            cls = "tok-string"
        elif kind == "number":
            cls = "tok-number"
        elif kind == "word":
            if token in SLANG_KEYWORDS:
                cls = "tok-keyword"
            elif token in SLANG_TYPES:
                cls = "tok-type"
            elif token in SLANG_BUILTINS:
                cls = "tok-builtin"
            elif code[match.end():match.end() + 1] == "(":
                cls = "tok-function"
        escaped = html.escape(token)
        out.append('<span class="%s">%s</span>' % (cls, escaped) if cls else escaped)
    out.append(html.escape(code[position:]))
    return "".join(out)


def code_block(code, language, label=""):
    classes = "language-" + re.sub(r"[^a-z0-9_-]", "", language.lower()) if language else ""
    caption = '<span class="code-label">%s</span>' % html.escape(label) if label else ""
    return (
        '<div class="code">'
        '<div class="code-head">%s<button class="copy" type="button" '
        'aria-label="Copy code">Copy</button></div>'
        '<pre><code class="%s">%s</code></pre></div>' %
        (caption, classes, highlight(code, language)))


LIST_MARKER = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")


def md_to_html(lines, root, current_path, ids=None):
    out = []
    ids = ids if ids is not None else set()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()

        if stripped.startswith("```"):
            indent = len(line) - len(stripped)
            language = stripped[3:].strip()
            body = []
            i += 1
            while i < len(lines) and not lines[i].lstrip().startswith("```"):
                body.append(lines[i][indent:] if lines[i].startswith(" " * indent)
                            else lines[i])
                i += 1
            i += 1
            out.append(code_block("\n".join(body), language))
            continue

        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            level = len(heading.group(1))
            title = heading.group(2).strip()
            anchor = unique_id(title, ids)
            out.append('<h%d id="%s">%s<a class="anchor" href="#%s" '
                       'aria-label="Link to this section">#</a></h%d>' %
                       (level, anchor, inline(title, root, current_path), anchor, level))
            i += 1
            continue

        if line.startswith("|") and i + 1 < len(lines) and re.match(
                r"^\|[\s:|-]+\|$", lines[i + 1]):
            headers = [cell.strip() for cell in line.strip("|").split("|")]
            i += 2
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append([cell.strip() for cell in lines[i].strip("|").split("|")])
                i += 1
            out.append('<div class="table-wrap"><table><thead><tr>%s</tr></thead>'
                       '<tbody>%s</tbody></table></div>' % (
                           "".join("<th>%s</th>" % inline(cell, root, current_path)
                                   for cell in headers),
                           "".join("<tr>%s</tr>" % "".join(
                               "<td>%s</td>" % inline(cell, root, current_path)
                               for cell in row) for row in rows)))
            continue

        marker = LIST_MARKER.match(line)
        if marker:
            base_indent = len(marker.group(1))
            ordered = marker.group(2).endswith(".")
            items = []
            while i < len(lines):
                current = LIST_MARKER.match(lines[i])
                if not current or len(current.group(1)) < base_indent:
                    break
                if len(current.group(1)) > base_indent:
                    break
                item_text = inline(current.group(3), root, current_path)
                i += 1
                nested = []
                while i < len(lines):
                    candidate = lines[i]
                    nested_marker = LIST_MARKER.match(candidate)
                    if candidate.strip() == "":
                        if (i + 1 < len(lines) and
                                ((LIST_MARKER.match(lines[i + 1]) and
                                  len(LIST_MARKER.match(lines[i + 1]).group(1)) > base_indent)
                                 or (lines[i + 1].startswith(" " * (base_indent + 2)) and
                                     lines[i + 1].strip()))):
                            nested.append("")
                            i += 1
                            continue
                        break
                    if nested_marker and len(nested_marker.group(1)) <= base_indent:
                        break
                    if len(candidate) - len(candidate.lstrip()) > base_indent:
                        nested.append(candidate[base_indent + 2:])
                        i += 1
                        continue
                    break
                nested_html = md_to_html(nested, root, current_path, ids) if nested else ""
                items.append("<li>%s%s</li>" % (item_text, nested_html))
                if i < len(lines) and lines[i].strip() == "":
                    following = i + 1
                    next_marker = LIST_MARKER.match(lines[following]) if following < len(lines) else None
                    if next_marker and len(next_marker.group(1)) == base_indent:
                        i += 1
                        continue
                    break
                if i >= len(lines) or not LIST_MARKER.match(lines[i]):
                    break
            tag = "ol" if ordered else "ul"
            out.append("<%s>%s</%s>" % (tag, "".join(items), tag))
            continue

        if stripped.startswith(">"):
            quote_lines = []
            while i < len(lines) and lines[i].lstrip().startswith(">"):
                quote_lines.append(lines[i].lstrip()[1:].lstrip())
                i += 1
            out.append("<blockquote>%s</blockquote>" %
                       md_to_html(quote_lines, root, current_path, ids))
            continue

        if stripped in ("---", "***", "___"):
            out.append("<hr>")
            i += 1
            continue

        if not stripped:
            i += 1
            continue

        paragraph = []
        while i < len(lines):
            candidate = lines[i]
            candidate_stripped = candidate.lstrip()
            if not candidate_stripped:
                break
            if (candidate_stripped.startswith(("```", "#", "|", ">")) or
                    LIST_MARKER.match(candidate)):
                break
            paragraph.append(candidate.strip())
            i += 1
        if paragraph:
            out.append("<p>%s</p>" % inline(" ".join(paragraph), root, current_path))
        else:
            i += 1
    return "\n".join(out)


def read_api(path):
    modules = []
    current_module = None
    current_item = None
    for line in read_markdown(path):
        if line.startswith("## "):
            filename, separator, description = line[3:].partition(" -- ")
            current_module = {"file": filename.strip(),
                              "description": description.strip() if separator else "",
                              "items": []}
            modules.append(current_module)
            current_item = None
        elif current_module and line.startswith("    ") and current_item:
            description = line.strip()
            if current_item["description"]:
                current_item["description"] += " " + description
            else:
                current_item["description"] = description
        elif current_module and line.strip() and not line.startswith("#"):
            current_item = {"signature": line.strip(), "description": ""}
            current_module["items"].append(current_item)
    if not modules:
        raise ValueError("docs/api.txt has no API modules; run make api first")
    return modules


def api_slug(module, signature, used):
    name = re.sub(r"\([^)]*", "", signature).split()[0]
    return unique_id(module + "-" + name, used)


def render_api(modules, root, current_path):
    ids = set()
    output = []
    search = []
    item_count = sum(len(module["items"]) for module in modules)
    output.append('<p>The public package surface contains %d entries across %d source files. '
                  'This page is generated from <code>docs/api.txt</code>, which is '
                  'generated from <code>zokor/</code>.</p>' % (item_count, len(modules)))
    for module in modules:
        module_id = unique_id(module["file"], ids)
        output.append('<section class="api-module"><h2 id="%s">%s'
                      '<a class="anchor" href="#%s" aria-label="Link to this section">#</a>'
                      '</h2>' % (module_id, inline(module["file"], root, current_path), module_id))
        if module["description"]:
            output.append('<p class="api-module-description">%s</p>' %
                          inline(module["description"], root, current_path))
        for item in module["items"]:
            item_id = api_slug(module["file"], item["signature"], ids)
            output.append('<div class="api-item" id="%s"><code>%s</code>%s</div>' % (
                item_id, html.escape(item["signature"]),
                '<p>%s</p>' % inline(item["description"], root, current_path)
                if item["description"] else ""))
            search.append({
                "title": item["signature"],
                "tagline": item["description"] or module["description"],
                "url": "api/#" + item_id,
                "text": module["file"] + " " + item["signature"] + " " + item["description"],
            })
        output.append("</section>")
    return "\n".join(output), search


def source_intro(path):
    lines = read_markdown(path)
    parts = []
    started = False
    for line in lines:
        if line.startswith("//"):
            started = True
            content = line[2:].strip()
            if not content and parts:
                break
            parts.append(content)
        elif not line.strip() and started:
            break
        else:
            break
    return " ".join(parts).strip()


def example_files(example):
    if example["files"]:
        return [ROOT / path for path in example["files"]]
    base = ROOT / "examples" / "ports" / "src"
    return sorted(path for path in base.rglob("*.sl")
                  if not path.name.endswith("_test.sl"))


def render_example(example, root, current_path):
    files = example_files(example)
    output = []
    markdown = ["# %s" % example["title"], ""]
    if example["name"] in ("hello", "chat"):
        description = source_intro(files[0])
        if description:
            output.append("<p class=\"example-intro\">%s</p>" %
                          inline(description, root, current_path))
            markdown.extend([description, ""])
    else:
        output.append('<p class="example-intro">The example is built from the '
                      'source files below, with tests beside each package.</p>')
        markdown.extend(["The example source files are shown below.", ""])
    output.append('<p class="run-command">Run it from the repository root: '
                  '<code>%s</code></p>' % html.escape(example["command"]))
    markdown.extend(["Run from the repository root: `%s`." % example["command"], ""])
    for source in files:
        relative = source.relative_to(ROOT).as_posix()
        code = source.read_text(encoding="utf-8").rstrip("\n")
        anchor = example_anchor(relative)
        output.append('<section class="example-file" id="%s"><h2>%s'
                      '<a class="anchor" href="#%s" aria-label="Link to this file">#</a>'
                      '</h2>%s</section>' % (
                          anchor, html.escape(relative), anchor,
                          code_block(code, "slang", relative)))
        markdown.extend(["## `%s`" % relative, "", "```slang", code, "```", ""])
    return "\n".join(output), "\n".join(markdown), files


def html_text(markup):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", markup))).strip()


def relative_root(path):
    return "../" * (len(Path(path).parts) - 1)


def public_path(path):
    path, marker, fragment = path.partition("#")
    path = Path(path).as_posix()
    if path == "index.html":
        path = ""
    elif path.endswith("/index.html"):
        path = path[:-len("index.html")]
    elif path.endswith(".html"):
        path = path[:-len(".html")]
    return path + ("#" + fragment if marker else "")


def canonical_url(path):
    path = public_path(path)
    return SITE_URL + path


def render_nav(current, root):
    links = []
    for page in PRIMARY_NAV:
        active = current == page["path"] or (
            page["path"] == "guide/start.html" and current.startswith("guide/"))
        links.append('<a href="%s%s"%s>%s</a>' % (
            root, public_path(page["path"]),
            ' class="active" aria-current="page"' if active else "",
            html.escape(page["nav"])))
    return "".join(links)


def render_guide_nav(current, root):
    if not current.startswith("guide/"):
        return ""
    return '<nav class="subnav" aria-label="Guide pages">%s</nav>' % "".join(
        '<a href="%s%s"%s>%s</a>' % (
            root, public_path(page["path"]),
            ' aria-current="page"' if page["path"] == current else "",
            html.escape(page["nav"])) for page in GUIDE_PAGES)


def page_html(template, *, title, tagline, body, path, seo_title=None,
              description=None, structured_data=None, hero="",
              show_page_head=True):
    root = relative_root(path) or "./"
    depth = len(Path(path).parts) - 1
    md_path = Path(path).with_suffix(".md").as_posix()
    seo_title = seo_title or "%s | Zokor" % title
    description = description or tagline
    canonical = canonical_url(path)
    extra_head = (
        '<meta property="og:image" content="%sassets/zokor-card-1200x630.jpg">'
        '<meta property="og:image:alt" content="Zokor, a backend framework for Slang">'
        '<meta property="og:image:width" content="1200">'
        '<meta property="og:image:height" content="630">'
        '<meta name="twitter:image" content="%sassets/zokor-card-1200x630.jpg">'
        '<meta name="twitter:image:alt" content="Zokor, a backend framework for Slang">'
    ) % (SITE_URL, SITE_URL)
    if structured_data:
        json_ld = json.dumps(structured_data, ensure_ascii=False, separators=(",", ":"))
        json_ld = json_ld.replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")
        extra_head += '<script type="application/ld+json">%s</script>' % json_ld
    page_head = ""
    if show_page_head:
        page_head = (
            '<header class="page-head"><p class="page-kicker">Zokor documentation</p>'
            '<h1>%s</h1><p class="tagline">%s</p>'
            '<p class="agentline"><a href="%s">Markdown</a> · '
            '<a href="%sllms.txt">llms.txt</a> · '
            '<a href="%sapi.json">api.json</a></p></header>' % (
                html.escape(title), html.escape(tagline), root + md_path, root, root))
    return (template.replace("{{SEO_TITLE}}", html.escape(seo_title))
            .replace("{{DESCRIPTION}}", html.escape(description))
            .replace("{{NAV}}", render_nav(path, root))
            .replace("{{SUBNAV}}", render_guide_nav(path, root))
            .replace("{{ROOT}}", root)
            .replace("{{CANONICAL_URL}}", html.escape(canonical, quote=True))
            .replace("{{MD_PATH}}", root + md_path)
            .replace("{{EXTRA_HEAD}}", extra_head)
            .replace("{{HERO}}", hero)
            .replace("{{PAGE_HEAD}}", page_head)
            .replace("{{BODY}}", body)
            .replace("{{DEPTH}}", str(depth)))


def markdown_twin(title, tagline, body):
    return "# %s\n\n> %s\n\n%s\n" % (title, tagline, body.strip())


def image_dimensions(data, name):
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24:
        return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    if data.startswith(b"\xff\xd8"):
        index = 2
        while index + 4 <= len(data):
            if data[index] != 0xFF:
                index += 1
                continue
            while index < len(data) and data[index] == 0xFF:
                index += 1
            if index >= len(data):
                break
            marker = data[index]
            index += 1
            if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
                continue
            if index + 2 > len(data):
                break
            length = int.from_bytes(data[index:index + 2], "big")
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                          0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                if index + 7 <= len(data):
                    height = int.from_bytes(data[index + 3:index + 5], "big")
                    width = int.from_bytes(data[index + 5:index + 7], "big")
                    return width, height
                break
            index += length
    raise ValueError("cannot read dimensions for %s" % name)


def build_files():
    readme_lines = read_markdown(ROOT / "README.md")
    sections = read_sections(readme_lines)
    mapped = {"What is in it"} | {
        name for page in GUIDE_PAGES for name in page["sections"]
    }
    missing = sorted(set(sections) - mapped)
    unknown = sorted(mapped - set(sections))
    if missing or unknown:
        raise ValueError("README page map differs (unmapped: %s; missing: %s)" %
                         (", ".join(missing) or "none", ", ".join(unknown) or "none"))

    template = (WWW / "theme" / "base.html").read_text(encoding="utf-8")
    title, tagline = brand_from_readme(readme_lines)
    files = {}
    pages = []
    search = []
    markdown_pages = []
    preamble = read_preamble(readme_lines)
    preamble_html = md_to_html(preamble, "./", "index.html")
    feature_html = md_to_html(sections["What is in it"], "./", "index.html")
    home_body = '<section class="readme-preamble">%s</section>' % preamble_html
    home_body += '<section class="readme-section"><h2 id="what-is-in-it">What is in it</h2>%s</section>' % feature_html
    home_hero = (
        '<section class="hero"><div class="hero-copy">'
        '<p class="eyebrow">Developer documentation</p>'
        '<h1>%s</h1><p class="hero-lede">%s</p>'
        '<div class="hero-actions"><a class="button primary" href="guide/start">'
        'Read the guide</a><a class="button" href="api/">Browse the API</a></div>'
        '<p class="agentline"><a href="index.md">Markdown</a> · '
        '<a href="llms.txt">llms.txt</a> · <a href="api.json">api.json</a></p>'
        '</div><img class="hero-art" src="assets/zokor-header-256.png" '
        'width="256" height="256" alt="Zokor, the illustrated burrowing rodent"></section>' %
        (html.escape(title), html.escape(tagline)))
    home_markdown = "\n\n".join(["\n".join(preamble).strip(),
                                    "## What is in it\n\n" +
                                    "\n".join(sections["What is in it"]).strip()])
    home_description = (
        "Zokor is a backend framework for Slang, with routing, middleware, "
        "configuration, validation, database helpers, background jobs, and HTTP APIs.")
    home_seo_title = "Zokor: Backend Framework for Slang"
    structured_data = {
        "@context": "https://schema.org",
        "@graph": [
            {
                "@type": "WebSite",
                "@id": SITE_URL + "#website",
                "url": SITE_URL,
                "name": "Zokor",
                "inLanguage": "en",
            },
            {
                "@type": "SoftwareSourceCode",
                "@id": SITE_URL + "#software",
                "url": SITE_URL,
                "name": "Zokor",
                "description": home_description,
                "codeRepository": "https://github.com/dolphlabs/zokor",
                "programmingLanguage": "Slang",
                "maintainer": {
                    "@type": "Organization",
                    "name": "Dolphlabs",
                    "url": "https://dolphlabs.com/",
                },
            },
        ],
    }
    home_path = "index.html"
    home_page = page_html(template, title=title, tagline=tagline,
                          body=home_body, path=home_path, hero=home_hero,
                          seo_title=home_seo_title, description=home_description,
                          structured_data=structured_data,
                          show_page_head=False)
    files[home_path] = home_page
    files["index.md"] = markdown_twin(title, tagline, home_markdown)
    pages.append({"path": home_path, "title": title, "tagline": tagline,
                  "body": home_body})
    search.append({"title": title, "tagline": tagline, "url": public_path(home_path),
                   "text": html_text(home_body + preamble_html)})
    markdown_pages.append(files["index.md"])

    for page in GUIDE_PAGES:
        root = relative_root(page["path"])
        ids = set()
        html_sections = []
        markdown_sections = []
        for section_name in page["sections"]:
            section_id = unique_id(section_name, ids)
            section_html = md_to_html(sections[section_name], root, page["path"], ids)
            html_sections.append(
                '<section class="readme-section"><h2 id="%s">%s'
                '<a class="anchor" href="#%s" aria-label="Link to this section">#</a>'
                '</h2>%s</section>' % (section_id, html.escape(section_name),
                                       section_id, section_html))
            markdown_sections.append("## %s\n\n%s" %
                                     (section_name, "\n".join(sections[section_name]).strip()))
        page_body = "\n".join(html_sections)
        summary = page["description"]
        path = page["path"]
        page_template = page_html(template, title=page["title"], tagline=summary,
                                  body=page_body, path=path,
                                  seo_title=page["seo_title"], description=summary)
        markdown_body = "\n\n".join(markdown_sections)
        twin = markdown_twin(page["title"], summary, markdown_body)
        twin_path = str(Path(path).with_suffix(".md"))
        files[path] = page_template
        files[twin_path] = twin
        pages.append({"path": path, "title": page["title"], "tagline": summary,
                      "body": page_body})
        search.append({"title": page["title"], "tagline": summary,
                       "url": public_path(path),
                       "text": html_text(page_body)})
        markdown_pages.append(twin)

    api_path = ROOT / "docs" / "api.txt"
    modules = read_api(api_path)
    api_html, api_search = render_api(modules, "../", "api/index.html")
    api_summary = (
        "Browse public Zokor types, functions, and methods, with signatures and "
        "descriptions generated from the source package.")
    api_page = page_html(template, title="API reference", tagline=api_summary,
                         body=api_html, path="api/index.html",
                         seo_title="Zokor API Reference | Public Types and Functions",
                         description=api_summary)
    files["api/index.html"] = api_page
    files["api/index.md"] = api_path.read_text(encoding="utf-8")
    pages.append({"path": "api/index.html", "title": "API reference",
                  "tagline": api_summary, "body": api_html})
    search.extend(api_search)
    markdown_pages.append(files["api/index.md"])

    example_cards = []
    example_search = []
    example_markdown_pages = []
    example_index_root = relative_root("examples/index.html")
    for example in EXAMPLE_PAGES:
        root = relative_root(example["path"])
        example_html, example_markdown, sources = render_example(
            example, root, example["path"])
        example_summary = example["description"]
        page_html_content = page_html(
            template, title=example["title"], tagline=example_summary,
            body=example_html, path=example["path"],
            seo_title=example["seo_title"], description=example_summary)
        markdown_path = str(Path(example["path"]).with_suffix(".md"))
        files[example["path"]] = page_html_content
        files[markdown_path] = markdown_twin(example["title"], example_summary,
                                              example_markdown)
        pages.append({"path": example["path"], "title": example["title"],
                      "tagline": example_summary, "body": example_html})
        example_search.append({"title": example["title"], "tagline": example_summary,
                               "url": public_path(example["path"]),
                               "text": html_text(example_html)})
        example_markdown_pages.append(files[markdown_path])
        example_cards.append(
            '<a class="example-card" href="%s"><span class="eyebrow">%s files</span>'
            '<strong>%s</strong><span>%s</span></a>' % (
                html.escape(example_index_root + public_path(example["path"])),
                len(sources),
                html.escape(example["title"]),
                html.escape(example_summary)))
    example_index_body = '<div class="example-grid">%s</div>' % "".join(example_cards)
    example_index_summary = (
        "Explore runnable Slang examples built with Zokor, from a minimal HTTP "
        "service to WebSocket chat and testable ports and fakes.")
    example_index = page_html(template, title="Examples", tagline=example_index_summary,
                              body=example_index_body, path="examples/index.html",
                              seo_title="Zokor Examples | Slang Services, HTTP and WebSockets",
                              description=example_index_summary)
    files["examples/index.html"] = example_index
    files["examples/index.md"] = markdown_twin(
        "Examples", example_index_summary,
        "\n\n".join("- [%s](%s) — %s" % (
            example["title"], Path(example["path"]).name, example["command"])
                   for example in EXAMPLE_PAGES))
    pages.append({"path": "examples/index.html", "title": "Examples",
                  "tagline": example_index_summary, "body": example_index_body})
    search.extend(example_search)
    search.append({"title": "Examples", "tagline": example_index_summary,
                   "url": public_path("examples/index.html"),
                   "text": html_text(example_index_body)})
    markdown_pages.extend([files["examples/index.md"], *example_markdown_pages])

    sitemap = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    ]
    for page in pages:
        sitemap.extend(["  <url>", "    <loc>%s</loc>" %
                        html.escape(canonical_url(page["path"]), quote=False),
                        "  </url>"])
    sitemap.append("</urlset>")
    files["sitemap.xml"] = "\n".join(sitemap) + "\n"

    files["style.css"] = (WWW / "theme" / "style.css").read_text(encoding="utf-8")
    files["app.js"] = (WWW / "theme" / "app.js").read_text(encoding="utf-8")
    for name, (content_type, expected_size) in ASSETS.items():
        source = WWW / "assets" / name
        if not source.is_file():
            raise ValueError("missing resized asset %s" % source)
        data = source.read_bytes()
        actual_size = image_dimensions(data, name)
        if actual_size != expected_size:
            raise ValueError("%s is %sx%s; expected %sx%s" %
                             (name, actual_size[0], actual_size[1],
                              expected_size[0], expected_size[1]))
        files["assets/" + name] = data

    site_index = ["# Zokor", "", "> %s" % tagline, "", "## Pages", ""]
    for page in pages:
        site_index.append("- [%s](%s): %s" % (
            page["title"], Path(page["path"]).with_suffix(".md").as_posix(),
            page["tagline"]))
    site_index.extend(["", "## Source", "",
                       "The guide is pulled from README.md. API entries come from "
                       "docs/api.txt, generated and checked from zokor/. Examples "
                       "are read directly from examples/.", ""])
    files["llms.txt"] = "\n".join(site_index)
    files["llms-full.txt"] = "\n\n".join(markdown_pages)
    files["search.json"] = json.dumps(search, ensure_ascii=False, separators=(",", ":"))
    files["api.json"] = json.dumps({
        "package": "zokor",
        "source": "docs/api.txt",
        "modules": modules,
    }, ensure_ascii=False, indent=2)
    files[".nojekyll"] = ""
    files["robots.txt"] = (
        "User-agent: *\nAllow: /\n\n"
        "Sitemap: %ssitemap.xml\n" % SITE_URL)
    files["_headers"] = """/*.md
  Content-Type: text/plain; charset=utf-8
  Access-Control-Allow-Origin: *
  X-Robots-Tag: noindex

/*.txt
  Content-Type: text/plain; charset=utf-8
  Access-Control-Allow-Origin: *
  X-Robots-Tag: noindex

/*.json
  Content-Type: application/json; charset=utf-8
  Access-Control-Allow-Origin: *
  X-Robots-Tag: noindex

/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
"""
    return files


def write_files(files, out_dir, check):
    out = Path(out_dir)
    if check:
        differences = []
        for relative, expected in sorted(files.items()):
            target = out / relative
            actual = target.read_bytes() if target.is_file() else None
            expected_bytes = expected if isinstance(expected, bytes) else expected.encode("utf-8")
            if actual != expected_bytes:
                differences.append(relative)
        if differences:
            print("docs site: generated output is stale; run make docs", file=sys.stderr)
            for path in differences[:30]:
                print("  %s" % path, file=sys.stderr)
            if len(differences) > 30:
                print("  ... and %d more" % (len(differences) - 30), file=sys.stderr)
            return False
        print("PASS docs site is up to date (%d generated files)" % len(files))
        return True

    out.mkdir(parents=True, exist_ok=True)
    for relative, content in files.items():
        target = out / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            target.write_bytes(content)
        else:
            target.write_text(content, encoding="utf-8")
    print("built %d site files -> %s" % (len(files), out))
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT,
                        help="output directory (default: docs)")
    parser.add_argument("--check", action="store_true",
                        help="fail if generated files differ from the output")
    args = parser.parse_args()
    try:
        files = build_files()
    except (OSError, ValueError) as error:
        print("docs site: %s" % error, file=sys.stderr)
        return 1
    return 0 if write_files(files, args.out, args.check) else 1


if __name__ == "__main__":
    raise SystemExit(main())
