# Fase 5 — Pulido y Go-Live

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Storefront con Lighthouse ≥ 90 en mobile para home/PLP/PDP, pruebas de carga pasadas, accesibilidad WCAG 2.2 AA, checklist de go-live completado, y lanzamiento con tráfico real.

**Architecture:** Optimizaciones de rendimiento en Nuxt (fonts preload, CLS reduction, lazy hydration), rate limiting en middleware Nuxt, monitoreo con Sentry + OTel, pruebas k6 contra staging.

**Tech Stack:** Nuxt 4, Playwright (E2E), k6 (carga), Lighthouse CI, Sentry, axe-core (accesibilidad), Railway.

**Estado:** 🔲 Pendiente | Requiere: Fase 4 completada

---

## Mapa de archivos

```
licona-storefront/ (modificaciones)
├── app/
│   └── middleware/
│       └── rate-limit.ts           # Rate limiting en mutations del storefront
├── server/
│   └── plugins/
│       └── sentry.ts               # Inicializar Sentry en Nitro
├── tests/
│   └── e2e/
│       ├── checkout-wompi.spec.ts  # Flujo completo con Playwright
│       └── plp-pdp.spec.ts         # Navegación básica
├── k6/
│   └── load-test.js                # Script de carga con k6
└── .lighthouserc.json              # Configuración de Lighthouse CI

licona-saleor/ (modificaciones)
└── saleor/
    └── settings.py                 # OTel config (si no está ya)
```

---

## Task 1: Optimizaciones de rendimiento en Nuxt

**Files:**
- Modify: `nuxt.config.ts`
- Modify: `app/assets/styles/brand.css`

- [ ] **Step 1: Preload de fuentes críticas**

Agregar a `nuxt.config.ts`:

```typescript
app: {
  head: {
    link: [
      {
        rel: 'preload',
        href: '/fonts/Fraunces-Regular.woff2',
        as: 'font',
        type: 'font/woff2',
        crossorigin: 'anonymous',
      },
      {
        rel: 'preload',
        href: '/fonts/Satoshi-Regular.woff2',
        as: 'font',
        type: 'font/woff2',
        crossorigin: 'anonymous',
      },
    ],
  },
},
```

- [ ] **Step 2: Generar imagen de ruido en build**

El overlay `body::before` con `noise.png` debe ser un PNG optimizado de 200×200px a 8% opacidad. Generar con:

```bash
# Instalar sharp-cli si no está
npx sharp-cli --input noise-source.png --output public/noise.png --resize 200 200
```

O usar cualquier generador de ruido online y comprimir el PNG resultante.

- [ ] **Step 3: Lazy hydration en ProductGrid**

Para PLP con muchos productos, diferir la hidratación de cards que están debajo del fold:

```typescript
// app/components/plp/ProductGrid.vue — agregar al script
import { defineAsyncComponent } from 'vue'

// Usar LazyProductCard para items debajo del fold
const LazyProductCard = defineAsyncComponent(() => import('./ProductCard.vue'))
```

En el template, usar `ProductCard` para los primeros 4 items y `LazyProductCard` para el resto:

```vue
<li v-for="(product, index) in products" :key="product.id">
  <ProductCard v-if="index < 4" :product="product" />
  <LazyProductCard v-else :product="product" />
</li>
```

- [ ] **Step 4: View Transitions API**

```typescript
// nuxt.config.ts — agregar
experimental: {
  viewTransition: true,
},
```

En `app/app.vue`, agregar la meta de transition:

```vue
<script setup lang="ts">
useHead({
  meta: [{ name: 'view-transition', content: 'same-origin' }],
})
</script>
```

- [ ] **Step 5: Verificar LCP en PDP**

El LCP debe ser la imagen principal del producto. Verificar que `NuxtImg` en `ProductGallery.vue` tenga `loading="eager"` y `fetchpriority="high"` para la imagen activa:

```vue
<!-- app/components/pdp/ProductGallery.vue — imagen principal -->
<NuxtImg
  :src="media[activeIndex].url"
  :alt="media[activeIndex].alt || ''"
  class="w-full h-full object-cover"
  loading="eager"
  fetchpriority="high"
  :width="800"
  :height="1067"
/>
```

- [ ] **Step 6: Commit**

```bash
git add nuxt.config.ts app/components/
git commit -m "perf: preload fonts, lazy hydration for ProductGrid, view transitions"
```

---

## Task 2: Headers de seguridad en Nuxt

**Files:**
- Modify: `nuxt.config.ts`

