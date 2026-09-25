// Sentry en el navegador (proyecto mobventa-web). Se carga como script clásico
// ANTES del loader de Sentry en cada página; el loader llama a window.sentryOnLoad.
// Solo errores: sin trazas ni replay. Los enlaces privados /c/<token> se ocultan.
window.sentryOnLoad = function () {
  var ocultar = function (s) {
    return typeof s === 'string' ? s.replace(/\/c\/[a-f0-9]{24,}/g, '/c/<token>') : s;
  };
  Sentry.init({
    environment: location.hostname === 'mobventa.netlify.app' ? 'production' : 'preview',
    release: 'mobventa@' + (document.documentElement.dataset.version || 'dev'),
    sendDefaultPii: false,
    tracesSampleRate: 0,
    replaysSessionSampleRate: 0,
    replaysOnErrorSampleRate: 0,
    ignoreErrors: [/ResizeObserver loop/, /Load failed/, /NetworkError/, /AbortError/],
    initialScope: { tags: { pagina: location.pathname.split('/')[1] || 'catalogo' } },
    beforeSend: function (event) {
      if (event.request && event.request.url) event.request.url = ocultar(event.request.url);
      if (event.request && event.request.headers && event.request.headers.Referer) {
        event.request.headers.Referer = ocultar(event.request.headers.Referer);
      }
      (event.breadcrumbs || []).forEach(function (b) {
        if (b.data) { if (b.data.url) b.data.url = ocultar(b.data.url); if (b.data.to) b.data.to = ocultar(b.data.to); if (b.data.from) b.data.from = ocultar(b.data.from); }
        if (b.message) b.message = ocultar(b.message);
      });
      return event;
    },
  });
};
