# Mantenimiento — mantener viva la base y cerrar el proyecto

## Por qué
Supabase pausa los proyectos del plan gratuito que muestran poca actividad de usuarios durante 7 días
(avisa por correo una semana antes; un proyecto pausado se restaura con un clic durante 90 días).
Según su documentación bastan «unas pocas consultas al día». Las tareas internas (pg_cron) no cuentan:
la actividad debe llegar por la API. Solo el plan Pro lo garantiza del todo.

## Latido (migración 022)
`public.latido(origen)` actualiza una fila en `public.latidos` (una por origen, como mucho una escritura
cada 10 min). La llaman dos disparadores independientes:

| Origen | Qué es | Frecuencia | Dónde se configura |
| --- | --- | --- | --- |
| `netlify` | función programada `netlify/functions/latido.js` | cada 6 h | `config.schedule` en el propio archivo |
| `sentry` | monitor de disponibilidad «Supabase mobventa: latido» | cada hora | Sentry → Alerts/Uptime, proyecto `mobventa-functions` |

El monitor de Sentry llama directo a `https://<ref>.supabase.co/rest/v1/rpc/latido` (POST, cabecera `apikey`
con la clave anónima, cuerpo `{"p_origen":"sentry"}`), sin pasar por Netlify. Si la base deja de responder
(por ejemplo, porque se pausó), Sentry abre una incidencia y avisa por correo.

Comprobación: Administración → Ajustes muestra la fecha del último latido de cada origen. Por SQL:
`select * from public.latidos;`

## Si llega el correo de aviso de pausa
Entrar al dashboard de Supabase (eso ya genera actividad) y revisar por qué fallaron los dos disparadores:
`select * from public.latidos;`, los logs de la función `latido` en Netlify y el monitor en Sentry.

## Cierre del proyecto
1. Exportar un respaldo: Supabase → Database → Backups, o `supabase db dump` con la CLI; descargar el bucket `fotos`.
2. Desactivar el monitor en Sentry (Alerts → Uptime → «Supabase mobventa: latido» → Disable).
3. Quitar `netlify/functions/latido.js` (o borrar el sitio en Netlify).
4. Pausar o eliminar el proyecto en Supabase. Sin latido, se pausará solo a la semana.
