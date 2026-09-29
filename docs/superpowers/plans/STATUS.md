# Estado del Proyecto E-Commerce — Saleor + Nuxt 4

> Actualizar este archivo al inicio de cada sesión de trabajo.

---

## Estado General

| Campo | Valor |
|---|---|
| **Fase actual** | Fase 3 — Pasarelas de pago Colombia |
| **Fecha de inicio** | 2026-04-16 |
| **Última actualización** | 2026-04-27 |
| **Próxima acción** | Crear servicio Railway `app-wompi` + credenciales Wompi sandbox → prueba E2E |

---

## Fases del Proyecto

| # | Fase | Estado | Semanas | Plan |
|---|---|---|---|---|
| 0 | Infraestructura (Fork Saleor + Railway) | ✅ Completada | 1 | [Fase 0](2026-04-16-fase0-infraestructura.md) |
| 1 | Catálogo y Storefront base | ✅ Completada | 2-4 | [Fase 1](2026-04-16-fase1-catalogo-storefront.md) |
| 2 | Checkout sin pago | ✅ Completada | 5-6 | [Fase 2](2026-04-16-fase2-checkout-envios.md) |
| 3 | Pasarelas de pago Colombia | 🔄 En progreso | 7-9 | [Fase 3](2026-04-16-fase3-pasarelas-co.md) |
| 4 | Cuenta cliente y facturación | 🔲 Pendiente | 10-11 | [Fase 4](2026-04-16-fase4-cuenta-facturacion.md) |
| 5 | Pulido y Go-live | 🔲 Pendiente | 12-13 | [Fase 5](2026-04-16-fase5-golive.md) |

**Leyenda:** 🔲 Pendiente · 🔄 En progreso · ✅ Completada · ⛔ Bloqueada

---

## Repositorios

| Repo | URL | Estado |
|---|---|---|
| `licona-saleor` | https://github.com/aclicona/licona-saleor | ✅ Activo (branch `stable/3.22`) |
| `licona-storefront` | https://github.com/aclicona/licona-storefront | ✅ Activo — flujo de pago completo |
| `licona-saleor-apps` | https://github.com/aclicona/licona-saleor-apps | ✅ Activo — `app-envios` desplegado en Railway |

---

## Servicios Railway

| Servicio | Estado | URL |
|---|---|---|
| `postgres` | ✅ Corriendo | Railway interno |
| `redis` | ✅ Corriendo | Railway interno |
| `saleor-api` | ✅ Corriendo | https://saleor-api-production-a780.up.railway.app |
| `saleor-worker` | ✅ Corriendo | Railway interno (Celery) |
| `saleor-beat` | ✅ Corriendo | Railway interno (Celery beat) |
| `saleor-dashboard` | ✅ Corriendo | https://saleor-dashboard-production-4a02.up.railway.app |
| `storefront` | ✅ Corriendo | https://licona-storefront-production.up.railway.app |
| `app-wompi` | 🔄 Código listo, pendiente despliegue | rama `feat/fase3-wompi` |
| `app-payu` | 🔲 Por crear | — |
| `app-mercadopago` | 🔲 Por crear | — |
| `app-facturacion-co` | 🔲 Por crear | — |

---

## Criterios de Aceptación (del spec)

- [ ] Una orden completa: storefront → Wompi (tarjeta, PSE, Nequi) → dashboard → reembolso parcial
- [ ] Fork actualizable de minor a minor sin downtime
- [ ] Dashboard oficial sin modificaciones con Apps propias instaladas
- [ ] Lighthouse ≥ 90 (Performance, Accessibility, Best Practices, SEO) en mobile para home, PLP y PDP
- [ ] Fallo de una App no tumba el core ni el storefront
- [ ] Diseño distintivo, no de plantilla genérica

---

## Log de Sesiones