- [ ] **Step 1: Agregar headers via `nitro.routeRules`**

```typescript
// nuxt.config.ts — dentro de nitro
headers: {
  'X-Frame-Options': 'DENY',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  'Content-Security-Policy': [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline'",      // 'unsafe-inline' necesario para Nuxt; ajustar con nonces en producción
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: https://media.licona-store.com",
    "font-src 'self'",
    "connect-src 'self' https://api.licona-store.com",
    "frame-ancestors 'none'",
  ].join('; '),
},
```

- [ ] **Step 2: Commit**

```bash
git add nuxt.config.ts
git commit -m "security: add HTTP security headers via Nitro routeRules"
```

---

## Task 3: Rate limiting en el storefront

**Files:**
- Create: `app/middleware/rate-limit.ts`

- [ ] **Step 1: Crear el middleware**

```typescript
// server/middleware/rate-limit.ts
// Nota: este middleware corre en el servidor Nitro, no en el cliente
import { defineEventHandler, getRequestIP, setResponseStatus } from 'h3'

const requestCounts = new Map<string, { count: number; resetAt: number }>()
const WINDOW_MS = 60_000   // 1 minuto
const MAX_REQUESTS = 60    // máximo por IP por ventana

export default defineEventHandler((event) => {
  // Solo limitar endpoints de mutación
  if (!event.path?.includes('/graphql')) return

  const body = event.node?.req?.method
  if (body !== 'POST') return

  const ip = getRequestIP(event) ?? 'unknown'
  const now = Date.now()
  const record = requestCounts.get(ip)

  if (!record || record.resetAt < now) {
    requestCounts.set(ip, { count: 1, resetAt: now + WINDOW_MS })
    return
  }

  record.count++
  if (record.count > MAX_REQUESTS) {
    setResponseStatus(event, 429)
    return { error: 'Too many requests. Please try again in a minute.' }
  }
})
```

- [ ] **Step 2: Commit**

```bash
git add server/middleware/rate-limit.ts
git commit -m "security: add rate limiting middleware (60 req/min per IP)"
```

---

## Task 4: Configurar Sentry

**Files:**
- Create: `app/plugins/sentry.client.ts`
- Create: `server/plugins/sentry.ts`

- [ ] **Step 1: Instalar Sentry**

```bash
npm install @sentry/nuxt @sentry/node
```

- [ ] **Step 2: Plugin cliente**

```typescript
// app/plugins/sentry.client.ts
import * as Sentry from '@sentry/nuxt'

export default defineNuxtPlugin(() => {
  Sentry.init({
    dsn: useRuntimeConfig().public.sentryDsn,
    environment: process.env.NODE_ENV,
    tracesSampleRate: 0.1,
    replaysSessionSampleRate: 0.0,
    replaysOnErrorSampleRate: 1.0,
  })
})
```

- [ ] **Step 3: Plugin servidor**

```typescript
// server/plugins/sentry.ts
import * as Sentry from '@sentry/node'

export default defineNitroPlugin(() => {
  Sentry.init({
    dsn: process.env.SENTRY_DSN,
    environment: process.env.NODE_ENV,
    tracesSampleRate: 0.1,
  })
})
```

- [ ] **Step 4: Agregar DSN a `nuxt.config.ts`**

```typescript
runtimeConfig: {
  sentryDsn: process.env.SENTRY_DSN,
  public: {
    sentryDsn: process.env.NUXT_PUBLIC_SENTRY_DSN,
    // ... resto
  },
},
```

- [ ] **Step 5: Agregar variable en Railway**

```
SENTRY_DSN=https://...@sentry.io/...
NUXT_PUBLIC_SENTRY_DSN=https://...@sentry.io/...
```

- [ ] **Step 6: Commit**

```bash
git add app/plugins/sentry.client.ts server/plugins/sentry.ts
git commit -m "feat: add Sentry error monitoring to storefront"
```

---

## Task 5: Tests E2E con Playwright

**Files:**
- Create: `tests/e2e/plp-pdp.spec.ts`
- Create: `tests/e2e/checkout-wompi.spec.ts`
- Create: `playwright.config.ts`

- [ ] **Step 1: Instalar Playwright**

```bash
npm install -D @playwright/test
npx playwright install chromium
```

- [ ] **Step 2: `playwright.config.ts`**

```typescript
import { defineConfig, devices } from '@playwright/test'

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: false,
  retries: 1,
  workers: 1,
  reporter: 'html',
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL || 'http://localhost:3000',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'mobile', use: { ...devices['Pixel 5'] } },
  ],
})
```

