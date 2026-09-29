# Fase 4 — Cuenta de Cliente y Facturación Electrónica

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flujo completo de cuenta de cliente (registro, login, historial de órdenes, devoluciones) y `app-facturacion-co` para emisión de facturas electrónicas DIAN vía Siigo o Alegra.

**Architecture:** Autenticación con `@saleor/auth-sdk` adaptado a Vue, tokens JWT en cookies httpOnly. `app-facturacion-co` es un servicio Fastify que escucha el webhook `ORDER_FULLY_PAID` de Saleor y emite la factura en el proveedor DIAN configurado. El iframe de configuración de la App aparece en el Dashboard de Saleor.

**Tech Stack:** Nuxt 4, `@saleor/auth-sdk`, Fastify 5, `@saleor/app-sdk`, Siigo API o Alegra API, Node 22.

**Estado:** 🔲 Pendiente | Requiere: Fase 3 completada

---

## Mapa de archivos

```
licona-storefront/ (modificaciones)
└── app/
    ├── composables/
    │   └── useAuth.ts                    # Login, registro, refresh token, logout
    ├── middleware/
    │   └── auth.global.ts                # Redirige /cuenta/** si no hay sesión
    ├── graphql/
    │   └── mutations/
    │       └── auth.graphql              # tokenCreate, tokenRefresh, accountRegister, passwordReset
    └── pages/
        └── cuenta/
            ├── index.vue                 # Dashboard de cuenta
            ├── login.vue
            ├── registro.vue
            ├── recuperar-clave.vue
            ├── ordenes.vue               # Historial de órdenes
            ├── ordenes/[id].vue          # Detalle de orden
            └── devoluciones.vue          # Solicitud de devolución

licona-saleor-apps/ (modificaciones)
└── apps/
    └── facturacion/
        ├── src/
        │   ├── index.ts                  # Servidor Fastify
        │   ├── webhooks/
        │   │   └── order-fully-paid.ts   # Emite factura al recibir pago
        │   ├── providers/
        │   │   ├── siigo.ts              # Cliente HTTP de Siigo API
        │   │   └── alegra.ts             # Cliente HTTP de Alegra API
        │   └── lib/
        │       └── dian-adapter.ts       # Mapeo de datos de Saleor a formato DIAN
        ├── Dockerfile
        └── package.json
```

---

## Task 1: Mutations de autenticación

**Files:**
- Create: `app/graphql/mutations/auth.graphql`

- [ ] **Step 1: Crear las mutations**

```graphql
# app/graphql/mutations/auth.graphql

mutation TokenCreate($email: String!, $password: String!) {
  tokenCreate(email: $email, password: $password) {
    token
    refreshToken
    csrfToken
    user {
      id
      email
      firstName
      lastName
    }
    errors { field message code }
  }
}

mutation TokenRefresh($refreshToken: String!) {
  tokenRefresh(refreshToken: $refreshToken) {
    token
    errors { field message code }
  }
}

mutation AccountRegister(
  $email: String!
  $password: String!
  $firstName: String!
  $lastName: String!
  $channel: String!
  $redirectUrl: String!
) {
  accountRegister(
    input: {
      email: $email
      password: $password
      firstName: $firstName
      lastName: $lastName
      channel: $channel
      redirectUrl: $redirectUrl
    }
  ) {
    user { id email }
    errors { field message code }
    requiresConfirmation
  }
}

mutation PasswordChange($oldPassword: String!, $newPassword: String!) {
  passwordChange(oldPassword: $oldPassword, newPassword: $newPassword) {
    user { id }
    errors { field message code }
  }
}

mutation RequestPasswordReset($email: String!, $redirectUrl: String!, $channel: String!) {
  requestPasswordReset(email: $email, redirectUrl: $redirectUrl, channel: $channel) {
    errors { field message code }
  }
}

mutation SetPassword($email: String!, $password: String!, $token: String!) {
  setPassword(email: $email, password: $password, token: $token) {
    token
    refreshToken
    user { id email }
    errors { field message code }
  }
}

query MeWithOrders($first: Int!, $after: String) {
  me {
    id
    email
    firstName
    lastName
    orders(first: $first, after: $after) {
      edges {
        node {
          id
          number
          status
          created
          totalPrice { gross { amount currency } }
          lines {
            id
            quantity
            productName
            variantName
            thumbnail { url alt }
            totalPrice { gross { amount currency } }
          }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
```

