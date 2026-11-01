// Registers the service worker and wires the "Install app" button (any element
// with data-install). The button only shows when the browser offers installation
// and hides itself once Dispatch HQ is running as an installed app.
(function () {
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register('sw.js').catch(function (err) { console.warn('SW registration failed', err); });
    });
  }
  var installed = window.matchMedia('(display-mode: standalone)').matches ||
    window.matchMedia('(display-mode: window-controls-overlay)').matches ||
    window.navigator.standalone === true;
  var deferred = null;
  function buttons() { return document.querySelectorAll('[data-install]'); }
  function toggle(show) { buttons().forEach(function (b) { b.style.display = show ? '' : 'none'; }); }
  window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    deferred = e;
    if (!installed) toggle(true);
  });
  window.addEventListener('appinstalled', function () { deferred = null; toggle(false); });
  document.addEventListener('click', function (e) {
    var b = e.target.closest && e.target.closest('[data-install]');
    if (!b || !deferred) return;
    deferred.prompt();
    deferred.userChoice.finally(function () { deferred = null; toggle(false); });
  });
})();