- [ ] **Step 3: Test de navegación PLP/PDP**

```typescript
// tests/e2e/plp-pdp.spec.ts
import { test, expect } from '@playwright/test'

test.describe('Catálogo', () => {
  test('home carga correctamente', async ({ page }) => {
    await page.goto('/')
    await expect(page.locator('h1')).toBeVisible()
    await expect(page.locator('text=Ver colección')).toBeVisible()
  })

  test('PLP muestra productos', async ({ page }) => {
    // Reemplazar <slug> con una categoría que exista en el catálogo de staging
    await page.goto('/categoria/ropa')
    await expect(page.locator('article').first()).toBeVisible({ timeout: 10000 })
  })

  test('PDP muestra precio en COP', async ({ page }) => {
    await page.goto('/categoria/ropa')
    const firstProduct = page.locator('article a').first()
    await firstProduct.click()
    await expect(page.locator('text=COP').or(page.locator('text=$'))).toBeVisible({ timeout: 10000 })
    await expect(page.locator('button:has-text("Agregar al carrito")')).toBeVisible()
  })
})
```

- [ ] **Step 4: Test de checkout con Wompi sandbox**

```typescript
// tests/e2e/checkout-wompi.spec.ts
import { test, expect } from '@playwright/test'

// Este test requiere que el entorno de staging tenga sandbox activo y catálogo de prueba.
test.describe('Checkout Wompi sandbox', () => {
  test('flujo completo de compra', async ({ page }) => {
    // 1. Ir al PDP y agregar al carrito
    await page.goto('/producto/producto-de-prueba')
    await page.locator('button:has-text("Agregar al carrito")').click()
    await expect(page.locator('text=1').first()).toBeVisible()  // badge del carrito

    // 2. Ir al checkout
    await page.goto('/checkout/direccion')
    await page.fill('[placeholder="Correo electrónico"]', 'test@sandbox.com')
    await page.fill('[placeholder="Nombre"]', 'Juan')
    await page.fill('[placeholder="Apellido"]', 'Prueba')
    await page.fill('[placeholder*="Dirección"]', 'Cra 15 # 93-47')
    await page.fill('[placeholder="Ciudad"]', 'Bogotá')
    await page.fill('[placeholder="Código postal"]', '110111')
    await page.fill('[placeholder="Departamento"]', 'Cundinamarca')
    await page.locator('button:has-text("Continuar al envío")').click()

    // 3. Seleccionar método de envío
    await expect(page.locator('text=Servientrega')).toBeVisible({ timeout: 5000 })
    await page.locator('label:has-text("Servientrega")').click()
    await page.locator('button:has-text("Continuar al resumen")').click()

    // 4. Seleccionar Wompi y pagar
    await expect(page.locator('text=Pago')).toBeVisible()
    await page.locator('label:has-text("Wompi")').click()
    await page.locator('button:has-text("Pagar")').click()

    // 5. Verificar redirección a Wompi sandbox
    await expect(page).toHaveURL(/sandbox\.wompi\.co/, { timeout: 10000 })
  })
})
```

- [ ] **Step 5: Ejecutar tests en staging**

```bash
PLAYWRIGHT_BASE_URL=https://staging.licona-store.com npx playwright test tests/e2e/plp-pdp.spec.ts
```

Salida esperada: 3 tests passed.

- [ ] **Step 6: Commit**

```bash
git add tests/e2e/ playwright.config.ts
git commit -m "test: add Playwright E2E tests for catalog navigation and Wompi checkout"
```

---

## Task 6: Prueba de carga con k6

**Files:**
- Create: `k6/load-test.js`

- [ ] **Step 1: Instalar k6**

```bash
# macOS
brew install k6
```

- [ ] **Step 2: Crear el script**