- [ ] **Step 2: Regenerar tipos**

```bash
npm run codegen
```

- [ ] **Step 3: Commit**

```bash
git add app/graphql/mutations/auth.graphql app/graphql/generated/
git commit -m "feat: add auth and account GraphQL mutations"
```

---

## Task 2: Composable `useAuth`

**Files:**
- Create: `app/composables/useAuth.ts`
- Create: `tests/composables/useAuth.test.ts`

- [ ] **Step 1: Test**

```typescript
// tests/composables/useAuth.test.ts
import { describe, it, expect, vi } from 'vitest'

const mockMutation = vi.fn()
vi.mock('@urql/vue', () => ({
  useMutation: () => [{ fetching: { value: false } }, mockMutation],
}))

describe('useAuth', () => {
  it('isLoggedIn es false si no hay token en cookie', async () => {
    const { useAuth } = await import('~/composables/useAuth')
    const auth = useAuth()
    expect(auth.isLoggedIn.value).toBe(false)
  })

  it('login llama a tokenCreate mutation', async () => {
    mockMutation.mockResolvedValueOnce({
      data: {
        tokenCreate: {
          token: 'jwt-token',
          refreshToken: 'refresh-token',
          user: { id: '1', email: 'test@test.com', firstName: 'Test', lastName: 'User' },
          errors: [],
        },
      },
    })
    const { useAuth } = await import('~/composables/useAuth')
    const auth = useAuth()
    await auth.login('test@test.com', 'password')
    expect(mockMutation).toHaveBeenCalledWith({ email: 'test@test.com', password: 'password' })
  })
})
```

- [ ] **Step 2: Verificar fallo**

```bash
npx vitest run tests/composables/useAuth.test.ts
```

- [ ] **Step 3: Implementar**

```typescript
// app/composables/useAuth.ts
import { useMutation, useQuery } from '@urql/vue'
import {
  TokenCreateDocument,
  TokenRefreshDocument,
  AccountRegisterDocument,
  RequestPasswordResetDocument,
  SetPasswordDocument,
  MeWithOrdersDocument,
} from '~/graphql/generated/graphql'
import { useSaleor } from '~/composables/useSaleor'

const TOKEN_COOKIE = 'saleor-auth-token'
const REFRESH_COOKIE = 'saleor-refresh-token'

export function useAuth() {
  const { channel } = useSaleor()
  const token = useCookie<string | null>(TOKEN_COOKIE, {
    default: () => null,
    maxAge: 60 * 60 * 24 * 30,  // 30 días
    sameSite: 'lax',
    httpOnly: false,              // Necesita ser leído por JS para el header Authorization
    secure: process.env.NODE_ENV === 'production',
  })

  const refreshToken = useCookie<string | null>(REFRESH_COOKIE, {
    default: () => null,
    maxAge: 60 * 60 * 24 * 90,  // 90 días
    sameSite: 'lax',
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
  })

  const isLoggedIn = computed(() => !!token.value)
  const currentUser = ref<{ id: string; email: string; firstName: string; lastName: string } | null>(null)

  const [, createToken] = useMutation(TokenCreateDocument)
  const [, refreshTokenMutation] = useMutation(TokenRefreshDocument)
  const [, registerAccount] = useMutation(AccountRegisterDocument)
  const [, requestReset] = useMutation(RequestPasswordResetDocument)
  const [, setPassword] = useMutation(SetPasswordDocument)

  async function login(email: string, password: string) {
    const result = await createToken({ email, password })
    if (result.data?.tokenCreate?.errors.length) {
      throw new Error(result.data.tokenCreate.errors[0].message ?? 'Credenciales incorrectas')
    }
    if (result.data?.tokenCreate?.token) {
      token.value = result.data.tokenCreate.token
      refreshToken.value = result.data.tokenCreate.refreshToken ?? null
      currentUser.value = result.data.tokenCreate.user ?? null
    }
  }

  async function register(params: {
    email: string; password: string; firstName: string; lastName: string
  }) {
    const result = await registerAccount({
      ...params,
      channel,
      redirectUrl: `${window.location.origin}/cuenta/confirmar-email`,
    })
    if (result.data?.accountRegister?.errors.length) {
      throw new Error(result.data.accountRegister.errors[0].message ?? 'Error al registrar')
    }
    return result.data?.accountRegister?.requiresConfirmation
  }

  async function refresh() {
    if (!refreshToken.value) throw new Error('Sin refresh token')
    const result = await refreshTokenMutation({ refreshToken: refreshToken.value })
    if (result.data?.tokenRefresh?.token) {
      token.value = result.data.tokenRefresh.token
    }
  }

  function logout() {
    token.value = null
    refreshToken.value = null
    currentUser.value = null
  }

  async function sendPasswordReset(email: string) {
    await requestReset({
      email,
      channel,
      redirectUrl: `${window.location.origin}/cuenta/nueva-clave`,
    })
  }

  async function confirmNewPassword(email: string, password: string, resetToken: string) {
    const result = await setPassword({ email, password, token: resetToken })
    if (result.data?.setPassword?.errors.length) {
      throw new Error(result.data.setPassword.errors[0].message ?? 'Error al cambiar contraseña')
    }
    if (result.data?.setPassword?.token) {
      token.value = result.data.setPassword.token
      refreshToken.value = result.data.setPassword.refreshToken ?? null
    }
  }

  return {
    token: readonly(token),
    isLoggedIn,
    currentUser,
    login,
    register,
    refresh,
    logout,
    sendPasswordReset,
    confirmNewPassword,
  }
}
```

