// Sentry en las funciones de Netlify (proyecto mobventa-functions).
// Requiere la variable de entorno SENTRY_DSN_FUNCTIONS; sin ella no hace nada.
// @sentry/node (con OpenTelemetry) pesa varios MB y tarda 150-400 ms en inicializarse: se carga
// solo cuando hay algo que reportar, así el arranque en frío de cada función no lo paga.
const dsn = process.env.SENTRY_DSN_FUNCTIONS;
let sentryPromise = null;
async function cargarSentry() {
  if (!sentryPromise) {
    sentryPromise = import('@sentry/node').then((Sentry) => {
      Sentry.init({
        dsn,
        environment: process.env.CONTEXT || 'production',
        release: process.env.COMMIT_REF ? `mobventa@${process.env.COMMIT_REF.slice(0, 7)}` : undefined,
        sendDefaultPii: false,
        tracesSampleRate: 0,
      });
      return Sentry;
    });
  }
  return sentryPromise;
}

/** Registra una excepción con contexto de la función. Seguro de llamar sin DSN. */
export async function reportar(e, extra = {}) {
  if (!dsn) return;
  const Sentry = await cargarSentry();
  Sentry.withScope((scope) => {
    for (const [k, v] of Object.entries(extra)) scope.setTag(k, String(v));
    Sentry.captureException(e);
  });
  await Sentry.flush(2000);
}

/** Envuelve un handler (req, context) => Response: captura lo no controlado y responde 500 sin detalles. */
export function withSentry(nombre, handler) {
  return async (req, context) => {
    try {
      return await handler(req, context);
    } catch (e) {
      console.error(`[${nombre}]`, e);
      await reportar(e, { funcion: nombre, metodo: req.method });
      return new Response(JSON.stringify({ error: 'Error interno' }), {
        status: 500, headers: { 'content-type': 'application/json' },
      });
    }
  };
}
