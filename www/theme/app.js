/* Search, copying, navigation and theme are enhancements. Page content is
 * rendered into HTML by build.py, so it remains available without JavaScript. */
(function () {
  "use strict";

  var root = document.documentElement;
  var theme = document.getElementById("theme");
  try {
    var savedTheme = localStorage.getItem("zokor-theme");
    if (savedTheme === "dark" || savedTheme === "light") root.dataset.theme = savedTheme;
  } catch (error) {}
  if (theme) {
    theme.addEventListener("click", function () {
      var dark = root.dataset.theme
        ? root.dataset.theme === "dark"
        : matchMedia("(prefers-color-scheme: dark)").matches;
      root.dataset.theme = dark ? "light" : "dark";
      try { localStorage.setItem("zokor-theme", root.dataset.theme); } catch (error) {}
    });
  }

  var toggle = document.getElementById("navtoggle");
  var nav = document.getElementById("mainnav");
  var scrim = document.getElementById("navscrim");
  if (toggle && nav && scrim) {
    function closeNav() {
      nav.classList.remove("open");
      toggle.setAttribute("aria-expanded", "false");
      scrim.hidden = true;
    }
    toggle.addEventListener("click", function () {
      var open = toggle.getAttribute("aria-expanded") !== "true";
      toggle.setAttribute("aria-expanded", String(open));
      nav.classList.toggle("open", open);
      scrim.hidden = !open;
    });
    scrim.addEventListener("click", closeNav);
    nav.addEventListener("click", function (event) {
      if (event.target.closest("a")) closeNav();
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && toggle.getAttribute("aria-expanded") === "true") {
        closeNav(); toggle.focus();
      }
    });
  }

  document.querySelectorAll(".copy").forEach(function (button) {
    button.addEventListener("click", function () {
      var code = button.closest(".code").querySelector("pre code");
      if (!code || !navigator.clipboard) return;
      navigator.clipboard.writeText(code.innerText).then(function () {
        button.textContent = "Copied";
        button.classList.add("ok");
        setTimeout(function () {
          button.textContent = "Copy";
          button.classList.remove("ok");
        }, 1400);
      }).catch(function () {});
    });
  });

  var toc = document.getElementById("toc");
  var headings = Array.prototype.slice.call(
    document.querySelectorAll(".content h2[id], .content h3[id]"));
  if (toc && headings.length) {
    headings.forEach(function (heading) {
      var link = document.createElement("a");
      link.href = "#" + heading.id;
      link.textContent = heading.textContent.replace(/#$/, "").trim();
      if (heading.tagName === "H3") link.className = "h3";
      toc.appendChild(link);
    });
  }

  var search = document.getElementById("search");
  var results = document.getElementById("results");
  var stylesheet = document.querySelector('link[rel="stylesheet"][href$="style.css"]');
  var base = stylesheet ? stylesheet.getAttribute("href").replace(/style\.css$/, "") : "";
  var index;

  function loadIndex() {
    if (index) return Promise.resolve(index);
    return fetch(base + "search.json").then(function (response) {
      if (!response.ok) throw new Error("search index unavailable");
      return response.json();
    }).then(function (value) {
      index = value;
      return index;
    });
  }

  function render(items, query) {
    while (results.firstChild) results.removeChild(results.firstChild);
    if (!items.length) {
      var empty = document.createElement("p");
      empty.className = "empty";
      empty.textContent = "No matches for “" + query + "”.";
      results.appendChild(empty);
    } else {
      items.forEach(function (item) {
        var link = document.createElement("a");
        link.href = base + item.url;
        link.setAttribute("role", "option");
        var title = document.createElement("strong");
        title.textContent = item.title;
        var summary = document.createElement("small");
        summary.textContent = item.tagline || "";
        link.appendChild(title);
        link.appendChild(summary);
        results.appendChild(link);
      });
    }
    results.hidden = false;
  }

  function runSearch() {
    var query = search.value.trim().toLowerCase();
    if (query.length < 2) { results.hidden = true; return; }
    loadIndex().then(function (items) {
      var matches = [];
      items.forEach(function (item) {
        var title = (item.title || "").toLowerCase();
        var summary = (item.tagline || "").toLowerCase();
        var body = (item.text || "").toLowerCase();
        var score = title === query ? 100 : title.indexOf(query) === 0 ? 60
          : title.indexOf(query) >= 0 ? 40 : summary.indexOf(query) >= 0 ? 20
          : body.indexOf(query) >= 0 ? 10 : 0;
        if (score) matches.push({ item: item, score: score });
      });
      matches.sort(function (a, b) { return b.score - a.score; });
      render(matches.slice(0, 12).map(function (match) { return match.item; }), search.value.trim());
    }).catch(function () { results.hidden = true; });
  }

  if (search && results) {
    search.addEventListener("input", runSearch);
    search.addEventListener("focus", function () {
      if (search.value.trim().length > 1) runSearch();
    });
    document.addEventListener("click", function (event) {
      if (!results.contains(event.target) && event.target !== search) results.hidden = true;
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "/" && document.activeElement !== search) {
        event.preventDefault(); search.focus();
      } else if (event.key === "Escape") {
        results.hidden = true;
      }
    });
  }
})();
