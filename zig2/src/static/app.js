// CSS already re-themes via `color-scheme` + light-dark(). This listener adds
// runtime reaction: it mirrors the current mode into `data-theme` (an override
// hook), updates the indicator, and emits a `themechange` event.
(function () {
  const query = window.matchMedia("(prefers-color-scheme: dark)");
  function applyTheme() {
    const mode = query.matches ? "dark" : "light";
    document.documentElement.dataset.theme = mode;
    const label = document.getElementById("theme-name");
    if (label) label.textContent = mode;
    document.dispatchEvent(new CustomEvent("themechange", { detail: { mode } }));
  }
  query.addEventListener("change", applyTheme);
  applyTheme();
})();
