import json
import re
import unittest
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

from www.build import ROOT, build_files


class ResourceLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("href", "src") and value:
                self.urls.append(value)


class SearchMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = build_files()
        cls.pages = {
            path: content for path, content in cls.files.items()
            if path.endswith(".html")
        }

    def test_html_pages_have_unique_search_metadata(self):
        titles = []
        descriptions = []
        for path, source in self.pages.items():
            title = re.search(r"<title>(.*?)</title>", source, re.S)
            description = re.search(
                r'<meta name="description" content="(.*?)">', source, re.S)
            self.assertIsNotNone(title, path)
            self.assertIsNotNone(description, path)
            titles.append(title.group(1))
            descriptions.append(description.group(1))
            self.assertLessEqual(len(title.group(1)), 70, path)
            self.assertGreaterEqual(len(description.group(1)), 50, path)
            self.assertLessEqual(len(description.group(1)), 160, path)
            self.assertNotRegex(description.group(1), r"(?:\.\.\.|\s[,.])$")

            canonical = re.search(
                r'<link rel="canonical" href="(.*?)">', source, re.S)
            self.assertIsNotNone(canonical, path)
            self.assertTrue(canonical.group(1).startswith(
                "https://zokor.dolphlabs.com/"), path)
            self.assertIn(
                '<meta property="og:url" content="%s">' % canonical.group(1),
                source, path)
            self.assertIn('<meta property="og:title" content="%s">' %
                          title.group(1), source, path)
            self.assertIn('<meta name="twitter:title" content="%s">' %
                          title.group(1), source, path)
            self.assertIn(
                '<meta property="og:image" content="https://zokor.dolphlabs.com/'
                'assets/zokor-card-1200x630.jpg">', source, path)

        self.assertEqual(len(titles), len(set(titles)))
        self.assertEqual(len(descriptions), len(set(descriptions)))

    def test_sitemap_contains_the_canonical_html_pages(self):
        sitemap = ET.fromstring(self.files["sitemap.xml"])
        namespace = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
        locations = {
            node.text for node in sitemap.findall("s:url/s:loc", namespace)
        }
        canonicals = {
            re.search(r'<link rel="canonical" href="(.*?)">', source).group(1)
            for source in self.pages.values()
        }
        self.assertEqual(locations, canonicals)
        self.assertIn("Sitemap: https://zokor.dolphlabs.com/sitemap.xml",
                      self.files["robots.txt"])

    def test_links_and_sitemap_use_cloudflare_extensionless_routes(self):
        homepage = self.pages["index.html"]
        examples = self.pages["examples/index.html"]
        self.assertIn('<a class="brand" href="./">', homepage)
        self.assertIn('href="guide/start"', homepage)
        self.assertIn('href="api/"', homepage)
        self.assertIn('href="../examples/hello"', examples)
        sitemap = ET.fromstring(self.files["sitemap.xml"])
        namespace = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
        for location in sitemap.findall("s:url/s:loc", namespace):
            self.assertNotIn(".html", location.text)

    def test_internal_links_resolve_from_their_canonical_routes(self):
        for path, source in self.pages.items():
            canonical = re.search(
                r'<link rel="canonical" href="(.*?)">', source).group(1)
            parser = ResourceLinks()
            parser.feed(source)
            for target in parser.urls:
                resolved = urlsplit(urljoin(canonical, target))
                if resolved.netloc != "zokor.dolphlabs.com" or not resolved.path:
                    continue
                self.assertFalse(resolved.path.endswith(".html"),
                                 "%s links to a redirecting .html URL: %s" %
                                 (path, target))
                route = resolved.path.lstrip("/")
                if not route:
                    route = "index.html"
                elif route.endswith("/"):
                    route += "index.html"
                elif route not in self.files and route + ".html" in self.files:
                    route += ".html"
                exists = route in self.files or (ROOT / "docs" / route).is_file()
                self.assertTrue(exists, "%s -> %s (%s)" % (path, target, route))

    def test_machine_readable_alternates_are_available_but_not_indexed(self):
        headers = self.files["_headers"]
        for rule in ("/*.md", "/*.txt", "/*.json"):
            block = headers.split(rule, 1)[1].split("\n\n", 1)[0]
            self.assertIn("X-Robots-Tag: noindex", block)
        self.assertIn("Content-Type: text/plain; charset=utf-8", headers)
        self.assertIn("Access-Control-Allow-Origin: *", headers)

    def test_homepage_has_valid_source_code_structured_data(self):
        homepage = self.pages["index.html"]
        block = re.search(
            r'<script type="application/ld\+json">(.*?)</script>',
            homepage, re.S)
        self.assertIsNotNone(block)
        data = json.loads(block.group(1))
        entities = data["@graph"]
        source_code = next(item for item in entities
                           if item["@type"] == "SoftwareSourceCode")
        self.assertEqual(source_code["name"], "Zokor")
        self.assertEqual(source_code["url"], "https://zokor.dolphlabs.com/")
        self.assertEqual(source_code["codeRepository"],
                         "https://github.com/dolphlabs/zokor")


if __name__ == "__main__":
    unittest.main()