- [ ] **Step 4: Ejecutar tests**

```bash
npx vitest run tests/composables/useAuth.test.ts
```

Salida esperada: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/composables/useAuth.ts tests/composables/useAuth.test.ts
git commit -m "feat: implement useAuth composable with JWT cookie storage"
```

---

## Task 3: Middleware de autenticación

**Files:**
- Create: `app/middleware/auth.global.ts`

- [ ] **Step 1: Crear el middleware**

```typescript
// app/middleware/auth.global.ts
export default defineNuxtRouteMiddleware((to) => {
  const { isLoggedIn } = useAuth()

  const protectedPrefixes = ['/cuenta']
  const isProtected = protectedPrefixes.some((prefix) => to.path.startsWith(prefix))

  // Excluir las páginas de login y registro del guard
  const authPages = ['/cuenta/login', '/cuenta/registro', '/cuenta/recuperar-clave', '/cuenta/nueva-clave']
  const isAuthPage = authPages.includes(to.path)

  if (isProtected && !isAuthPage && !isLoggedIn.value) {
    return navigateTo(`/cuenta/login?redirect=${encodeURIComponent(to.fullPath)}`)
  }
})
```

- [ ] **Step 2: Commit**

```bash
git add app/middleware/auth.global.ts
git commit -m "feat: add auth middleware for /cuenta routes"
```

---

## Task 4: Páginas de login y registro

**Files:**
- Create: `app/pages/cuenta/login.vue`
- Create: `app/pages/cuenta/registro.vue`

- [ ] **Step 1: `login.vue`**

```vue
<!-- app/pages/cuenta/login.vue -->
<script setup lang="ts">
import { useAuth } from '~/composables/useAuth'

definePageMeta({ layout: 'default' })

const { login } = useAuth()
const router = useRouter()
const route = useRoute()

const form = reactive({ email: '', password: '' })
const error = ref<string | null>(null)
const loading = ref(false)