```javascript
// k6/load-test.js
import http from 'k6/http'
import { sleep, check } from 'k6'

export const options = {
  scenarios: {
    browsing: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '1m', target: 20 },   // ramp-up a 20 usuarios
        { duration: '3m', target: 20 },   // mantener 20
        { duration: '1m', target: 0 },    // ramp-down
      ],
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<2000'],   // 95% de requests < 2s
    http_req_failed: ['rate<0.01'],      // menos del 1% de errores
  },
}

const BASE_URL = __ENV.BASE_URL || 'https://staging.licona-store.com'
const GRAPHQL_URL = __ENV.GRAPHQL_URL || 'https://staging-api.licona-store.com/graphql/'

const PAGES = [
  '/',
  '/categoria/ropa',
  '/producto/producto-de-prueba',
]

const PRODUCT_LIST_QUERY = JSON.stringify({
  query: `query {
    products(channel: "default-channel", first: 24) {
      edges { node { id name slug } }
    }
  }`,
})

export default function () {
  // Simular navegación
  const page = PAGES[Math.floor(Math.random() * PAGES.length)]
  const res = http.get(`${BASE_URL}${page}`)

  check(res, {
    'status 200': (r) => r.status === 200,
    'no error en body': (r) => !r.body.includes('"errors":[{'),
  })

  // Simular query GraphQL
  const gqlRes = http.post(GRAPHQL_URL, PRODUCT_LIST_QUERY, {
    headers: { 'Content-Type': 'application/json' },
  })

  check(gqlRes, {
    'GraphQL 200': (r) => r.status === 200,
    'sin errores GraphQL': (r) => {
      try {
        return !JSON.parse(r.body).errors
      } catch {
        return false
      }
    },
  })

  sleep(1 + Math.random() * 2)  // 1-3 segundos entre requests
}
```

- [ ] **Step 3: Ejecutar en staging**

```bash
BASE_URL=https://staging.licona-store.com \
GRAPHQL_URL=https://staging-api.licona-store.com/graphql/ \
k6 run k6/load-test.js
```

Salida esperada: todos los thresholds verdes. Si `p(95)` supera 2s, investigar queries N+1 o índices de Postgres faltantes.

- [ ] **Step 4: Commit**

```bash
git add k6/
git commit -m "test: add k6 load test script"
```

---

## Task 7: Lighthouse CI

**Files:**
- Create: `.lighthouserc.json`
- Modify: `.github/workflows/` (en `licona-storefront`)

- [ ] **Step 1: Crear `.lighthouserc.json`**

```json
{
  "ci": {
    "collect": {
      "url": [
        "http://localhost:3000/",
        "http://localhost:3000/categoria/ropa",
        "http://localhost:3000/producto/producto-de-prueba"
      ],
      "startServerCommand": "npm run preview",
      "numberOfRuns": 3
    },
    "assert": {
      "preset": "lighthouse:recommended",
      "assertions": {
        "categories:performance": ["error", { "minScore": 0.9 }],
        "categories:accessibility": ["error", { "minScore": 0.9 }],
        "categories:best-practices": ["error", { "minScore": 0.9 }],
        "categories:seo": ["error", { "minScore": 0.9 }]
      }
    },
    "upload": {
      "target": "temporary-public-storage"
    }
  }
}
```

- [ ] **Step 2: Agregar workflow de Lighthouse CI**

```yaml
# .github/workflows/lighthouse.yml
name: Lighthouse CI

on:
  pull_request:
    branches: [main]

jobs:
  lighthouse:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22' }
      - run: npm ci
      - run: npm run build
      - run: npx @lhci/cli@0.13.x autorun
        env:
          LHCI_GITHUB_APP_TOKEN: ${{ secrets.LHCI_GITHUB_APP_TOKEN }}
          NUXT_PUBLIC_SALEOR_API_URL: ${{ secrets.STAGING_SALEOR_API_URL }}
```

- [ ] **Step 3: Commit**

```bash
git add .lighthouserc.json .github/workflows/lighthouse.yml
git commit -m "ci: add Lighthouse CI with ≥90 score thresholds"
```

---

## Task 8: Auditoría de accesibilidad

**Files:**
- Modify: `tests/e2e/plp-pdp.spec.ts`

- [ ] **Step 1: Instalar axe-playwright**

```bash
npm install -D @axe-core/playwright
```

- [ ] **Step 2: Agregar checks de accesibilidad a los tests E2E**

```typescript
// tests/e2e/plp-pdp.spec.ts — agregar al final
import AxeBuilder from '@axe-core/playwright'

test('home sin violaciones WCAG 2.2 AA', async ({ page }) => {
  await page.goto('/')
  await page.waitForLoadState('networkidle')
  const results = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag22aa'])
    .analyze()
  expect(results.violations).toEqual([])
})

test('PDP sin violaciones WCAG 2.2 AA', async ({ page }) => {
  await page.goto('/producto/producto-de-prueba')
  await page.waitForLoadState('networkidle')
  const results = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag22aa'])
    .analyze()
  expect(results.violations).toEqual([])
})
```

- [ ] **Step 3: Ejecutar y corregir violaciones**

```bash
npx playwright test tests/e2e/plp-pdp.spec.ts --grep "WCAG"
```

