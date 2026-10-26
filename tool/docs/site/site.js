// Daravel documentation site: theme, search, copy buttons, highlighting,
// "on this page" scroll-spy, version switcher, landing tabs. No dependencies.
(function () {
  "use strict";
  var root = document.documentElement;
  var STORAGE = "daravel-theme";

  function storedTheme() {
    try { return localStorage.getItem(STORAGE); } catch (e) { return null; }
  }
  function applyTheme(theme) {
    if (theme === "light" || theme === "dark") root.setAttribute("data-theme", theme);
    else root.removeAttribute("data-theme");
    var button = document.querySelector("[data-theme-toggle]");
    if (button) {
      var label = theme === "light" ? "Light" : theme === "dark" ? "Dark" : "System";
      button.textContent = label;
      button.setAttribute("aria-label", "Theme: " + label);
    }
  }
  applyTheme(storedTheme());

  // Language: the EN / ID choice is remembered, and a visitor arriving from
  // another site (a search engine, a README link) on a page in the other
  // language is sent to the same page in theirs. Links inside the site are
  // never redirected, so the switcher always works.
  var LANG_STORAGE = "daravel-lang";
  function storedLang() {
    try { return localStorage.getItem(LANG_STORAGE); } catch (e) { return null; }
  }
  function fromThisSite() {
    try { return document.referrer && new URL(document.referrer).host === location.host; }
    catch (e) { return false; }
  }

  document.addEventListener("DOMContentLoaded", function () {
    var pageLang = root.getAttribute("lang");
    var wanted = storedLang();
    if (wanted && pageLang && wanted !== pageLang && !fromThisSite()) {
      var other = document.querySelector('.lang a[hreflang="' + wanted + '"]');
      if (other && other.getAttribute("aria-current") !== "true") {
        location.replace(other.href + location.hash);
        return;
      }
    }
    document.querySelectorAll(".lang a[hreflang]").forEach(function (link) {
      link.addEventListener("click", function () {
        try { localStorage.setItem(LANG_STORAGE, link.getAttribute("hreflang")); }
        catch (e) { /* private mode */ }
      });
    });

    applyTheme(storedTheme());

    var themeButton = document.querySelector("[data-theme-toggle]");
    if (themeButton) {
      themeButton.addEventListener("click", function () {
        var order = [null, "light", "dark"];
        var next = order[(order.indexOf(storedTheme()) + 1) % order.length];
        try {
          if (next) localStorage.setItem(STORAGE, next); else localStorage.removeItem(STORAGE);
        } catch (e) { /* private mode */ }
        applyTheme(next);
      });
    }

    var menu = document.querySelector("[data-menu-toggle]");
    var sidebar = document.querySelector(".sidebar");
    if (menu && sidebar) {
      menu.addEventListener("click", function () {
        var open = sidebar.classList.toggle("open");
        menu.setAttribute("aria-expanded", String(open));
      });
    }

    var versions = document.querySelector("[data-version-select]");
    if (versions) {
      versions.addEventListener("change", function () {
        var page = versions.getAttribute("data-page");
        window.location.href = versions.getAttribute("data-docs-root") + versions.value + "/" + page;
      });
    }

    highlightAll();
    addCopyButtons();
    initTabs();
    initToc();
    initSearch();
  });

  // Highlighting: a small tokenizer for the languages the guides use.
  var KEYWORDS = {
    dart: "abstract as assert async await base break case catch class const continue default deferred do dynamic else enum export extends extension external factory false final finally for Function get if implements import in interface is late library mixin new null on operator part required rethrow return sealed set show static super switch sync this throw true try typedef var void when while with yield",
    php: "abstract array as break case catch class clone const continue declare default do echo else elseif enum extends false final finally fn for foreach function global if implements instanceof interface match namespace new null private protected public readonly return static switch this throw true try use var while yield",
    bash: "if then else fi for do done case esac function export cd echo",
    yaml: "true false null",
    json: "true false null"
  };
  var LANGS = { sh: "bash", shell: "bash", console: "bash", yml: "yaml", dotenv: "bash", ini: "bash", caddyfile: "bash", nginx: "bash", dockerfile: "bash" };

  function escapeHtml(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function highlight(code, lang) {
    var words = KEYWORDS[lang];
    if (!words) return escapeHtml(code);
    var keywordSet = {};
    words.split(" ").forEach(function (w) { keywordSet[w] = true; });
    var hashComments = lang === "bash" || lang === "yaml" || lang === "php";
    var pattern = new RegExp(
      "(\\/\\/[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/" + (hashComments ? "|#[^\\n]*" : "") + ")" +
      "|(r?'(?:\\\\.|[^'\\\\\\n])*'|r?\"(?:\\\\.|[^\"\\\\\\n])*\")" +
      "|\\b(\\d+(?:\\.\\d+)?)\\b" +
      "|(\\$?[A-Za-z_][A-Za-z0-9_]*)",
      "g"
    );
    var out = "";
    var last = 0;
    code.replace(pattern, function (match, comment, string, number, word, index) {
      out += escapeHtml(code.slice(last, index));
      last = index + match.length;
      if (comment) out += '<span class="tok-c">' + escapeHtml(comment) + "</span>";
      else if (string) out += '<span class="tok-s">' + escapeHtml(string) + "</span>";
      else if (number) out += '<span class="tok-n">' + number + "</span>";
      else if (keywordSet[word]) out += '<span class="tok-k">' + word + "</span>";
      else if (/^[A-Z]/.test(word) && lang !== "bash") out += '<span class="tok-t">' + word + "</span>";
      else out += escapeHtml(word);
      return match;
    });
    return out + escapeHtml(code.slice(last));
  }
  function highlightAll() {
    document.querySelectorAll("pre code").forEach(function (block) {
      var match = /language-([\w-]+)/.exec(block.className);
      var lang = match ? match[1].toLowerCase() : "";
      lang = LANGS[lang] || lang;
      block.innerHTML = highlight(block.textContent, lang);
    });
  }

  function copy(text, button) {
    var done = function () {
      var label = button.textContent;
      button.textContent = "Copied";
      setTimeout(function () { button.textContent = label; }, 1400);
    };
    if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, function () {});
  }
  function addCopyButtons() {
    document.querySelectorAll(".prose pre, .pair pre").forEach(function (pre) {
      var button = document.createElement("button");
      button.className = "copy";
      button.type = "button";
      button.textContent = "Copy";
      button.addEventListener("click", function () { copy(pre.querySelector("code").textContent, button); });
      pre.appendChild(button);
    });
    document.querySelectorAll("[data-copy]").forEach(function (button) {
      button.addEventListener("click", function () { copy(button.getAttribute("data-copy"), button); });
    });
  }

  function initTabs() {
    var tabs = Array.prototype.slice.call(document.querySelectorAll('.tabs [role="tab"]'));
    function select(tab, focus) {
      tabs.forEach(function (t) {
        var selected = t === tab;
        t.setAttribute("aria-selected", String(selected));
        t.tabIndex = selected ? 0 : -1;
        document.getElementById(t.getAttribute("aria-controls")).hidden = !selected;
      });
      if (focus) tab.focus();
    }
    tabs.forEach(function (tab, index) {
      tab.addEventListener("click", function () { select(tab, false); });
      tab.addEventListener("keydown", function (event) {
        var step = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
        if (step) {
          event.preventDefault();
          select(tabs[(index + step + tabs.length) % tabs.length], true);
        }
      });
    });
  }

  function initToc() {
    var links = Array.prototype.slice.call(document.querySelectorAll(".toc a"));
    if (!links.length || !("IntersectionObserver" in window)) return;
    var byId = {};
    links.forEach(function (link) { byId[link.getAttribute("href").slice(1)] = link; });
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        links.forEach(function (l) { l.classList.remove("active"); });
        var link = byId[entry.target.id];
        if (link) link.classList.add("active");
      });
    }, { rootMargin: "-80px 0px -70% 0px" });
    Object.keys(byId).forEach(function (id) {
      var heading = document.getElementById(id);
      if (heading) observer.observe(heading);
    });
  }

  function initSearch() {
    var dialog = document.querySelector(".search-dialog");
    if (!dialog) return;
    var input = dialog.querySelector("input");
    var list = dialog.querySelector(".search-results");
    var indexUrl = dialog.getAttribute("data-index");
    var lang = dialog.getAttribute("data-lang");
    var base = dialog.getAttribute("data-base");
    var pages = null;
    var selected = 0;

    function load() {
      if (pages) return Promise.resolve(pages);
      return fetch(indexUrl).then(function (r) { return r.json(); }).then(function (data) {
        pages = data.pages;
        return pages;
      });
    }
    function open() {
      if (typeof dialog.showModal === "function") dialog.showModal(); else dialog.setAttribute("open", "");
      input.value = "";
      render([]);
      input.focus();
      load();
    }
    function render(results) {
      list.innerHTML = "";
      selected = 0;
      if (!input.value.trim()) return;
      if (!results.length) {
        list.innerHTML = '<li class="search-empty">No pages match "' + escapeHtml(input.value) + '".</li>';
        return;
      }
      results.slice(0, 12).forEach(function (result, i) {
        var item = document.createElement("li");
        item.setAttribute("role", "option");
        item.setAttribute("aria-selected", String(i === 0));
        var link = document.createElement("a");
        link.href = base + result.url;
        link.innerHTML = escapeHtml(result.title) + "<small>" + escapeHtml(result.context) + "</small>";
        item.appendChild(link);
        list.appendChild(item);
      });
    }
    function search(query) {
      var terms = query.toLowerCase().split(/\s+/).filter(Boolean);
      var results = [];
      (pages || []).forEach(function (page) {
        if (page.lang !== lang) return;
        var candidates = [{ title: page.title, url: page.url, context: page.category, text: page.title + " " + page.text, weight: 3 }];
        page.headings.forEach(function (h) {
          candidates.push({ title: h.text, url: page.url + "#" + h.id, context: page.title, text: h.text, weight: 2 });
        });
        candidates.forEach(function (c) {
          var haystack = c.text.toLowerCase();
          if (terms.every(function (t) { return haystack.indexOf(t) !== -1; })) {
            var titleHit = terms.every(function (t) { return c.title.toLowerCase().indexOf(t) !== -1; });
            results.push({ title: c.title, url: c.url, context: c.context, score: c.weight + (titleHit ? 5 : 0) });
          }
        });
      });
      return results.sort(function (a, b) { return b.score - a.score; });
    }
    function move(step) {
      var items = list.querySelectorAll('[role="option"]');
      if (!items.length) return;
      items[selected].setAttribute("aria-selected", "false");
      selected = (selected + step + items.length) % items.length;
      items[selected].setAttribute("aria-selected", "true");
      items[selected].scrollIntoView({ block: "nearest" });
    }

    document.querySelectorAll("[data-search-open]").forEach(function (b) { b.addEventListener("click", open); });
    document.addEventListener("keydown", function (event) {
      var typing = /input|textarea|select/i.test((event.target && event.target.tagName) || "");
      if ((event.key === "k" && (event.ctrlKey || event.metaKey)) || (event.key === "/" && !typing)) {
        event.preventDefault();
        open();
      }
    });
    input.addEventListener("input", function () {
      load().then(function () { render(search(input.value)); });
    });
    input.addEventListener("keydown", function (event) {
      if (event.key === "ArrowDown") { event.preventDefault(); move(1); }
      else if (event.key === "ArrowUp") { event.preventDefault(); move(-1); }
      else if (event.key === "Enter") {
        var current = list.querySelectorAll('[role="option"] a')[selected];
        if (current) window.location.href = current.href;
      }
    });
    dialog.addEventListener("click", function (event) { if (event.target === dialog) dialog.close(); });
  }
})();