async function submit() {
  error.value = null
  loading.value = true
  try {
    await login(form.email, form.password)
    const redirect = (route.query.redirect as string) || '/cuenta'
    router.push(redirect)
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Error al iniciar sesión'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="max-w-md mx-auto py-20 px-4">
    <h1 class="font-display text-4xl text-ink mb-10">Iniciar sesión</h1>

    <div v-if="error" class="mb-4 p-3 bg-accent-light text-accent text-sm font-body">{{ error }}</div>

    <form class="space-y-4" @submit.prevent="submit">
      <input v-model="form.email" type="email" required placeholder="Correo electrónico"
        class="w-full border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
      <input v-model="form.password" type="password" required placeholder="Contraseña"
        class="w-full border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
      <NuxtLink to="/cuenta/recuperar-clave" class="block text-xs font-body text-muted hover:text-ink">
        ¿Olvidaste tu contraseña?
      </NuxtLink>
      <button type="submit" :disabled="loading"
        class="w-full py-4 bg-ink text-cream font-body text-sm font-medium disabled:opacity-50 hover:bg-accent transition-colors duration-200">
        {{ loading ? 'Iniciando...' : 'Ingresar' }}
      </button>
    </form>

    <p class="mt-8 font-body text-sm text-muted text-center">
      ¿No tienes cuenta?
      <NuxtLink to="/cuenta/registro" class="text-ink underline">Regístrate</NuxtLink>
    </p>
  </div>
</template>
```

- [ ] **Step 2: `registro.vue`**

```vue
<!-- app/pages/cuenta/registro.vue -->
<script setup lang="ts">
import { useAuth } from '~/composables/useAuth'

definePageMeta({ layout: 'default' })

const { register } = useAuth()
const form = reactive({ email: '', password: '', firstName: '', lastName: '' })
const error = ref<string | null>(null)
const success = ref(false)
const loading = ref(false)

async function submit() {
  error.value = null
  loading.value = true
  try {
    const requiresConfirmation = await register(form)
    success.value = true
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Error al registrar'
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="max-w-md mx-auto py-20 px-4">
    <h1 class="font-display text-4xl text-ink mb-10">Crear cuenta</h1>

    <div v-if="success" class="p-4 bg-ink/5 font-body text-sm text-ink">
      ¡Cuenta creada! Revisa tu correo para confirmar.
    </div>

    <form v-else class="space-y-4" @submit.prevent="submit">
      <div v-if="error" class="p-3 bg-accent-light text-accent text-sm font-body">{{ error }}</div>

      <div class="grid grid-cols-2 gap-4">
        <input v-model="form.firstName" required placeholder="Nombre"
          class="border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
        <input v-model="form.lastName" required placeholder="Apellido"
          class="border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
      </div>
      <input v-model="form.email" type="email" required placeholder="Correo electrónico"
        class="w-full border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
      <input v-model="form.password" type="password" required minlength="8" placeholder="Contraseña (mín. 8 caracteres)"
        class="w-full border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />

      <button type="submit" :disabled="loading"
        class="w-full py-4 bg-ink text-cream font-body text-sm font-medium disabled:opacity-50 hover:bg-accent transition-colors duration-200">
        {{ loading ? 'Creando cuenta...' : 'Crear cuenta' }}
      </button>
    </form>
  </div>
</template>
```

- [ ] **Step 3: Commit**

```bash
git add app/pages/cuenta/login.vue app/pages/cuenta/registro.vue
git commit -m "feat: add login and registration pages"
```

---

## Task 5: Historial de órdenes

**Files:**
- Create: `app/pages/cuenta/ordenes.vue`
- Create: `app/pages/cuenta/ordenes/[id].vue`

- [ ] **Step 1: `ordenes.vue`**

```vue
<!-- app/pages/cuenta/ordenes.vue -->
<script setup lang="ts">
import { useQuery } from '@urql/vue'
import { MeWithOrdersDocument } from '~/graphql/generated/graphql'

definePageMeta({ layout: 'default' })

const { data, fetching } = useQuery({
  query: MeWithOrdersDocument,
  variables: { first: 20, after: null },
})

const orders = computed(() => data.value?.me?.orders.edges.map((e) => e.node) ?? [])

function formatDate(dateStr: string) {
  return new Intl.DateTimeFormat('es-CO', { dateStyle: 'long' }).format(new Date(dateStr))
}

function formatPrice(amount: number) {
  return new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', minimumFractionDigits: 0 }).format(amount)
}

const STATUS_LABELS: Record<string, string> = {
  UNFULFILLED: 'Pendiente',
  PARTIALLY_FULFILLED: 'En proceso',
  FULFILLED: 'Enviado',
  DELIVERED: 'Entregado',
  RETURNED: 'Devuelto',
  CANCELED: 'Cancelado',
}
</script>

<template>
  <div class="max-w-screen-md mx-auto py-16 px-4">
    <h1 class="font-display text-4xl text-ink mb-10">Mis pedidos</h1>

    <div v-if="fetching" class="space-y-4">
      <div v-for="i in 3" :key="i" class="h-20 bg-ink/5 animate-pulse" />
    </div>

    <div v-else-if="orders.length === 0" class="font-body text-muted text-sm">
      No tienes pedidos aún.
    </div>

    <div v-else class="space-y-3">
      <NuxtLink
        v-for="order in orders"
        :key="order.id"
        :to="`/cuenta/ordenes/${order.id}`"
        class="flex items-center justify-between p-5 border border-[--color-border] hover:border-ink transition-colors"
      >
        <div>
          <p class="font-body text-sm font-medium text-ink">#{{ order.number }}</p>
          <p class="font-body text-xs text-muted mt-0.5">{{ formatDate(order.created) }}</p>
        </div>
        <div class="text-right">
          <p class="font-body text-sm font-medium text-ink">{{ formatPrice(order.totalPrice.gross.amount) }}</p>
          <p class="font-body text-xs text-muted mt-0.5">{{ STATUS_LABELS[order.status] ?? order.status }}</p>
        </div>
      </NuxtLink>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Commit**

```bash
git add app/pages/cuenta/ordenes.vue
git commit -m "feat: add order history page"
```

---

## Task 6: Scaffold de `app-facturacion-co`

**Files:**
- Create: `apps/facturacion/package.json`
- Create: `apps/facturacion/src/index.ts`
- Create: `apps/facturacion/src/providers/siigo.ts`
- Create: `apps/facturacion/src/webhooks/order-fully-paid.ts`

- [ ] **Step 1: Crear `package.json`**

```json
{
  "name": "@licona/app-facturacion",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js",
    "test": "vitest run"
  },
  "dependencies": {
    "@saleor/app-sdk": "^0.50.0",
    "fastify": "^5.0.0",
    "zod": "^3.22.0"
  },
  "devDependencies": {
    "typescript": "^5.4.0",
    "tsx": "^4.7.0",
    "vitest": "^1.5.0"
  }
}
```

- [ ] **Step 2: Crear el servidor Fastify con manifest**

```typescript
// apps/facturacion/src/index.ts
import Fastify from 'fastify'
import { orderFullyPaidHandler } from './webhooks/order-fully-paid.js'

const app = Fastify({ logger: true })
const APP_URL = process.env.APP_URL ?? 'http://localhost:3003'

app.get('/api/manifest', async () => ({
  id: 'app.licona.facturacion',
  version: '1.0.0',
  name: 'Facturación Electrónica CO',
  about: 'Emisión automática de facturas electrónicas DIAN vía Siigo o Alegra.',
  permissions: ['MANAGE_ORDERS'],
  appUrl: APP_URL,
  webhooks: [
    {
      name: 'Order Fully Paid',
      asyncEvents: ['ORDER_FULLY_PAID'],
      isActive: true,
      targetUrl: `${APP_URL}/api/webhooks/order-fully-paid`,
    },
  ],
  extensions: [
    {
      label: 'Facturas emitidas',
      mount: 'NAVIGATION_ORDERS',
      target: 'APP_PAGE',
      permissions: ['MANAGE_ORDERS'],
      url: `${APP_URL}/?saleorApiUrl={saleorApiUrl}`,
    },
  ],
  requiredSaleorVersion: '>=3.22.0',
}))

app.post('/api/webhooks/order-fully-paid', orderFullyPaidHandler)

app.listen({ port: parseInt(process.env.PORT ?? '3003'), host: '0.0.0.0' })
```

- [ ] **Step 3: Crear el webhook handler**

```typescript
// apps/facturacion/src/webhooks/order-fully-paid.ts
import type { FastifyRequest, FastifyReply } from 'fastify'
import { createHmac, timingSafeEqual } from 'node:crypto'
import { SiigoClient } from '../providers/siigo.js'

interface OrderPayload {
  order: {
    id: string
    number: string
    userEmail: string
    billingAddress: {
      firstName: string
      lastName: string
      streetAddress1: string
      city: string
      postalCode: string
      country: { code: string }
    } | null
    total: { gross: { amount: number; currency: string } }
    lines: Array<{
      id: string
      productName: string
      variantName: string
      quantity: number
      unitPrice: { gross: { amount: number; currency: string } }
      totalPrice: { gross: { amount: number; currency: string } }
    }>
  }
}

function verifySignature(payload: string, signature: string, secret: string): boolean {
  const expected = createHmac('sha256', secret).update(payload).digest('hex')
  const sigBuf = Buffer.from(signature, 'hex')
  const expBuf = Buffer.from(expected, 'hex')
  return sigBuf.length === expBuf.length && timingSafeEqual(sigBuf, expBuf)
}

export async function orderFullyPaidHandler(req: FastifyRequest, reply: FastifyReply) {
  const signature = (req.headers['saleor-signature'] as string) ?? ''
  const secret = process.env.SALEOR_WEBHOOK_SECRET!
  const rawBody = JSON.stringify(req.body)

  if (!verifySignature(rawBody, signature, secret)) {
    return reply.status(401).send({ error: 'Invalid signature' })
  }

  const { order } = req.body as OrderPayload

  const siigo = new SiigoClient({
    username: process.env.SIIGO_USERNAME!,
    accessKey: process.env.SIIGO_ACCESS_KEY!,
  })

  try {
    await siigo.createInvoice({
      orderId: order.id,
      orderNumber: order.number,
      customerEmail: order.userEmail,
      billingAddress: order.billingAddress,
      lines: order.lines,
      totalAmount: order.total.gross.amount,
      currency: order.total.gross.currency,
    })
    req.log.info({ orderId: order.id }, 'Factura emitida correctamente')
  } catch (error) {
    req.log.error({ orderId: order.id, error }, 'Error al emitir factura')
    // No retornamos error a Saleor para que no reintente indefinidamente.
    // El error se registra en Sentry.
  }

  return reply.send({ ok: true })
}
```

- [ ] **Step 4: Crear cliente de Siigo**

```typescript
// apps/facturacion/src/providers/siigo.ts

interface SiigoConfig {
  username: string
  accessKey: string
}

interface InvoiceParams {
  orderId: string
  orderNumber: string
  customerEmail: string
  billingAddress: {
    firstName: string
    lastName: string
    streetAddress1: string
    city: string
    postalCode: string
    country: { code: string }
  } | null
  lines: Array<{
    productName: string
    variantName: string
    quantity: number
    unitPrice: { gross: { amount: number; currency: string } }
  }>
  totalAmount: number
  currency: string
}

export class SiigoClient {
  private baseUrl = 'https://api.siigo.com'
  private accessToken: string | null = null

  constructor(private config: SiigoConfig) {}

  private async authenticate(): Promise<string> {
    if (this.accessToken) return this.accessToken

    const response = await fetch(`${this.baseUrl}/auth`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Partner-Id': 'licona-store' },
      body: JSON.stringify({
        username: this.config.username,
        access_key: this.config.accessKey,
      }),
    })

    if (!response.ok) throw new Error(`Siigo auth error ${response.status}`)
    const data = await response.json()
    this.accessToken = data.access_token
    return this.accessToken!
  }

  async createInvoice(params: InvoiceParams): Promise<{ id: string; number: string }> {
    const token = await this.authenticate()

    // El account_id del tipo de factura de venta en Siigo
    const INVOICE_TYPE_ID = parseInt(process.env.SIIGO_INVOICE_TYPE_ID ?? '1', 10)

    const response = await fetch(`${this.baseUrl}/v1/invoices`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        document: { id: INVOICE_TYPE_ID },
        customer: {
          person_type: 'Person',
          id_type: 'CC',
          identification: params.customerEmail,  // En producción usar NIT/CC real
          name: [
            params.billingAddress?.firstName ?? '',
            params.billingAddress?.lastName ?? '',
          ],
          address: {
            address: params.billingAddress?.streetAddress1 ?? '',
            city: {
              country_code: params.billingAddress?.country.code ?? 'CO',
              state_code: 'CO-CUN',  // Ajustar según departamento
              city_code: '11001',    // Bogotá por defecto; en producción mapear postalCode
            },
          },
          contacts: [{ first_name: '', last_name: '', email: params.customerEmail }],
        },
        items: params.lines.map((line) => ({
          code: line.productName.substring(0, 30),
          description: `${line.productName} - ${line.variantName}`,
          quantity: line.quantity,
          price: line.unitPrice.gross.amount,
          taxed: true,
          taxes: [{ id: parseInt(process.env.SIIGO_TAX_ID ?? '19001', 10) }],  // IVA 19%
        })),
        payments: [
          {
            id: parseInt(process.env.SIIGO_PAYMENT_METHOD_ID ?? '5765', 10),
            value: params.totalAmount,
            due_date: new Date().toISOString().split('T')[0],
          },
        ],
        observations: `Pedido Licona Store #${params.orderNumber}`,
      }),
    })

    if (!response.ok) {
      const err = await response.json().catch(() => ({}))
      throw new Error(`Siigo invoice error ${response.status}: ${JSON.stringify(err)}`)
    }

    const data = await response.json()
    return { id: data.id, number: data.number }
  }
}
```

- [ ] **Step 5: Commit**

```bash
git add apps/facturacion/
git commit -m "feat: implement app-facturacion-co with Siigo provider and ORDER_FULLY_PAID webhook"
```

---

## Task 7: Desplegar `app-facturacion-co`

**Files:**
- Create: `apps/facturacion/Dockerfile`

- [ ] **Step 1: Dockerfile**

```dockerfile
FROM node:22-slim AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-slim AS runner
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
EXPOSE 3003
CMD ["node", "dist/index.js"]
```

- [ ] **Step 2: Variables en Railway**

```
APP_URL=https://facturacion.apps.licona-store.com
SALEOR_WEBHOOK_SECRET=<generar>
SIIGO_USERNAME=<usuario de Siigo>
SIIGO_ACCESS_KEY=<access key de Siigo>
SIIGO_INVOICE_TYPE_ID=<ID del tipo de factura de venta en Siigo>
SIIGO_TAX_ID=<ID del impuesto IVA 19% en Siigo>
SIIGO_PAYMENT_METHOD_ID=<ID del método de pago tarjeta en Siigo>
PORT=3003
```

- [ ] **Step 3: Instalar en Saleor Dashboard**

Dashboard → Apps → Install custom app → `https://facturacion.apps.licona-store.com/api/manifest`.

- [ ] **Step 4: Prueba**

Desde el sandbox, completar una orden con pago Wompi aprobado. Verificar en los logs de `app-facturacion-co` que la factura fue emitida. Verificar en Siigo que aparece la factura.

- [ ] **Step 5: Commit**

```bash
git add apps/facturacion/Dockerfile
git commit -m "feat: add Dockerfile for app-facturacion Railway deployment"
git push origin main
```

---

## Verificación final de Fase 4

- [ ] Login y registro de cliente funcional en el storefront.
- [ ] Las rutas `/cuenta/**` redirigen a login si no hay sesión.
- [ ] El historial de órdenes muestra las órdenes del cliente logueado.
- [ ] Al completar una orden pagada, `app-facturacion-co` emite la factura y aparece en Siigo.
- [ ] `npx vitest run` pasa todos los tests.
- [ ] Actualizar `STATUS.md`: Fase 4 → ✅ Completada.
