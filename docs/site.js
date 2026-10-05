// MacDown2.0 landing page: language toggle + copy buttons. No libraries, no network.
(function () {
  var KEY = "macdown2-lang";
  var root = document.documentElement;
  var TEXT = {
    en: {
      title: "MacDown2.0 — Markdown, native to the Mac",
      desc: "MacDown2.0 is a free, open-source Markdown editor for macOS 26, written from scratch in Swift. Dark source on the left, live preview on the right, re-rendered in milliseconds as you type.",
      copied: "Copied"
    },
    zh: {
      title: "MacDown2.0 — Markdown，回归 Mac 原生",
      desc: "MacDown2.0 是一款免费开源的 macOS 26 Markdown 编辑器，用 Swift 从零重写。左边是深色源码，右边是实时预览，边打字边在毫秒间刷新。",
      copied: "已复制"
    }
  };

  function stored() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }
  function remember(l) { try { localStorage.setItem(KEY, l); } catch (e) {} }
  function cur() { return root.lang.indexOf("zh") === 0 ? "zh" : "en"; }

  function setLang(l) {
    var t = TEXT[l];
    root.lang = l === "zh" ? "zh-Hans" : "en";
    document.title = t.title;
    var m = document.querySelector('meta[name="description"]');
    if (m) m.setAttribute("content", t.desc);
    var btns = document.querySelectorAll("[data-lang]");
    for (var i = 0; i < btns.length; i++) btns[i].setAttribute("aria-pressed", String(btns[i].getAttribute("data-lang") === l));
  }

  // Set <html lang> before first paint so there is no flash of the other language.
  var first = stored();
  if (first !== "en" && first !== "zh") first = /^zh/i.test(navigator.language || "") ? "zh" : "en";
  root.lang = first === "zh" ? "zh-Hans" : "en";

  function legacyCopy(text) {
    return new Promise(function (ok, fail) {
      var ta = document.createElement("textarea");
      ta.value = text; ta.setAttribute("readonly", ""); ta.style.cssText = "position:fixed;top:0;opacity:0";
      document.body.appendChild(ta); ta.select();
      try { document.execCommand("copy") ? ok() : fail(); } catch (e) { fail(e); } finally { document.body.removeChild(ta); }
    });
  }
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text).catch(function () { return legacyCopy(text); });
    return legacyCopy(text);
  }

  document.addEventListener("DOMContentLoaded", function () {
    setLang(first);
    document.addEventListener("click", function (e) {
      var b = e.target.closest && e.target.closest("[data-lang]");
      if (b) { var l = b.getAttribute("data-lang"); remember(l); setLang(l); return; }
      var c = e.target.closest && e.target.closest("[data-copy]");
      if (!c) return;
      copyText(c.getAttribute("data-copy")).then(function () {
        var live = document.getElementById("live");
        c.classList.add("done");
        live.textContent = TEXT[cur()].copied;
        clearTimeout(c._t);
        c._t = setTimeout(function () { c.classList.remove("done"); live.textContent = ""; }, 1600);
      }, function () {});
    });
  });
})();