| Fecha | Sesión | Qué se hizo | Qué quedó pendiente |
|---|---|---|---|
| 2026-04-16 | Planificación | Spec recibida. Planes creados. CLAUDE.md actualizado. | Iniciar Fase 0 |
| 2026-04-17 | Fase 0 — Deploy | Fork activo en GitHub. Postgres + Redis + saleor-api corriendo en Railway. Dockerfile optimizado (multi-stage, uv, sin cache mounts). railway.json con DOCKERFILE builder, nixpacksPlan vacío para evitar inyección de Node.js cache mounts. Port fix con `sh -c`. RSA_PRIVATE_KEY como PEM crudo. | Worker, beat, dashboard |
| 2026-04-17 | Fase 0 — Completada | Todos los servicios corriendo. S3+CloudFront operativo (imágenes en d38o6f3ivpuaig.cloudfront.net). Fixes aplicados: ENTRYPOINT→CMD shell form, healthcheck por servicio, discount.0052 para PG18, dashboard=3.22, PUBLIC_URL, AWS_MEDIA_BUCKET_NAME. | GitHub Actions (sync + build) |
| 2026-04-17 | Fase 1 — Código base | Repo `licona-storefront` creado en GitHub. Nuxt 4, Tailwind v4 (CSS-first/@tailwindcss/vite), URQL+retryExchange, Codegen contra API real, componentes (ProductCard, ProductGrid, ProductGallery, ProductVariants), páginas (Home, PLP, PDP), endpoint revalidación ISR, Dockerfile. 3/3 tests Vitest. | Desplegar en Railway, agregar fuentes woff2 (Fraunces + Satoshi) |
| 2026-04-25 | Fase 2 — Checkout y App Envíos | Checkout mutations GraphQL + codegen. `useCart` (persistencia en cookie), `useCheckout`, CartDrawer, CartItem, páginas checkout/direccion, checkout/envio, checkout/confirmacion. Monorepo `licona-saleor-apps` con `app-envios` (Fastify 5, webhook `SHIPPING_LIST_METHODS_FOR_CHECKOUT`, Servientrega/Coordinadora/TCC). Dockerfile. Rama `feat/fase2-checkout`. | Push `licona-storefront` a Railway, crear repo GitHub `licona-saleor-apps`, crear servicio Railway `app-envios`, instalar App en Dashboard Saleor |
| 2026-04-26 | Fase 2 — Cierre + Fase 3 inicio | Fix `app.vue` (`<NuxtWelcome>` → `<NuxtLayout>`), layout `default.vue`, merge `feat/fase2-checkout` → `main`. Repo `licona-saleor-apps` creado en GitHub. `app-envios` desplegado en Railway e instalado en Dashboard. Fixes: campo `query` en manifest (requerido por Saleor), ruta `GET /` para iframe Dashboard, JWS verification reemplazando HMAC incorrecto. Paquete compartido `@licona/webhook-utils` con `verifySaleorWebhook` (RS256, payload detached). | Iniciar Task 1 Fase 3: scaffold `app-wompi` |
| 2026-04-27 | Fase 3 — app-wompi + flujo de pago storefront | `app-wompi` completo: 6 handlers Transactions API (JWS), webhook entrante Wompi (HMAC), `WompiClient`, `SaleorClient`, manifest con `query`, EnvAPL, Dockerfile. Storefront: `payment.graphql`, codegen, `usePayment` (urql v2), `PaymentMethodSelector` dinámico (lee `availablePaymentGateways` de Saleor), `pago.vue`, `orden/[id].vue`. Selector de pasarelas sin hardcodeo — refleja automáticamente lo instalado en Dashboard. | Crear servicio `app-wompi` en Railway + credenciales Wompi sandbox |
| 2026-04-27 | Proxy BFF + Railway private networking | Proxy `/api/graphql` en Nitro (BFF pattern). Diagnóstico completo de Railway private networking: IPv4 interna va por proxy TLS, IPv6 va directo al container. Fix encadenado: URL fallback correcta → env vars en Railway → `NUXT_PUBLIC_SALEOR_API_URL` → `--host=::` en Uvicorn (IPv6 dual-stack) → `X-Forwarded-Proto: https` para evitar `SECURE_SSL_REDIRECT` de Django → `preferGetMethod: false` en urql v2 (Saleor devuelve Playground HTML para GET). Proxy funcionando 100% vía red interna IPv6. | Iniciar Task 1 Fase 3: scaffold `app-wompi` |

---

## Notas para Fase 3

- El plan de Fase 3 (Task 2) no incluye campo `query` en los webhooks del manifest de `app-wompi` — **agregar antes de instalar** (misma causa que el bug de `app-envios`).
- El plan usa `const [, fn] = useMutation(...)` de `@urql/vue` v1 — la v2 retorna `{ executeMutation }`. **Corregir en `usePayment.ts`**.
- `app-wompi` debe usar `@licona/webhook-utils` para verificar webhooks de Saleor (JWS/RS256). Los webhooks entrantes de Wompi sí usan HMAC — `verify-signature.ts` del plan es correcto para ese caso.
- `SALEOR_WEBHOOK_SECRET` no existe para apps registradas por manifest — eliminar de cualquier variable de entorno.

---

## Decisiones Técnicas Tomadas

| Decisión | Razón | Fecha |
|---|---|---|
| Apps sobre plugins | Plugins deprecados en Saleor, Apps son el futuro | 2026-04-16 |
| Dashboard sin fork | Evitar deuda de mantenimiento, extensión vía iframes | 2026-04-16 |
| Transactions API (no Payments API legacy) | Saleor recomienda Transactions API para integraciones nuevas | 2026-04-16 |
| COP sin decimales (`decimal_places=0`) | El peso colombiano no usa decimales en cobros | 2026-04-16 |
| Tokens JWT en cookies httpOnly (no localStorage) | Seguridad XSS | 2026-04-16 |
| UpstashRedisAPL o PostgresAPL (no FileAPL) | Filesystem de Railway no persiste entre deploys | 2026-04-16 |
| Apps via manifest usan JWS/RS256, no HMAC | Saleor no asigna `secretKey` a webhooks registrados desde manifest — firma con su RSA privada | 2026-04-26 |
| `@licona/webhook-utils` para verificación JWS | Paquete compartido en `packages/` reutilizable por todas las Apps del monorepo | 2026-04-26 |
| Wompi como pasarela primaria | Cubre más métodos colombianos (PSE, Nequi, Daviplata, efectivo) | 2026-04-16 |
| Selector de pasarelas dinámico (sin hardcodeo) | `availablePaymentGateways` de Saleor — instalar/desinstalar apps en Dashboard sin tocar código del storefront | 2026-04-27 |
| EnvAPL en lugar de UpstashAPL | Un solo tenant (nuestra instancia Saleor) — token en variable de entorno Railway, sin costo extra | 2026-04-27 |
| Fastify para todas las apps del monorepo | Consistencia con app-envios, builds más simples, control total sobre JWS verification | 2026-04-27 |

---

## Riesgos Activos

| Riesgo | Impacto | Mitigación |
|---|---|---|
| Saleor depreca API usada | Alto | Suscribirse a changelog, tests de contrato |
| Fork queda atrás del upstream | Alto | Workflow semanal de sync (GitHub Actions) |
| Pasarela CO sin SDK oficial | Medio | Cliente HTTP propio + tests sandbox |
| Railway sube precios | Medio | Docker puro, arquitectura portable |
