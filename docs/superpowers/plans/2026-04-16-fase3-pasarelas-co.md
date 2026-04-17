# Fase 3 — Pasarelas de Pago Colombia

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `app-wompi`, `app-payu` y `app-mercadopago` completamente funcionales contra la Transactions API de Saleor, con sandboxes probados end-to-end. El storefront muestra las pasarelas disponibles en el checkout y completa órdenes reales.

**Architecture:** Cada pasarela es un Next.js 15 App independiente usando `@saleor/app-sdk`. Implementan los 6 webhooks síncronos de la Transactions API. La idempotencia se maneja con UUID v4 generado en el storefront y enviado en cada intento de `transactionInitialize`. El storefront llama `paymentGatewayInitialize` para obtener la configuración pública de cada pasarela.

**Tech Stack:** Next.js 15 (App Router), `@saleor/app-sdk` ^0.50, `@saleor/app-sdk/APL/upstash`, TypeScript strict, Vitest, Railway.

**Estado:** 🔲 Pendiente | Requiere: Fase 2 completada

---

## Mapa de archivos

```
licona-saleor-apps/
└── apps/
    └── wompi/                                          # Pasarela primaria
        ├── src/
        │   ├── app/
        │   │   ├── api/
        │   │   │   ├── manifest/route.ts               # App manifest
        │   │   │   ├── register/route.ts               # APL registration
        │   │   │   └── webhooks/
        │   │   │       ├── payment-gateway-initialize-session/route.ts
        │   │   │       ├── transaction-initialize-session/route.ts
        │   │   │       ├── transaction-process-session/route.ts
        │   │   │       ├── transaction-charge-requested/route.ts
        │   │   │       ├── transaction-refund-requested/route.ts
        │   │   │       ├── transaction-cancelation-requested/route.ts
        │   │   │       └── wompi-incoming/route.ts      # Webhook entrante de Wompi
        │   │   └── page.tsx                             # UI de configuración (iframe en dashboard)
        │   ├── lib/
        │   │   ├── wompi-client.ts                      # SDK HTTP para la API de Wompi
        │   │   ├── saleor-client.ts                     # Cliente GraphQL para transactionEventReport
        │   │   └── verify-signature.ts                  # Verificación HMAC para webhooks de Wompi
        │   └── saleor-app.ts                            # Instancia de SaleorApp con APL
        ├── Dockerfile
        └── package.json

# app-payu y app-mercadopago tienen la misma estructura con sus clientes específicos.

licona-storefront/ (modificaciones)
└── app/
    ├── composables/
    │   └── usePayment.ts                               # Orquesta la Transactions API desde el storefront
    ├── components/checkout/
    │   ├── PaymentMethodSelector.vue                   # Lista pasarelas disponibles
    │   └── WompiWidget.vue                             # Widget de pago Wompi
    ├── graphql/mutations/
    │   └── payment.graphql                             # paymentGatewayInitialize, transactionInitialize, checkoutComplete
    └── pages/checkout/
        ├── pago.vue                                    # Paso de pago (reemplaza confirmacion.vue)
        └── orden/[id].vue                              # Página de orden completada
```

---

## Task 1: Scaffold de `app-wompi` con Next.js 15

**Files:**
- Create: `apps/wompi/package.json`, `apps/wompi/src/saleor-app.ts`

- [ ] **Step 1: Crear el directorio y `package.json`**

```bash
mkdir -p apps/wompi/src/app/api/webhooks apps/wompi/src/lib
```

```json
// apps/wompi/package.json
{
  "name": "@licona/app-wompi",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "next dev --port 3002",
    "build": "next build",
    "start": "next start --port 3002",
    "test": "vitest run"
  },
  "dependencies": {
    "@saleor/app-sdk": "^0.50.0",
    "next": "^15.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "graphql": "^16.8.0",
    "graphql-request": "^7.0.0"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "@types/react": "^19.0.0",
    "typescript": "^5.4.0",
    "vitest": "^1.5.0"
  }
}
```

- [ ] **Step 2: Crear `saleor-app.ts` con APL**

```typescript
// apps/wompi/src/saleor-app.ts
import { SaleorApp } from '@saleor/app-sdk/saleor-app'
import { UpstashAPL } from '@saleor/app-sdk/APL/upstash'
import { FileAPL } from '@saleor/app-sdk/APL/file'

// En producción usar UpstashAPL; en desarrollo FileAPL
const apl =
  process.env.NODE_ENV === 'production'
    ? new UpstashAPL({
        restUrl: process.env.UPSTASH_URL!,
        restToken: process.env.UPSTASH_TOKEN!,
      })
    : new FileAPL()

export const saleorApp = new SaleorApp({ apl })
```

- [ ] **Step 3: Commit**

```bash
git add apps/wompi/
git commit -m "feat: scaffold app-wompi with Next.js 15 and SaleorApp"
```

---

## Task 2: Manifest y registro de `app-wompi`

**Files:**
- Create: `apps/wompi/src/app/api/manifest/route.ts`
- Create: `apps/wompi/src/app/api/register/route.ts`

- [ ] **Step 1: Crear el manifest**

