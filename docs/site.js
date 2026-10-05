// MacDown2.0 landing page: remembers an explicit language choice + copy buttons. No libraries, no network.
// English lives at / and Chinese at /zh/ (Scripts/build-site.py); the EN / 中文 control is a plain link between them.
// The page head also carries a small inline script that sends a returning visitor who chose 中文 from / to /zh/.
(function () {
  var KEY = "macdown2-lang";
  var COPIED = { en: "Copied", zh: "已复制" };

  function remember(l) { try { localStorage.setItem(KEY, l); } catch (e) {} }

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

  document.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest("[data-lang]");
    if (b) { remember(b.getAttribute("data-lang")); return; } // the link navigates by itself
    var c = e.target.closest && e.target.closest("[data-copy]");
    if (!c) return;
    copyText(c.getAttribute("data-copy")).then(function () {
      var live = document.getElementById("live");
      c.classList.add("done");
      live.textContent = COPIED[/^zh/i.test(document.documentElement.lang) ? "zh" : "en"];
      clearTimeout(c._t);
      c._t = setTimeout(function () { c.classList.remove("done"); live.textContent = ""; }, 1600);
    }, function () {});
  });
})();
