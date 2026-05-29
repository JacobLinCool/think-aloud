/* ThinkAloud landing page — progressive enhancement only.
   Everything degrades gracefully: with JS off the page is fully readable,
   the hero animation is pure CSS, and download buttons point at the
   Releases page. */

(function () {
  "use strict";

  var REPO = "JacobLinCool/think-aloud";

  /* ---- year in footer ---- */
  var yearEl = document.getElementById("year");
  if (yearEl) yearEl.textContent = "© " + new Date().getFullYear();

  /* ---- nav shadow once scrolled ---- */
  var nav = document.getElementById("nav");
  if (nav) {
    var onScroll = function () {
      nav.classList.toggle("nav--scrolled", window.scrollY > 8);
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
  }

  /* ---- reveal-on-scroll ---- */
  var revealEls = Array.prototype.slice.call(document.querySelectorAll("[data-reveal]"));

  if ("IntersectionObserver" in window && revealEls.length) {
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            io.unobserve(entry.target);
          }
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.1 }
    );
    // Hold reveals until the opening animation finishes — otherwise content
    // already in view (e.g. the statement band on phones, where the hero is
    // not full height) would appear before the icon has settled.
    var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    var started = false;
    var startObserving = function () {
      if (started) return;
      started = true;
      revealEls.forEach(function (el) { io.observe(el); });
    };
    if (reduce) {
      startObserving();
    } else {
      setTimeout(startObserving, 2700);
      // …but if the visitor scrolls during the intro, reveal right away.
      window.addEventListener("scroll", startObserving, { once: true, passive: true });
    }
  } else {
    // no observer support — just show everything
    revealEls.forEach(function (el) { el.classList.add("is-visible"); });
  }

  /* ---- dynamic download: resolve the latest .dmg from GitHub Releases ---- */
  var downloadBtns = [
    document.getElementById("heroDownload"),
    document.getElementById("navDownload"),
    document.getElementById("ctaDownload"),
  ].filter(Boolean);
  var versionEl = document.getElementById("downloadVersion");

  function humanSize(bytes) {
    if (!bytes) return "";
    var mb = bytes / (1024 * 1024);
    return mb >= 1 ? mb.toFixed(1) + " MB" : Math.round(bytes / 1024) + " KB";
  }

  fetch("https://api.github.com/repos/" + REPO + "/releases/latest", {
    headers: { Accept: "application/vnd.github+json" },
  })
    .then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function (rel) {
      var dmg = (rel.assets || []).filter(function (a) {
        return /\.dmg$/i.test(a.name);
      })[0];
      var tag = rel.tag_name || "";

      if (dmg && dmg.browser_download_url) {
        downloadBtns.forEach(function (b) { b.href = dmg.browser_download_url; });
      }
      if (versionEl && tag) {
        var size = humanSize(dmg && dmg.size);
        versionEl.textContent =
          "macOS · " + tag + (size ? " · " + size : "");
      }
    })
    .catch(function () {
      /* offline or rate-limited — leave the Releases-page fallback hrefs intact */
      if (versionEl) versionEl.textContent = "Latest release on GitHub";
    });
})();