```typescript
// apps/wompi/src/app/api/manifest/route.ts
import { createManifestHandler } from '@saleor/app-sdk/handlers/next'
import { saleorApp } from '../../../saleor-app'

const APP_URL = process.env.APP_URL ?? 'http://localhost:3002'

export const GET = createManifestHandler({
  manifestFactory: () => ({
    id: 'app.licona.wompi',
    version: '1.0.0',
    name: 'Wompi (Bancolombia)',
    about: 'Pasarela de pagos Wompi para Colombia: tarjetas, PSE, Nequi, Daviplata y más.',
    permissions: ['HANDLE_PAYMENTS', 'HANDLE_CHECKOUTS'],
    appUrl: APP_URL,
    tokenTargetUrl: `${APP_URL}/api/register`,
    webhooks: [
      {
        name: 'Payment Gateway Initialize Session',
        syncEvents: ['PAYMENT_GATEWAY_INITIALIZE_SESSION'],
        isActive: true,
        targetUrl: `${APP_URL}/api/webhooks/payment-gateway-initialize-session`,
      },
      {
        name: 'Transaction Initialize Session',
        syncEvents: ['TRANSACTION_INITIALIZE_SESSION'],
        isActive: true,
        targetUrl: `${APP_URL}/api/webhooks/transaction-initialize-session`,
      },
      {
        name: 'Transaction Process Session',
        syncEvents: ['TRANSACTION_PROCESS_SESSION'],
        isActive: true,
        targetUrl: `${APP_URL}/api/webhooks/transaction-process-session`,
      },
      {
        name: 'Transaction Charge Requested',
        syncEvents: ['TRANSACTION_CHARGE_REQUESTED'],
        isActive: true,
        targetUrl: `${APP_URL}/api/webhooks/transaction-charge-requested`,
      },
      {
        name: 'Transaction Refund Requested',
        syncEvents: ['TRANSACTION_REFUND_REQUESTED'],
        isActive: true,
        targetUrl: `${APP_URL}/api/webhooks/transaction-refund-requested`,
      },
      {
        name: 'Transaction Cancelation Requested',
        syncEvents: ['TRANSACTION_CANCELATION_REQUESTED'],
        isActive: true,
        targetUrl: `${APP_URL}/api/webhooks/transaction-cancelation-requested`,
      },
    ],
    extensions: [
      {
        label: 'Configuración Wompi',
        mount: 'NAVIGATION_CATALOG',
        target: 'APP_PAGE',
        permissions: ['MANAGE_APPS'],
        url: `${APP_URL}/?saleorApiUrl={saleorApiUrl}`,
      },
    ],
    requiredSaleorVersion: '>=3.22.0',
  }),
  saleorApp,
})
```

- [ ] **Step 2: Crear el handler de registro**

```typescript
// apps/wompi/src/app/api/register/route.ts
import { createAppRegisterHandler } from '@saleor/app-sdk/handlers/next'
import { saleorApp } from '../../../saleor-app'

export const POST = createAppRegisterHandler({ saleorApp })
```

- [ ] **Step 3: Commit**

```bash
git add apps/wompi/src/app/api/manifest apps/wompi/src/app/api/register
git commit -m "feat: add app-wompi manifest and registration handler"
```

---

## Task 3: Cliente HTTP de Wompi

**Files:**
- Create: `apps/wompi/src/lib/wompi-client.ts`
- Create: `tests/lib/wompi-client.test.ts`

- [ ] **Step 1: Test primero**

```typescript
// tests/lib/wompi-client.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

// Mock global fetch
global.fetch = vi.fn()

beforeEach(() => vi.clearAllMocks())

describe('WompiClient', () => {
  it('getPublicKey devuelve la llave pública del merchant', async () => {
    (fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      ok: true,
      json: async () => ({ data: { public_key: 'pub_test_abc123' } }),
    })

    const { WompiClient } = await import('../../apps/wompi/src/lib/wompi-client')
    const client = new WompiClient({ publicKey: 'pub_test_abc123', privateKey: 'priv_test_xyz' })
    const key = await client.getPublicKey()
    expect(key).toBe('pub_test_abc123')
  })

  it('createTransaction envía amount en centavos', async () => {
    (fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      ok: true,
      json: async () => ({ data: { id: 'txn_001', status: 'PENDING' } }),
    })

    const { WompiClient } = await import('../../apps/wompi/src/lib/wompi-client')
    const client = new WompiClient({ publicKey: 'pub_test_abc123', privateKey: 'priv_test_xyz' })
    const txn = await client.createTransaction({
      amountInCents: 12000000, // 120.000 COP
      currency: 'COP',
      customerEmail: 'test@example.com',
      reference: 'order-001',
      redirectUrl: 'https://licona-store.com/checkout/confirmacion',
    })
    expect(txn.id).toBe('txn_001')

    const [, options] = (fetch as ReturnType<typeof vi.fn>).mock.calls[0]
    const body = JSON.parse((options as RequestInit).body as string)
    expect(body.amount_in_cents).toBe(12000000)
  })
})
```

- [ ] **Step 2: Verificar fallo**

```bash
npx vitest run tests/lib/wompi-client.test.ts
```

- [ ] **Step 3: Implementar `wompi-client.ts`**