Revisar `results.violations` y corregir:
- Imágenes sin `alt`: agregar `alt` descriptivos en todos los `NuxtImg`.
- Contraste insuficiente: verificar color `muted` (`#6B6561`) contra fondo `cream` (`#F4EFE6`) — ratio mínimo 4.5:1 para texto normal. Si no pasa, oscurecer a `#5A5250`.
- Botones sin texto accesible: agregar `aria-label` a botones de solo icono (×, +, −).
- Formularios sin `<label>`: asociar cada `<input>` con un `<label>` o `aria-label`.

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/ app/components/
git commit -m "a11y: fix WCAG 2.2 AA violations (contrast, labels, alt text)"
```

---

## Task 9: Checklist de go-live

Completar cada ítem antes del lanzamiento. Marcar en `STATUS.md`.

- [ ] **Infraestructura**
  - [ ] Dominios `licona-store.com`, `api.licona-store.com`, `dashboard.licona-store.com` con SSL activo.
  - [ ] Variables de entorno de producción verificadas (sin valores de sandbox).
  - [ ] `WOMPI_SANDBOX=false`, llaves de producción de Wompi activas.
  - [ ] Backups automáticos de Postgres corriendo (verificar en Railway dashboard).
  - [ ] Snapshot manual de la DB antes del go-live.

- [ ] **Pasarelas de pago**
  - [ ] Webhooks de Wompi apuntando a `https://wompi.apps.licona-store.com/api/webhooks/wompi-incoming`.
  - [ ] Webhooks de PayU apuntando a `https://payu.apps.licona-store.com/api/webhooks/payu-incoming`.
  - [ ] Transacción de prueba real de COP 1.000 con tarjeta de producción por cada pasarela.

- [ ] **Monitoreo**
  - [ ] Sentry recibiendo errores de storefront y Apps.
  - [ ] Uptime monitor configurado (UptimeRobot o Better Uptime) para `licona-store.com` y `api.licona-store.com`.
  - [ ] Alertas de Railway configuradas (CPU > 80%, memoria > 80%).

- [ ] **Legales**
  - [ ] Términos y condiciones publicados en `/terminos`.
  - [ ] Política de privacidad (Ley 1581/2012) publicada en `/privacidad`.
  - [ ] Política de devoluciones publicada en `/devoluciones`.
  - [ ] Banner de cookies con consentimiento.

- [ ] **Calidad**
  - [ ] Lighthouse ≥ 90 en producción para home, PLP y PDP en mobile.
  - [ ] `npx playwright test` verde en staging.
  - [ ] k6 load test verde en staging.
  - [ ] Flujo completo end-to-end probado manualmente: home → PDP → carrito → dirección → envío → pago Wompi → orden confirmada → factura emitida.

- [ ] **Rollback**
  - [ ] Plan de rollback documentado: URL del último deploy estable en Railway, cómo hacer rollback con `railway redeploy --deployment <id>`.

---

## Task 10: Soft launch y apertura

- [ ] **Step 1: Deploy a producción con tráfico limitado**

En Railway, habilitar el dominio de producción pero no anunciarlo públicamente. Compartir la URL solo con el equipo para validación final.

- [ ] **Step 2: Monitorear por 24h**

Revisar:
- Logs de `saleor-api`: no debe haber errores 500.
- Logs de `app-wompi`: webhooks procesados correctamente.
- Sentry: cero errores nuevos críticos.
- Railway CPU/memoria: dentro de límites normales.

- [ ] **Step 3: Apertura total**

Configurar DNS `www.licona-store.com` → apuntar al servicio de storefront en Railway. Anunciar el lanzamiento.

- [ ] **Step 4: Actualizar `STATUS.md`**

```markdown
| 5 | Pulido y Go-live | ✅ Completada | 12-13 | [Fase 5](2026-04-16-fase5-golive.md) |
```

Agregar al log de sesiones:
```markdown
| 2026-04-XX | Go-live | Todas las fases completadas. Tienda en línea activa. | Monitoreo continuo |
```

---

## Verificación final del proyecto

- [ ] Una orden completa con Wompi tarjeta, PSE y Nequi en producción.
- [ ] Reembolso parcial desde el dashboard en producción.
- [ ] Fork de Saleor actualizable sin downtime (probar en staging con la minor siguiente).
- [ ] Dashboard oficial muestra Apps instaladas con sus extensiones.
- [ ] Lighthouse ≥ 90 en mobile para home, PLP y PDP.
- [ ] Fallo de `app-wompi` (stop en Railway) → storefront y core siguen funcionando.
- [ ] Diseño distintivo, no de plantilla genérica — revisión visual final.