```typescript
// apps/wompi/src/lib/wompi-client.ts

const WOMPI_BASE_URL = 'https://sandbox.wompi.co/v1' // cambiar a producción: https://production.wompi.co/v1

interface WompiConfig {
  publicKey: string
  privateKey: string
  sandboxMode?: boolean
}

interface CreateTransactionParams {
  amountInCents: number     // Saleor trabaja en centavos de COP (1 COP = 1 centavo en Wompi)
  currency: 'COP'
  customerEmail: string
  reference: string          // Debe ser único por transacción (idempotencyKey)
  redirectUrl: string
  paymentMethod?: {
    type: 'CARD' | 'PSE' | 'NEQUI' | 'DAVIPLATA' | 'BANCOLOMBIA_TRANSFER'
    installments?: number
  }
}

interface WompiTransaction {
  id: string
  status: 'PENDING' | 'APPROVED' | 'DECLINED' | 'VOIDED' | 'ERROR'
  reference: string
  amount_in_cents: number
  currency: string
  payment_method_type: string
  redirect_url?: string
}

export class WompiClient {
  private baseUrl: string

  constructor(private config: WompiConfig) {
    this.baseUrl = config.sandboxMode === false
      ? 'https://production.wompi.co/v1'
      : WOMPI_BASE_URL
  }

  getPublicKey(): string {
    return this.config.publicKey
  }

  async createTransaction(params: CreateTransactionParams): Promise<WompiTransaction> {
    const response = await fetch(`${this.baseUrl}/transactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.config.privateKey}`,
      },
      body: JSON.stringify({
        amount_in_cents: params.amountInCents,
        currency: params.currency,
        customer_email: params.customerEmail,
        reference: params.reference,
        redirect_url: params.redirectUrl,
        payment_method: params.paymentMethod ?? { type: 'CARD' },
      }),
    })

    if (!response.ok) {
      const err = await response.json().catch(() => ({}))
      throw new Error(`Wompi API error ${response.status}: ${JSON.stringify(err)}`)
    }

    const data = await response.json()
    return data.data as WompiTransaction
  }

  async getTransaction(transactionId: string): Promise<WompiTransaction> {
    const response = await fetch(`${this.baseUrl}/transactions/${transactionId}`, {
      headers: { Authorization: `Bearer ${this.config.privateKey}` },
    })

    if (!response.ok) throw new Error(`Wompi API error ${response.status}`)
    const data = await response.json()
    return data.data as WompiTransaction
  }

  async voidTransaction(transactionId: string): Promise<void> {
    const response = await fetch(`${this.baseUrl}/transactions/${transactionId}/void`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${this.config.privateKey}` },
    })
    if (!response.ok) throw new Error(`Wompi void error ${response.status}`)
  }

  async refundTransaction(transactionId: string, amountInCents: number): Promise<void> {
    const response = await fetch(`${this.baseUrl}/transactions/${transactionId}/refund`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.config.privateKey}`,
      },
      body: JSON.stringify({ amount_in_cents: amountInCents }),
    })
    if (!response.ok) throw new Error(`Wompi refund error ${response.status}`)
  }
}
```

- [ ] **Step 4: Ejecutar tests**

```bash
npx vitest run tests/lib/wompi-client.test.ts
```

Salida esperada: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/wompi/src/lib/wompi-client.ts tests/lib/wompi-client.test.ts
git commit -m "feat: implement WompiClient with transaction CRUD"
```

---

## Task 4: Webhook `PAYMENT_GATEWAY_INITIALIZE_SESSION`

**Files:**
- Create: `apps/wompi/src/app/api/webhooks/payment-gateway-initialize-session/route.ts`

Este webhook recibe la solicitud del storefront de "¿qué datos necesito para mostrar esta pasarela?" y responde con la clave pública de Wompi y los métodos habilitados.

- [ ] **Step 1: Crear el handler**

```typescript
// apps/wompi/src/app/api/webhooks/payment-gateway-initialize-session/route.ts
import { createSyncWebhookHandler } from '@saleor/app-sdk/handlers/next'
import { PaymentGatewayInitializeSessionDocument } from '@saleor/app-sdk/types'
import { saleorApp } from '../../../../saleor-app'
import { WompiClient } from '../../../../lib/wompi-client'

export const POST = createSyncWebhookHandler({
  saleorApp,
  webhookName: 'PAYMENT_GATEWAY_INITIALIZE_SESSION',
  handler: async ({ payload }) => {
    const client = new WompiClient({
      publicKey: process.env.WOMPI_PUBLIC_KEY!,
      privateKey: process.env.WOMPI_PRIVATE_KEY!,
      sandboxMode: process.env.WOMPI_SANDBOX === 'true',
    })

    return {
      data: {
        publicKey: client.getPublicKey(),
        methods: ['CARD', 'PSE', 'NEQUI', 'DAVIPLATA', 'BANCOLOMBIA_TRANSFER'],
        currency: 'COP',
      },
    }
  },
})
```

- [ ] **Step 2: Commit**

```bash
git add apps/wompi/src/app/api/webhooks/payment-gateway-initialize-session/
git commit -m "feat: add PAYMENT_GATEWAY_INITIALIZE_SESSION handler"
```

---

## Task 5: Webhook `TRANSACTION_INITIALIZE_SESSION`

**Files:**
- Create: `apps/wompi/src/app/api/webhooks/transaction-initialize-session/route.ts`

Este es el webhook principal. El storefront llama a Saleor con la intención de pago y Saleor dispara este webhook. La App crea la transacción en Wompi y responde con la URL de redirección.

- [ ] **Step 1: Crear el handler**

```typescript
// apps/wompi/src/app/api/webhooks/transaction-initialize-session/route.ts
import { createSyncWebhookHandler } from '@saleor/app-sdk/handlers/next'
import { saleorApp } from '../../../../saleor-app'
import { WompiClient } from '../../../../lib/wompi-client'

export const POST = createSyncWebhookHandler({
  saleorApp,
  webhookName: 'TRANSACTION_INITIALIZE_SESSION',
  handler: async ({ payload }) => {
    const {
      action: { amount, currency },
      transaction: { id: transactionId },
      data,
      issuedAt,
    } = payload

    // El storefront envía el idempotencyKey en data
    const reference = (data as { idempotencyKey?: string })?.idempotencyKey ?? transactionId

    const client = new WompiClient({
      publicKey: process.env.WOMPI_PUBLIC_KEY!,
      privateKey: process.env.WOMPI_PRIVATE_KEY!,
      sandboxMode: process.env.WOMPI_SANDBOX === 'true',
    })

    const paymentMethod = (data as { method?: string })?.method ?? 'CARD'

    try {
      // Wompi trabaja en centavos. Saleor envía el monto en COP (ya sin decimales).
      // 1 COP = 100 centavos de Wompi.
      const amountInCents = Math.round(amount * 100)

      const wompiTxn = await client.createTransaction({
        amountInCents,
        currency: 'COP',
        customerEmail: payload.checkout?.email ?? '',
        reference,
        redirectUrl: `${process.env.STOREFRONT_URL}/checkout/confirmacion?txn=${transactionId}`,
        paymentMethod: { type: paymentMethod as 'CARD' | 'PSE' | 'NEQUI' | 'DAVIPLATA' | 'BANCOLOMBIA_TRANSFER' },
      })

      // Retornar CHARGE_ACTION_REQUIRED para que Saleor sepa que el usuario
      // debe ser redirigido a Wompi para completar el pago.
      return {
        result: 'CHARGE_ACTION_REQUIRED',
        amount,
        pspReference: wompiTxn.id,
        data: {
          redirectUrl: wompiTxn.redirect_url,
          wompiTransactionId: wompiTxn.id,
        },
      }
    } catch (error) {
      return {
        result: 'CHARGE_FAILURE',
        amount,
        message: error instanceof Error ? error.message : 'Error al crear transacción en Wompi',
      }
    }
  },
})
```

- [ ] **Step 2: Commit**

```bash
git add apps/wompi/src/app/api/webhooks/transaction-initialize-session/
git commit -m "feat: implement TRANSACTION_INITIALIZE_SESSION handler"
```

---

## Task 6: Webhook de confirmación entrante de Wompi

**Files:**
- Create: `apps/wompi/src/lib/verify-signature.ts`
- Create: `apps/wompi/src/app/api/webhooks/wompi-incoming/route.ts`
- Create: `apps/wompi/src/lib/saleor-client.ts`

- [ ] **Step 1: Crear verificación de firma de Wompi**

Wompi firma sus webhooks con SHA256 HMAC usando el `events_secret_key` del merchant.

```typescript
// apps/wompi/src/lib/verify-signature.ts
import { createHmac, timingSafeEqual } from 'node:crypto'

export function verifyWompiSignature(
  payload: string,
  timestamp: string,
  signature: string,
  secret: string
): boolean {
  // Wompi: checksum = sha256(properties + timestamp + secret)
  const toSign = payload + timestamp + secret
  const expected = createHmac('sha256', secret).update(toSign).digest('hex')
  const sigBuffer = Buffer.from(signature, 'hex')
  const expBuffer = Buffer.from(expected, 'hex')
  return sigBuffer.length === expBuffer.length && timingSafeEqual(sigBuffer, expBuffer)
}
```

- [ ] **Step 2: Crear cliente Saleor para `transactionEventReport`**

```typescript
// apps/wompi/src/lib/saleor-client.ts
import { GraphQLClient, gql } from 'graphql-request'

const TRANSACTION_EVENT_REPORT = gql`
  mutation TransactionEventReport(
    $transactionId: ID!
    $type: TransactionEventTypeEnum!
    $amount: PositiveDecimal!
    $pspReference: String!
    $message: String
  ) {
    transactionEventReport(
      id: $transactionId
      type: $type
      amount: $amount
      pspReference: $pspReference
      message: $message
    ) {
      alreadyProcessed
      transaction { id }
      errors { field message code }
    }
  }
`

export async function reportTransactionEvent({
  saleorApiUrl,
  token,
  transactionId,
  type,
  amount,
  pspReference,
  message,
}: {
  saleorApiUrl: string
  token: string
  transactionId: string
  type: 'CHARGE_SUCCESS' | 'CHARGE_FAILURE' | 'REFUND_SUCCESS' | 'REFUND_FAILURE' | 'CANCEL_SUCCESS'
  amount: number
  pspReference: string
  message?: string
}) {
  const client = new GraphQLClient(saleorApiUrl, {
    headers: { Authorization: `Bearer ${token}` },
  })

  return client.request(TRANSACTION_EVENT_REPORT, {
    transactionId,
    type,
    amount: amount.toString(),
    pspReference,
    message,
  })
}
```

- [ ] **Step 3: Crear el handler de webhook entrante de Wompi**

```typescript
// apps/wompi/src/app/api/webhooks/wompi-incoming/route.ts
import { NextRequest, NextResponse } from 'next/server'
import { verifyWompiSignature } from '../../../../lib/verify-signature'
import { reportTransactionEvent } from '../../../../lib/saleor-client'

const WOMPI_STATUS_TO_SALEOR: Record<string, 'CHARGE_SUCCESS' | 'CHARGE_FAILURE'> = {
  APPROVED: 'CHARGE_SUCCESS',
  DECLINED: 'CHARGE_FAILURE',
  ERROR: 'CHARGE_FAILURE',
  VOIDED: 'CHARGE_FAILURE',
}

export async function POST(req: NextRequest) {
  const rawBody = await req.text()
  const timestamp = req.headers.get('x-event-created-at') ?? ''
  const signature = req.headers.get('x-signature') ?? ''
  const secret = process.env.WOMPI_EVENTS_SECRET!

  if (!verifyWompiSignature(rawBody, timestamp, signature, secret)) {
    return NextResponse.json({ error: 'Invalid signature' }, { status: 401 })
  }

  const payload = JSON.parse(rawBody)
  const transaction = payload.data?.transaction

  if (!transaction) return NextResponse.json({ ok: true })

  const wompiStatus: string = transaction.status
  const saleorEventType = WOMPI_STATUS_TO_SALEOR[wompiStatus]

  if (!saleorEventType) return NextResponse.json({ ok: true })

  // El reference es el saleorTransactionId que guardamos al crear la transacción
  // La App necesita buscar en el APL el token para la instancia de Saleor
  // Por simplicidad, usamos una variable de entorno con el URL y token de la instancia
  await reportTransactionEvent({
    saleorApiUrl: process.env.SALEOR_API_URL!,
    token: process.env.SALEOR_APP_TOKEN!,
    transactionId: transaction.reference,  // saleor transaction id
    type: saleorEventType,
    amount: transaction.amount_in_cents / 100,  // convertir centavos a COP
    pspReference: transaction.id,
    message: `Wompi status: ${wompiStatus}`,
  })

  return NextResponse.json({ ok: true })
}
```

- [ ] **Step 4: Commit**

```bash
git add apps/wompi/src/lib/ apps/wompi/src/app/api/webhooks/wompi-incoming/
git commit -m "feat: add Wompi incoming webhook handler with HMAC verification and transactionEventReport"
```

---

## Task 7: Webhooks de operaciones (charge, refund, cancel)

**Files:**
- Create: `apps/wompi/src/app/api/webhooks/transaction-charge-requested/route.ts`
- Create: `apps/wompi/src/app/api/webhooks/transaction-refund-requested/route.ts`
- Create: `apps/wompi/src/app/api/webhooks/transaction-cancelation-requested/route.ts`
- Create: `apps/wompi/src/app/api/webhooks/transaction-process-session/route.ts`

- [ ] **Step 1: `transaction-charge-requested`** (captura de auth — Wompi auto-captura, solo confirmar)

```typescript
// apps/wompi/src/app/api/webhooks/transaction-charge-requested/route.ts
import { createSyncWebhookHandler } from '@saleor/app-sdk/handlers/next'
import { saleorApp } from '../../../../saleor-app'

export const POST = createSyncWebhookHandler({
  saleorApp,
  webhookName: 'TRANSACTION_CHARGE_REQUESTED',
  handler: async ({ payload }) => {
    // Wompi auto-captura en el authorize; no hay acción adicional.
    return {
      result: 'CHARGE_SUCCESS',
      amount: payload.action.amount,
      pspReference: payload.transaction.pspReference ?? '',
    }
  },
})
```

- [ ] **Step 2: `transaction-refund-requested`**

```typescript
// apps/wompi/src/app/api/webhooks/transaction-refund-requested/route.ts
import { createSyncWebhookHandler } from '@saleor/app-sdk/handlers/next'
import { saleorApp } from '../../../../saleor-app'
import { WompiClient } from '../../../../lib/wompi-client'

export const POST = createSyncWebhookHandler({
  saleorApp,
  webhookName: 'TRANSACTION_REFUND_REQUESTED',
  handler: async ({ payload }) => {
    const client = new WompiClient({
      publicKey: process.env.WOMPI_PUBLIC_KEY!,
      privateKey: process.env.WOMPI_PRIVATE_KEY!,
      sandboxMode: process.env.WOMPI_SANDBOX === 'true',
    })

    const pspReference = payload.transaction.pspReference
    if (!pspReference) {
      return { result: 'REFUND_FAILURE', amount: payload.action.amount, message: 'Sin pspReference' }
    }

    try {
      const amountInCents = Math.round(payload.action.amount * 100)
      await client.refundTransaction(pspReference, amountInCents)
      return { result: 'REFUND_SUCCESS', amount: payload.action.amount, pspReference }
    } catch (error) {
      return {
        result: 'REFUND_FAILURE',
        amount: payload.action.amount,
        message: error instanceof Error ? error.message : 'Error en reembolso',
      }
    }
  },
})
```

- [ ] **Step 3: `transaction-cancelation-requested`**

```typescript
// apps/wompi/src/app/api/webhooks/transaction-cancelation-requested/route.ts
import { createSyncWebhookHandler } from '@saleor/app-sdk/handlers/next'
import { saleorApp } from '../../../../saleor-app'
import { WompiClient } from '../../../../lib/wompi-client'

export const POST = createSyncWebhookHandler({
  saleorApp,
  webhookName: 'TRANSACTION_CANCELATION_REQUESTED',
  handler: async ({ payload }) => {
    const client = new WompiClient({
      publicKey: process.env.WOMPI_PUBLIC_KEY!,
      privateKey: process.env.WOMPI_PRIVATE_KEY!,
      sandboxMode: process.env.WOMPI_SANDBOX === 'true',
    })

    const pspReference = payload.transaction.pspReference
    if (!pspReference) {
      return { result: 'CANCEL_FAILURE', amount: payload.action.amount, message: 'Sin pspReference' }
    }

    try {
      await client.voidTransaction(pspReference)
      return { result: 'CANCEL_SUCCESS', amount: payload.action.amount, pspReference }
    } catch (error) {
      return {
        result: 'CANCEL_FAILURE',
        amount: payload.action.amount,
        message: error instanceof Error ? error.message : 'Error en cancelación',
      }
    }
  },
})
```

- [ ] **Step 4: `transaction-process-session`** (pasos adicionales como 3DS)

```typescript
// apps/wompi/src/app/api/webhooks/transaction-process-session/route.ts
import { createSyncWebhookHandler } from '@saleor/app-sdk/handlers/next'
import { saleorApp } from '../../../../saleor-app'
import { WompiClient } from '../../../../lib/wompi-client'

export const POST = createSyncWebhookHandler({
  saleorApp,
  webhookName: 'TRANSACTION_PROCESS_SESSION',
  handler: async ({ payload }) => {
    const client = new WompiClient({
      publicKey: process.env.WOMPI_PUBLIC_KEY!,
      privateKey: process.env.WOMPI_PRIVATE_KEY!,
      sandboxMode: process.env.WOMPI_SANDBOX === 'true',
    })

    const pspReference = payload.transaction.pspReference
    if (!pspReference) {
      return { result: 'CHARGE_FAILURE', amount: payload.action.amount, message: 'Sin transacción activa' }
    }

    const wompiTxn = await client.getTransaction(pspReference)

    const statusMap: Record<string, string> = {
      APPROVED: 'CHARGE_SUCCESS',
      DECLINED: 'CHARGE_FAILURE',
      ERROR: 'CHARGE_FAILURE',
      PENDING: 'CHARGE_ACTION_REQUIRED',
    }

    return {
      result: statusMap[wompiTxn.status] ?? 'CHARGE_ACTION_REQUIRED',
      amount: payload.action.amount,
      pspReference,
    }
  },
})
```

- [ ] **Step 5: Commit**

```bash
git add apps/wompi/src/app/api/webhooks/
git commit -m "feat: implement all Transactions API webhook handlers for Wompi"
```

---

## Task 8: Mutations de pago en el storefront

**Files:**
- Create: `app/graphql/mutations/payment.graphql`
- Create: `app/composables/usePayment.ts`

- [ ] **Step 1: Mutations GraphQL**

```graphql
# app/graphql/mutations/payment.graphql

mutation PaymentGatewayInitialize($checkoutId: ID!, $paymentGateways: [PaymentGatewayToInitialize!]) {
  paymentGatewayInitialize(
    id: $checkoutId
    paymentGateways: $paymentGateways
  ) {
    gatewayConfigs {
      id
      data
      errors { field message code }
    }
    errors { field message code }
  }
}

mutation TransactionInitialize(
  $checkoutId: ID!
  $paymentGateway: PaymentGatewayToInitialize!
  $idempotencyKey: String!
) {
  transactionInitialize(
    id: $checkoutId
    paymentGateway: $paymentGateway
    idempotencyKey: $idempotencyKey
  ) {
    transaction {
      id
      pspReference
    }
    transactionEvent {
      type
      message
    }
    data
    errors { field message code }
  }
}

mutation CheckoutComplete($checkoutId: ID!) {
  checkoutComplete(id: $checkoutId) {
    order {
      id
      number
      status
      totalPrice { gross { amount currency } }
    }
    errors { field message code }
  }
}
```

- [ ] **Step 2: Regenerar tipos**

```bash
npm run codegen
```

- [ ] **Step 3: Crear `usePayment.ts`**

```typescript
// app/composables/usePayment.ts
import { useMutation } from '@urql/vue'
import {
  PaymentGatewayInitializeDocument,
  TransactionInitializeDocument,
  CheckoutCompleteDocument,
} from '~/graphql/generated/graphql'
import { useCart } from '~/composables/useCart'

const IDEMPOTENCY_KEY_STORAGE = 'saleor-payment-idempotency-key'

export function usePayment() {
  const { checkoutId } = useCart()
  const [, initGateway] = useMutation(PaymentGatewayInitializeDocument)
  const [, initTransaction] = useMutation(TransactionInitializeDocument)
  const [, completeCheckout] = useMutation(CheckoutCompleteDocument)

  function getOrCreateIdempotencyKey(): string {
    if (typeof window === 'undefined') return crypto.randomUUID()
    const existing = localStorage.getItem(IDEMPOTENCY_KEY_STORAGE)
    if (existing) return existing
    const key = crypto.randomUUID()
    localStorage.setItem(IDEMPOTENCY_KEY_STORAGE, key)
    return key
  }

  function clearIdempotencyKey() {
    if (typeof window !== 'undefined') {
      localStorage.removeItem(IDEMPOTENCY_KEY_STORAGE)
    }
  }

  async function getGatewayConfig(gatewayId: string) {
    if (!checkoutId.value) throw new Error('No hay checkout activo')
    const result = await initGateway({
      checkoutId: checkoutId.value,
      paymentGateways: [{ id: gatewayId, data: null }],
    })
    if (result.data?.paymentGatewayInitialize?.errors.length) {
      throw new Error(result.data.paymentGatewayInitialize.errors[0].message ?? 'Error al inicializar pasarela')
    }
    return result.data?.paymentGatewayInitialize?.gatewayConfigs?.[0]?.data
  }

  async function startPayment(gatewayId: string, paymentData: Record<string, unknown>) {
    if (!checkoutId.value) throw new Error('No hay checkout activo')
    const idempotencyKey = getOrCreateIdempotencyKey()

    const result = await initTransaction({
      checkoutId: checkoutId.value,
      paymentGateway: { id: gatewayId, data: paymentData },
      idempotencyKey,
    })

    if (result.data?.transactionInitialize?.errors.length) {
      throw new Error(result.data.transactionInitialize.errors[0].message ?? 'Error al iniciar transacción')
    }

    return result.data?.transactionInitialize
  }

  async function completeOrder() {
    if (!checkoutId.value) throw new Error('No hay checkout activo')
    const result = await completeCheckout({ checkoutId: checkoutId.value })

    if (result.data?.checkoutComplete?.errors.length) {
      throw new Error(result.data.checkoutComplete.errors[0].message ?? 'Error al completar la orden')
    }

    clearIdempotencyKey()
    return result.data?.checkoutComplete?.order
  }

  return { getGatewayConfig, startPayment, completeOrder }
}
```

- [ ] **Step 4: Commit**

```bash
git add app/graphql/mutations/payment.graphql app/composables/usePayment.ts app/graphql/generated/
git commit -m "feat: add payment mutations and usePayment composable with idempotency"
```

---

## Task 9: Página de pago en el storefront

**Files:**
- Create: `app/pages/checkout/pago.vue`
- Create: `app/components/checkout/PaymentMethodSelector.vue`
- Create: `app/pages/checkout/orden/[id].vue`

- [ ] **Step 1: `PaymentMethodSelector.vue`**

```vue
<!-- app/components/checkout/PaymentMethodSelector.vue -->
<script setup lang="ts">
const GATEWAYS = [
  { id: 'app.licona.wompi', name: 'Wompi', methods: ['Tarjeta', 'PSE', 'Nequi', 'Daviplata'] },
  { id: 'app.licona.payu', name: 'PayU', methods: ['Tarjeta', 'PSE', 'Efecty', 'Baloto'] },
  { id: 'app.licona.mercadopago', name: 'Mercado Pago', methods: ['Tarjeta', 'PSE', 'Saldo MP'] },
]

const selected = defineModel<string>({ required: true })
</script>

<template>
  <div class="space-y-3">
    <label
      v-for="gw in GATEWAYS"
      :key="gw.id"
      class="flex items-center gap-4 p-4 border cursor-pointer transition-colors"
      :class="selected === gw.id ? 'border-ink bg-ink/5' : 'border-[--color-border]'"
    >
      <input v-model="selected" type="radio" :value="gw.id" class="sr-only" />
      <div class="w-4 h-4 rounded-full border-2 flex-shrink-0 flex items-center justify-center"
        :class="selected === gw.id ? 'border-ink' : 'border-muted'">
        <div v-if="selected === gw.id" class="w-2 h-2 rounded-full bg-ink" />
      </div>
      <div>
        <p class="font-body text-sm font-medium text-ink">{{ gw.name }}</p>
        <p class="font-body text-xs text-muted mt-0.5">{{ gw.methods.join(' · ') }}</p>
      </div>
    </label>
  </div>
</template>
```

- [ ] **Step 2: `app/pages/checkout/pago.vue`**

```vue
<!-- app/pages/checkout/pago.vue -->
<script setup lang="ts">
import { usePayment } from '~/composables/usePayment'
import { useCart } from '~/composables/useCart'

definePageMeta({ layout: 'checkout' })

const { startPayment } = usePayment()
const { total } = useCart()
const router = useRouter()

const selectedGateway = ref('app.licona.wompi')
const selectedMethod = ref('CARD')
const error = ref<string | null>(null)
const processing = ref(false)

const formattedTotal = computed(() =>
  new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', minimumFractionDigits: 0 }).format(total.value)
)

async function pay() {
  error.value = null
  processing.value = true
  try {
    const result = await startPayment(selectedGateway.value, { method: selectedMethod.value })
    const redirectUrl = (result?.data as { redirectUrl?: string })?.redirectUrl
    if (redirectUrl) {
      // Redireccionar a la pasarela (Wompi, PayU, etc.)
      window.location.href = redirectUrl
    } else if (result?.transactionEvent?.type === 'CHARGE_SUCCESS') {
      router.push(`/checkout/orden/${result.transaction?.id}`)
    }
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Error al procesar el pago'
  } finally {
    processing.value = false
  }
}
</script>

<template>
  <div class="max-w-lg mx-auto py-12 px-4">
    <h1 class="font-display text-3xl text-ink mb-8">Pago</h1>

    <div v-if="error" class="mb-6 p-3 bg-accent-light text-accent text-sm font-body">{{ error }}</div>

    <PaymentMethodSelector v-model="selectedGateway" />

    <div class="mt-8 border-t border-[--color-border] pt-6 flex justify-between items-center">
      <span class="font-body text-sm text-muted">Total a pagar</span>
      <span class="font-display text-2xl text-ink">{{ formattedTotal }}</span>
    </div>

    <button
      :disabled="processing"
      class="mt-6 w-full py-4 bg-ink text-cream font-body text-sm font-medium disabled:opacity-50 hover:bg-accent transition-colors duration-200"
      @click="pay"
    >
      {{ processing ? 'Procesando...' : `Pagar ${formattedTotal}` }}
    </button>
  </div>
</template>
```

- [ ] **Step 3: Crear página de orden completada**

```vue
<!-- app/pages/checkout/orden/[id].vue -->
<script setup lang="ts">
definePageMeta({ layout: 'default' })
const route = useRoute()
</script>

<template>
  <div class="max-w-lg mx-auto py-20 px-4 text-center">
    <div class="w-16 h-16 rounded-full bg-ink flex items-center justify-center mx-auto mb-8">
      <span class="text-cream text-2xl">✓</span>
    </div>
    <h1 class="font-display text-4xl text-ink mb-4">¡Gracias por tu compra!</h1>
    <p class="font-body text-muted mb-8">
      Tu pedido ha sido confirmado. Recibirás un correo con los detalles.
    </p>
    <NuxtLink to="/" class="inline-block px-8 py-4 border border-ink text-ink font-body text-sm hover:bg-ink hover:text-cream transition-colors duration-200">
      Seguir comprando
    </NuxtLink>
  </div>
</template>
```

- [ ] **Step 4: Commit**

```bash
git add app/components/checkout/PaymentMethodSelector.vue app/pages/checkout/pago.vue app/pages/checkout/orden/
git commit -m "feat: add payment step and order confirmation page"
```

---

## Task 10: Desplegar `app-wompi` en Railway y registrar en Saleor

**Files:**
- Create: `apps/wompi/Dockerfile`

- [ ] **Step 1: Dockerfile Next.js standalone**

```dockerfile
FROM node:22-slim AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
EXPOSE 3002
CMD ["node", "server.js"]
```

Agregar al `next.config.ts`:
```typescript
output: 'standalone'
```

- [ ] **Step 2: Variables de entorno en Railway**

```
APP_URL=https://wompi.apps.licona-store.com
WOMPI_PUBLIC_KEY=pub_test_...
WOMPI_PRIVATE_KEY=priv_test_...
WOMPI_EVENTS_SECRET=<de la consola de Wompi>
WOMPI_SANDBOX=true
SALEOR_API_URL=https://api.licona-store.com/graphql/
STOREFRONT_URL=https://licona-store.com
UPSTASH_URL=<URL de Upstash Redis>
UPSTASH_TOKEN=<token de Upstash>
```

- [ ] **Step 3: Registrar la App en Saleor Dashboard**

Dashboard → Apps → Install custom app → `https://wompi.apps.licona-store.com/api/manifest`.

Verificar que aparece en la lista de Apps instaladas con el webhook activo.

- [ ] **Step 4: Prueba end-to-end con sandbox de Wompi**

Usar la tarjeta de prueba de Wompi: `4242424242424242`, cualquier fecha futura, CVV `123`.

Flujo: carrito → dirección → envío → pago (seleccionar Wompi, método Tarjeta) → redirección a sandbox Wompi → completar pago → retorno a `/checkout/orden/<id>`.

Verificar en el Dashboard de Saleor que la orden aparece con estado pagado.

- [ ] **Step 5: Commit**

```bash
git add apps/wompi/Dockerfile
git commit -m "feat: add Dockerfile for app-wompi Railway deployment"
git push origin main
```

---

## Task 11: Replicar para app-payu y app-mercadopago

Los mismos pasos de los Tasks 1-10 con los SDKs de PayU y Mercado Pago.

- [ ] **PayU:** documentación en https://developers.payulatam.com — usar el endpoint de tokenización para tarjetas, PSE con banco seleccionado.

- [ ] **Mercado Pago:** SDK oficial `mercadopago` npm package. `new MercadoPago({ accessToken: process.env.MP_ACCESS_TOKEN })`. El flujo de redirect usa `preference.init_point`.

- [ ] Commit independiente para cada App:
  - `feat: implement app-payu with Transactions API`
  - `feat: implement app-mercadopago with Transactions API`

---

## Verificación final de Fase 3

- [ ] Orden completa con Wompi tarjeta en sandbox: storefront → pago → orden confirmada en dashboard.
- [ ] Orden con Wompi PSE en sandbox.
- [ ] Reembolso parcial desde el dashboard: el handler de refund llama a Wompi y la transacción queda en estado reembolsado.
- [ ] Si app-wompi cae (stop del servicio Railway), el storefront y el core siguen funcionando (solo ese método de pago no aparece).
- [ ] `npx vitest run` pasa todos los tests.
- [ ] Actualizar `STATUS.md`: Fase 3 → ✅ Completada.
