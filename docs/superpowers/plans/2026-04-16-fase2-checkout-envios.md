# Fase 2 — Checkout sin pago y App de Envíos

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flujo completo de checkout (carrito → dirección → envío → confirmación) sin pasarela de pago, con cálculo de fletes via `app-envios-co` y emails transaccionales.

**Architecture:** Carrito gestionado como checkout de Saleor (fuente de verdad). El estado de checkout se guarda en cookie por sesión. `app-envios-co` es un microservicio Node/Fastify que escucha el webhook `SHIPPING_LIST_METHODS_FOR_CHECKOUT` y devuelve métodos de envío con tarifas de Servientrega, Coordinadora y TCC.

**Tech Stack:** Nuxt 4, `@saleor/auth-sdk`, Fastify 5, `@saleor/app-sdk`, Node 22, Railway.

**Estado:** 🔲 Pendiente | Requiere: Fase 1 completada

---

## Mapa de archivos

```
licona-storefront/ (modificaciones)
├── app/
│   ├── composables/
│   │   ├── useCart.ts              # Estado del carrito (checkout de Saleor)
│   │   └── useCheckout.ts          # Flujo de checkout multi-paso
│   ├── components/
│   │   ├── cart/
│   │   │   ├── CartDrawer.vue      # Sidebar del carrito
│   │   │   └── CartItem.vue        # Item individual
│   │   └── checkout/
│   │       ├── StepAddress.vue     # Paso dirección de envío
│   │       ├── StepShipping.vue    # Paso método de envío
│   │       └── StepSummary.vue     # Resumen antes de pagar
│   ├── graphql/
│   │   └── mutations/
│   │       └── checkout.graphql    # checkoutCreate, checkoutLineAdd, etc.
│   └── pages/
│       ├── carrito.vue
│       └── checkout/
│           ├── index.vue           # Redirige al paso activo
│           ├── direccion.vue
│           ├── envio.vue
│           └── confirmacion.vue

licona-saleor-apps/ (repo nuevo)
└── apps/
    └── envios/                     # app-envios-co
        ├── src/
        │   ├── index.ts            # Servidor Fastify + manifest
        │   ├── webhooks/
        │   │   └── shipping-list-methods.ts
        │   └── providers/
        │       ├── servientrega.ts
        │       ├── coordinadora.ts
        │       └── tcc.ts
        ├── Dockerfile
        └── package.json
```

---

## Task 1: Mutations de checkout en GraphQL

**Files:**
- Create: `app/graphql/mutations/checkout.graphql`

- [ ] **Step 1: Crear las mutations**

```graphql
# app/graphql/mutations/checkout.graphql

fragment CheckoutBase on Checkout {
  id
  token
  quantity
  totalPrice {
    gross {
      amount
      currency
    }
  }
  lines {
    id
    quantity
    variant {
      id
      name
      product {
        name
        slug
        thumbnail { url alt }
      }
      pricing {
        price { gross { amount currency } }
      }
    }
  }
}

mutation CheckoutCreate($channel: String!, $lines: [CheckoutLineInput!]!) {
  checkoutCreate(input: { channel: $channel, lines: $lines }) {
    checkout { ...CheckoutBase }
    errors { field message code }
  }
}

mutation CheckoutLineAdd($checkoutId: ID!, $lines: [CheckoutLineInput!]!) {
  checkoutLinesAdd(checkoutId: $checkoutId, lines: $lines) {
    checkout { ...CheckoutBase }
    errors { field message code }
  }
}

mutation CheckoutLineUpdate($checkoutId: ID!, $lines: [CheckoutLineUpdateInput!]!) {
  checkoutLinesUpdate(checkoutId: $checkoutId, lines: $lines) {
    checkout { ...CheckoutBase }
    errors { field message code }
  }
}

mutation CheckoutLineDelete($checkoutId: ID!, $lineId: ID!) {
  checkoutLineDelete(checkoutId: $checkoutId, lineId: $lineId) {
    checkout { ...CheckoutBase }
    errors { field message code }
  }
}

mutation CheckoutEmailUpdate($checkoutId: ID!, $email: String!) {
  checkoutEmailUpdate(checkoutId: $checkoutId, email: $email) {
    checkout { ...CheckoutBase }
    errors { field message code }
  }
}

mutation CheckoutShippingAddressUpdate($checkoutId: ID!, $address: AddressInput!) {
  checkoutShippingAddressUpdate(checkoutId: $checkoutId, shippingAddress: $address) {
    checkout {
      ...CheckoutBase
      shippingAddress {
        firstName lastName streetAddress1 city postalCode country { code }
      }
      availableShippingMethods {
        id name price { amount currency }
      }
    }
    errors { field message code }
  }
}

mutation CheckoutDeliveryMethodUpdate($checkoutId: ID!, $deliveryMethodId: ID!) {
  checkoutDeliveryMethodUpdate(checkoutId: $checkoutId, deliveryMethodId: $deliveryMethodId) {
    checkout {
      ...CheckoutBase
      deliveryMethod {
        ... on ShippingMethod { id name price { amount currency } }
      }
    }
    errors { field message code }
  }
}

query CheckoutById($id: ID!) {
  checkout(id: $id) {
    ...CheckoutBase
    email
    shippingAddress {
      firstName lastName streetAddress1 city postalCode country { code }
    }
    deliveryMethod {
      ... on ShippingMethod { id name price { amount currency } }
    }
    availableShippingMethods {
      id name price { amount currency }
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
git add app/graphql/mutations/checkout.graphql app/graphql/generated/
git commit -m "feat: add checkout mutations and query"
```

---

## Task 2: Composable `useCart`

**Files:**
- Create: `app/composables/useCart.ts`
- Create: `tests/composables/useCart.test.ts`

- [ ] **Step 1: Test**

```typescript
// tests/composables/useCart.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

// Mock mínimo del cliente URQL
const mockMutation = vi.fn()
vi.mock('@urql/vue', () => ({
  useMutation: () => [{ fetching: { value: false }, error: { value: null } }, mockMutation],
}))
vi.mock('~/composables/useSaleor', () => ({
  useSaleor: () => ({ channel: 'default-channel', client: {} }),
}))

describe('useCart', () => {
  it('inicia con un carrito vacío', async () => {
    // El composable debe exportar quantity = 0 si no hay checkout guardado
    const { useCart } = await import('~/composables/useCart')
    const cart = useCart()
    expect(cart.quantity.value).toBe(0)
  })
})
```

- [ ] **Step 2: Verificar fallo**

```bash
npx vitest run tests/composables/useCart.test.ts
```

- [ ] **Step 3: Implementar `useCart.ts`**

```typescript
// app/composables/useCart.ts
import { useMutation, useQuery } from '@urql/vue'
import {
  CheckoutCreateDocument,
  CheckoutLineAddDocument,
  CheckoutLineUpdateDocument,
  CheckoutLineDeleteDocument,
  CheckoutByIdDocument,
} from '~/graphql/generated/graphql'
import { useSaleor } from '~/composables/useSaleor'

const CHECKOUT_ID_COOKIE = 'saleor-checkout-id'

export function useCart() {
  const { channel } = useSaleor()
  const checkoutId = useCookie<string | null>(CHECKOUT_ID_COOKIE, {
    default: () => null,
    maxAge: 60 * 60 * 24 * 30, // 30 días
    sameSite: 'lax',
  })

  const { data: checkoutData, executeQuery: refetchCheckout } = useQuery({
    query: CheckoutByIdDocument,
    variables: computed(() => ({ id: checkoutId.value ?? '' })),
    pause: computed(() => !checkoutId.value),
  })

  const checkout = computed(() => checkoutData.value?.checkout ?? null)
  const lines = computed(() => checkout.value?.lines ?? [])
  const quantity = computed(() => checkout.value?.quantity ?? 0)
  const total = computed(() => checkout.value?.totalPrice.gross.amount ?? 0)

  const [, createCheckout] = useMutation(CheckoutCreateDocument)
  const [, addLine] = useMutation(CheckoutLineAddDocument)
  const [, updateLine] = useMutation(CheckoutLineUpdateDocument)
  const [, deleteLine] = useMutation(CheckoutLineDeleteDocument)

  async function addToCart(variantId: string, quantity = 1) {
    if (!checkoutId.value) {
      const result = await createCheckout({
        channel,
        lines: [{ variantId, quantity }],
      })
      if (result.data?.checkoutCreate?.checkout?.id) {
        checkoutId.value = result.data.checkoutCreate.checkout.id
      }
    } else {
      await addLine({
        checkoutId: checkoutId.value,
        lines: [{ variantId, quantity }],
      })
    }
    await refetchCheckout({ requestPolicy: 'network-only' })
  }

  async function updateQuantity(lineId: string, quantity: number) {
    if (!checkoutId.value) return
    if (quantity === 0) {
      await removeFromCart(lineId)
      return
    }
    await updateLine({
      checkoutId: checkoutId.value,
      lines: [{ lineId, quantity }],
    })
    await refetchCheckout({ requestPolicy: 'network-only' })
  }

  async function removeFromCart(lineId: string) {
    if (!checkoutId.value) return
    await deleteLine({ checkoutId: checkoutId.value, lineId })
    await refetchCheckout({ requestPolicy: 'network-only' })
  }

  return { checkout, lines, quantity, total, checkoutId, addToCart, updateQuantity, removeFromCart }
}
```

- [ ] **Step 4: Ejecutar tests**

```bash
npx vitest run tests/composables/useCart.test.ts
```

Salida esperada: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/composables/useCart.ts tests/composables/useCart.test.ts
git commit -m "feat: implement useCart composable with Saleor checkout persistence"
```

---

## Task 3: CartDrawer y CartItem

**Files:**
- Create: `app/components/cart/CartItem.vue`
- Create: `app/components/cart/CartDrawer.vue`

- [ ] **Step 1: Crear `CartItem.vue`**

```vue
<!-- app/components/cart/CartItem.vue -->
<script setup lang="ts">
import { useCart } from '~/composables/useCart'

interface Line {
  id: string
  quantity: number
  variant: {
    id: string
    name: string
    product: { name: string; slug: string; thumbnail: { url: string; alt: string | null } | null }
    pricing: { price: { gross: { amount: number; currency: string } } | null } | null
  }
}

const { line } = defineProps<{ line: Line }>()
const { updateQuantity, removeFromCart } = useCart()

const price = computed(() => {
  const amount = (line.variant.pricing?.price?.gross?.amount ?? 0) * line.quantity
  return new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', minimumFractionDigits: 0 }).format(amount)
})
</script>

<template>
  <div class="flex gap-4 py-4 border-b border-[--color-border]">
    <NuxtImg
      v-if="line.variant.product.thumbnail"
      :src="line.variant.product.thumbnail.url"
      :alt="line.variant.product.thumbnail.alt || ''"
      class="w-16 h-20 object-cover border border-[--color-border] flex-shrink-0"
    />
    <div class="flex-1 min-w-0">
      <p class="font-body text-sm font-medium text-ink truncate">{{ line.variant.product.name }}</p>
      <p class="font-body text-xs text-muted mt-0.5">{{ line.variant.name }}</p>
      <div class="flex items-center justify-between mt-3">
        <div class="flex items-center gap-2 border border-[--color-border]">
          <button class="px-2 py-1 text-sm" @click="updateQuantity(line.id, line.quantity - 1)">−</button>
          <span class="px-2 font-body text-sm">{{ line.quantity }}</span>
          <button class="px-2 py-1 text-sm" @click="updateQuantity(line.id, line.quantity + 1)">+</button>
        </div>
        <span class="font-body text-sm font-medium">{{ price }}</span>
      </div>
    </div>
    <button class="text-muted hover:text-accent flex-shrink-0" aria-label="Eliminar" @click="removeFromCart(line.id)">
      ×
    </button>
  </div>
</template>
```

- [ ] **Step 2: Crear `CartDrawer.vue`**

```vue
<!-- app/components/cart/CartDrawer.vue -->
<script setup lang="ts">
import { useCart } from '~/composables/useCart'

const { isOpen } = defineProps<{ isOpen: boolean }>()
const emit = defineEmits<{ close: [] }>()
const { lines, total } = useCart()

const formattedTotal = computed(() =>
  new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', minimumFractionDigits: 0 }).format(total.value)
)
</script>

<template>
  <Teleport to="body">
    <Transition name="drawer">
      <div v-if="isOpen" class="fixed inset-0 z-50 flex justify-end">
        <div class="absolute inset-0 bg-ink/40" @click="emit('close')" />
        <div class="relative w-full max-w-md bg-cream flex flex-col shadow-2xl">
          <div class="flex items-center justify-between px-6 py-5 border-b border-[--color-border]">
            <h2 class="font-display text-2xl text-ink">Carrito</h2>
            <button class="text-muted hover:text-ink text-2xl" @click="emit('close')">×</button>
          </div>
          <div class="flex-1 overflow-y-auto px-6">
            <div v-if="lines.length === 0" class="py-16 text-center text-muted font-body text-sm">
              Tu carrito está vacío.
            </div>
            <CartItem v-for="line in lines" :key="line.id" :line="line" />
          </div>
          <div class="px-6 py-6 border-t border-[--color-border]">
            <div class="flex justify-between items-center mb-6">
              <span class="font-body text-sm text-muted">Total</span>
              <span class="font-body text-xl font-medium text-ink">{{ formattedTotal }}</span>
            </div>
            <NuxtLink
              to="/checkout/direccion"
              class="block w-full py-4 bg-ink text-cream text-center font-body text-sm font-medium hover:bg-accent transition-colors duration-200"
              @click="emit('close')"
            >
              Ir al checkout
            </NuxtLink>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.drawer-enter-active,
.drawer-leave-active {
  transition: opacity 200ms ease;
}
.drawer-enter-active .relative,
.drawer-leave-active .relative {
  transition: transform 300ms var(--ease-out-expo);
}
.drawer-enter-from,
.drawer-leave-to {
  opacity: 0;
}
.drawer-enter-from .relative {
  transform: translateX(100%);
}
</style>
```

- [ ] **Step 3: Commit**

```bash
git add app/components/cart/
git commit -m "feat: add CartDrawer and CartItem components"
```

---

## Task 4: Flujo de checkout — paso de dirección

**Files:**
- Create: `app/composables/useCheckout.ts`
- Create: `app/pages/checkout/direccion.vue`

- [ ] **Step 1: Crear `useCheckout.ts`**

```typescript
// app/composables/useCheckout.ts
import { useMutation } from '@urql/vue'
import {
  CheckoutEmailUpdateDocument,
  CheckoutShippingAddressUpdateDocument,
  CheckoutDeliveryMethodUpdateDocument,
} from '~/graphql/generated/graphql'
import { useCart } from '~/composables/useCart'

export function useCheckout() {
  const { checkoutId, refetchCheckout } = useCart()
  const [, updateEmail] = useMutation(CheckoutEmailUpdateDocument)
  const [, updateShippingAddress] = useMutation(CheckoutShippingAddressUpdateDocument)
  const [, updateDeliveryMethod] = useMutation(CheckoutDeliveryMethodUpdateDocument)

  async function setEmail(email: string) {
    if (!checkoutId.value) throw new Error('No hay checkout activo')
    const result = await updateEmail({ checkoutId: checkoutId.value, email })
    if (result.data?.checkoutEmailUpdate?.errors.length) {
      throw new Error(result.data.checkoutEmailUpdate.errors[0].message ?? 'Error al actualizar email')
    }
  }

  async function setShippingAddress(address: {
    firstName: string
    lastName: string
    streetAddress1: string
    city: string
    postalCode: string
    countryArea: string
    country: string
    phone: string
  }) {
    if (!checkoutId.value) throw new Error('No hay checkout activo')
    const result = await updateShippingAddress({
      checkoutId: checkoutId.value,
      address: {
        firstName: address.firstName,
        lastName: address.lastName,
        streetAddress1: address.streetAddress1,
        city: address.city,
        postalCode: address.postalCode,
        countryArea: address.countryArea,
        country: address.country,
        phone: address.phone,
      },
    })
    if (result.data?.checkoutShippingAddressUpdate?.errors.length) {
      throw new Error(result.data.checkoutShippingAddressUpdate.errors[0].message ?? 'Error en dirección')
    }
    await refetchCheckout({ requestPolicy: 'network-only' })
    return result.data?.checkoutShippingAddressUpdate?.checkout
  }

  async function setDeliveryMethod(deliveryMethodId: string) {
    if (!checkoutId.value) throw new Error('No hay checkout activo')
    const result = await updateDeliveryMethod({ checkoutId: checkoutId.value, deliveryMethodId })
    if (result.data?.checkoutDeliveryMethodUpdate?.errors.length) {
      throw new Error(result.data.checkoutDeliveryMethodUpdate.errors[0].message ?? 'Error en método de envío')
    }
    await refetchCheckout({ requestPolicy: 'network-only' })
  }

  return { setEmail, setShippingAddress, setDeliveryMethod }
}
```

- [ ] **Step 2: Crear `app/pages/checkout/direccion.vue`**

```vue
<!-- app/pages/checkout/direccion.vue -->
<script setup lang="ts">
import { useCheckout } from '~/composables/useCheckout'
import { useCart } from '~/composables/useCart'

definePageMeta({ layout: 'checkout' })

const { setEmail, setShippingAddress } = useCheckout()
const { checkout } = useCart()
const router = useRouter()

const form = reactive({
  email: '',
  firstName: '',
  lastName: '',
  streetAddress1: '',
  city: '',
  postalCode: '',
  countryArea: '', // Departamento
  country: 'CO',
  phone: '',
})

const error = ref<string | null>(null)
const saving = ref(false)

async function submit() {
  error.value = null
  saving.value = true
  try {
    await setEmail(form.email)
    await setShippingAddress(form)
    router.push('/checkout/envio')
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Error inesperado'
  } finally {
    saving.value = false
  }
}

// Pre-llenar si ya hay dirección
onMounted(() => {
  const addr = checkout.value?.shippingAddress
  if (addr) {
    form.firstName = addr.firstName
    form.lastName = addr.lastName
    form.streetAddress1 = addr.streetAddress1
    form.city = addr.city
    form.postalCode = addr.postalCode
    form.country = addr.country.code
  }
})
</script>

<template>
  <form class="max-w-lg mx-auto py-12 px-4" @submit.prevent="submit">
    <h1 class="font-display text-3xl text-ink mb-8">Dirección de envío</h1>

    <div v-if="error" class="mb-4 p-3 bg-accent-light text-accent text-sm font-body">
      {{ error }}
    </div>

    <div class="space-y-4">
      <input v-model="form.email" type="email" required placeholder="Correo electrónico"
        class="w-full border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
      <div class="grid grid-cols-2 gap-4">
        <input v-model="form.firstName" required placeholder="Nombre"
          class="border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
        <input v-model="form.lastName" required placeholder="Apellido"
          class="border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
      </div>
      <input v-model="form.streetAddress1" required placeholder="Dirección (ej: Cra 15 # 93-47)"
        class="w-full border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
      <div class="grid grid-cols-2 gap-4">
        <input v-model="form.city" required placeholder="Ciudad"
          class="border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
        <input v-model="form.postalCode" required placeholder="Código postal"
          class="border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
      </div>
      <input v-model="form.countryArea" required placeholder="Departamento"
        class="w-full border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
      <input v-model="form.phone" type="tel" placeholder="Teléfono (ej: +573001234567)"
        class="w-full border border-[--color-border] px-4 py-3 font-body text-sm bg-transparent focus:outline-none focus:border-ink" />
    </div>

    <button type="submit" :disabled="saving"
      class="mt-8 w-full py-4 bg-ink text-cream font-body text-sm font-medium disabled:opacity-50 hover:bg-accent transition-colors duration-200">
      {{ saving ? 'Guardando...' : 'Continuar al envío' }}
    </button>
  </form>
</template>
```

- [ ] **Step 3: Commit**

```bash
git add app/composables/useCheckout.ts app/pages/checkout/
git commit -m "feat: implement checkout address step"
```

---

## Task 5: Paso de métodos de envío

**Files:**
- Create: `app/pages/checkout/envio.vue`

- [ ] **Step 1: Crear la página**

```vue
<!-- app/pages/checkout/envio.vue -->
<script setup lang="ts">
import { useCheckout } from '~/composables/useCheckout'
import { useCart } from '~/composables/useCart'

definePageMeta({ layout: 'checkout' })

const { setDeliveryMethod } = useCheckout()
const { checkout } = useCart()
const router = useRouter()

const methods = computed(() => checkout.value?.availableShippingMethods ?? [])
const selected = ref<string>('')
const error = ref<string | null>(null)
const saving = ref(false)

onMounted(() => {
  const current = checkout.value?.deliveryMethod
  if (current && 'id' in current) selected.value = current.id
  else if (methods.value.length > 0) selected.value = methods.value[0].id
})

function formatPrice(amount: number) {
  return new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', minimumFractionDigits: 0 }).format(amount)
}

async function submit() {
  if (!selected.value) { error.value = 'Selecciona un método de envío'; return }
  saving.value = true
  error.value = null
  try {
    await setDeliveryMethod(selected.value)
    router.push('/checkout/confirmacion')
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Error inesperado'
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <div class="max-w-lg mx-auto py-12 px-4">
    <h1 class="font-display text-3xl text-ink mb-8">Método de envío</h1>

    <div v-if="error" class="mb-4 p-3 bg-accent-light text-accent text-sm font-body">{{ error }}</div>

    <div v-if="methods.length === 0" class="text-muted font-body text-sm">
      No hay métodos de envío disponibles para esta dirección.
    </div>

    <div class="space-y-3">
      <label
        v-for="method in methods"
        :key="method.id"
        class="flex items-center justify-between p-4 border cursor-pointer transition-colors"
        :class="selected === method.id ? 'border-ink bg-ink/5' : 'border-[--color-border]'"
      >
        <div class="flex items-center gap-3">
          <input v-model="selected" type="radio" :value="method.id" class="sr-only" />
          <div class="w-4 h-4 rounded-full border-2 flex items-center justify-center"
            :class="selected === method.id ? 'border-ink' : 'border-muted'">
            <div v-if="selected === method.id" class="w-2 h-2 rounded-full bg-ink" />
          </div>
          <span class="font-body text-sm text-ink">{{ method.name }}</span>
        </div>
        <span class="font-body text-sm font-medium text-ink">
          {{ method.price.amount === 0 ? 'Gratis' : formatPrice(method.price.amount) }}
        </span>
      </label>
    </div>

    <button
      :disabled="saving || !selected"
      class="mt-8 w-full py-4 bg-ink text-cream font-body text-sm font-medium disabled:opacity-50 hover:bg-accent transition-colors duration-200"
      @click="submit"
    >
      {{ saving ? 'Guardando...' : 'Continuar al resumen' }}
    </button>
  </div>
</template>
```

- [ ] **Step 2: Commit**

```bash
git add app/pages/checkout/envio.vue
git commit -m "feat: implement checkout shipping step"
```

---

## Task 6: Página de confirmación de orden

**Files:**
- Create: `app/pages/checkout/confirmacion.vue`

- [ ] **Step 1: Crear la página**

Esta página muestra el resumen final antes del pago. En Fase 2 no hay pasarela, así que el botón de pago quedará deshabilitado con un mensaje "Próximamente".

```vue
<!-- app/pages/checkout/confirmacion.vue -->
<script setup lang="ts">
import { useCart } from '~/composables/useCart'

definePageMeta({ layout: 'checkout' })

const { checkout } = useCart()

const total = computed(() => {
  const amount = checkout.value?.totalPrice.gross.amount ?? 0
  return new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', minimumFractionDigits: 0 }).format(amount)
})
</script>

<template>
  <div class="max-w-lg mx-auto py-12 px-4">
    <h1 class="font-display text-3xl text-ink mb-8">Resumen del pedido</h1>

    <div v-if="checkout">
      <div class="space-y-2 mb-6">
        <div v-for="line in checkout.lines" :key="line.id" class="flex justify-between text-sm font-body">
          <span>{{ line.variant.product.name }} × {{ line.quantity }}</span>
          <span>{{ new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', minimumFractionDigits: 0 }).format((line.variant.pricing?.price?.gross?.amount ?? 0) * line.quantity) }}</span>
        </div>
      </div>

      <div class="border-t border-[--color-border] pt-4 flex justify-between font-body font-medium">
        <span>Total</span>
        <span class="text-xl">{{ total }}</span>
      </div>

      <div class="mt-8 p-4 border border-[--color-border] bg-accent-light text-accent text-sm font-body">
        Integración de pagos disponible próximamente (Fase 3).
      </div>

      <button disabled
        class="mt-4 w-full py-4 bg-ink/30 text-cream font-body text-sm font-medium cursor-not-allowed">
        Pagar (próximamente)
      </button>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Commit**

```bash
git add app/pages/checkout/confirmacion.vue
git commit -m "feat: add checkout confirmation/summary page (payment placeholder)"
```

---

## Task 7: Inicializar monorepo `licona-saleor-apps`

**Files:**
- Create: `licona-saleor-apps/package.json`, `pnpm-workspace.yaml`, `apps/envios/package.json`

- [ ] **Step 1: Crear el monorepo**

```bash
mkdir licona-saleor-apps && cd licona-saleor-apps
git init
```

```json
// package.json
{
  "name": "licona-saleor-apps",
  "private": true,
  "engines": { "node": ">=22" }
}
```

```yaml
# pnpm-workspace.yaml
packages:
  - 'apps/*'
  - 'packages/*'
```

- [ ] **Step 2: Crear estructura de `app-envios`**

```bash
mkdir -p apps/envios/src/webhooks apps/envios/src/providers
```

```json
// apps/envios/package.json
{
  "name": "@licona/app-envios",
  "version": "0.1.0",
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

- [ ] **Step 3: Commit**

```bash
git add .
git commit -m "feat: initialize licona-saleor-apps monorepo with app-envios scaffold"
```

---

## Task 8: app-envios webhook handler

**Files:**
- Create: `apps/envios/src/index.ts`
- Create: `apps/envios/src/webhooks/shipping-list-methods.ts`

- [ ] **Step 1: Crear el servidor Fastify**

```typescript
// apps/envios/src/index.ts
import Fastify from 'fastify'
import { shippingListMethodsHandler } from './webhooks/shipping-list-methods.js'

const app = Fastify({ logger: true })

// Manifest de la App (Saleor lo necesita para instalarla)
app.get('/api/manifest', async () => ({
  id: 'app.licona.envios',
  version: '1.0.0',
  name: 'Licona Envíos CO',
  about: 'Integración con Servientrega, Coordinadora y TCC',
  permissions: ['MANAGE_SHIPPING'],
  appUrl: process.env.APP_URL ?? 'http://localhost:3001',
  webhooks: [
    {
      name: 'Shipping methods for checkout',
      syncEvents: ['SHIPPING_LIST_METHODS_FOR_CHECKOUT'],
      isActive: true,
      targetUrl: `${process.env.APP_URL ?? 'http://localhost:3001'}/api/webhooks/shipping-list-methods`,
    },
  ],
  extensions: [],
  requiredSaleorVersion: '>=3.22.0',
}))

app.post('/api/webhooks/shipping-list-methods', shippingListMethodsHandler)

const PORT = parseInt(process.env.PORT ?? '3001', 10)
app.listen({ port: PORT, host: '0.0.0.0' }, (err) => {
  if (err) { app.log.error(err); process.exit(1) }
})
```

- [ ] **Step 2: Crear el webhook handler**

```typescript
// apps/envios/src/webhooks/shipping-list-methods.ts
import type { FastifyRequest, FastifyReply } from 'fastify'
import { createHmac, timingSafeEqual } from 'node:crypto'

interface ShippingCheckoutPayload {
  checkout: {
    id: string
    shippingAddress: {
      city: string
      postalCode: string
      countryArea: string
    } | null
    lines: Array<{
      quantity: number
      variant: {
        weight: { value: number; unit: string } | null
        product: { weight: { value: number; unit: string } | null }
      }
    }>
  }
}

function verifyWebhookSignature(payload: string, signature: string, secret: string): boolean {
  const expected = createHmac('sha256', secret).update(payload).digest('hex')
  const sigBuf = Buffer.from(signature, 'hex')
  const expBuf = Buffer.from(expected, 'hex')
  return sigBuf.length === expBuf.length && timingSafeEqual(sigBuf, expBuf)
}

function calculateTotalWeightKg(lines: ShippingCheckoutPayload['checkout']['lines']): number {
  return lines.reduce((total, line) => {
    const weight = line.variant.weight?.value ?? line.variant.product.weight?.value ?? 0.5
    return total + weight * line.quantity
  }, 0)
}

export async function shippingListMethodsHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const secret = process.env.SALEOR_WEBHOOK_SECRET ?? ''
  const signature = (request.headers['saleor-signature'] as string) ?? ''
  const rawBody = JSON.stringify(request.body)

  if (!verifyWebhookSignature(rawBody, signature, secret)) {
    return reply.status(401).send({ error: 'Invalid signature' })
  }

  const payload = request.body as ShippingCheckoutPayload
  const { shippingAddress, lines } = payload.checkout

  if (!shippingAddress) {
    return reply.send([])
  }

  const weightKg = calculateTotalWeightKg(lines)

  // Tarifas base (en producción estas vendrían de la API de cada operador)
  // Servientrega: tarifa base 8.000 COP + 2.000 por kg adicional
  const servientregaPrice = 8000 + Math.max(0, weightKg - 1) * 2000

  // Coordinadora: tarifa base 9.000 COP + 1.800 por kg adicional
  const coordinadoraPrice = 9000 + Math.max(0, weightKg - 1) * 1800

  // TCC: tarifa base 10.000 COP + 1.500 por kg adicional
  const tccPrice = 10000 + Math.max(0, weightKg - 1) * 1500

  return reply.send([
    {
      id: 'servientrega-estandar',
      name: 'Servientrega Estándar (3-5 días)',
      amount: Math.round(servientregaPrice),
      currency: 'COP',
      maximumDeliveryDays: 5,
      minimumDeliveryDays: 3,
    },
    {
      id: 'coordinadora-estandar',
      name: 'Coordinadora Estándar (3-5 días)',
      amount: Math.round(coordinadoraPrice),
      currency: 'COP',
      maximumDeliveryDays: 5,
      minimumDeliveryDays: 3,
    },
    {
      id: 'tcc-express',
      name: 'TCC Express (1-2 días)',
      amount: Math.round(tccPrice),
      currency: 'COP',
      maximumDeliveryDays: 2,
      minimumDeliveryDays: 1,
    },
  ])
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/envios/src/
git commit -m "feat: implement app-envios with SHIPPING_LIST_METHODS_FOR_CHECKOUT webhook"
```

---

## Task 9: Desplegar app-envios en Railway

**Files:**
- Create: `apps/envios/Dockerfile`

- [ ] **Step 1: Crear Dockerfile**

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
EXPOSE 3001
CMD ["node", "dist/index.js"]
```

- [ ] **Step 2: Crear servicio en Railway**

New Service → GitHub Repo → `licona-saleor-apps`, Root Directory: `apps/envios`.

Variables:
```
APP_URL=https://envios.apps.licona-store.com
SALEOR_WEBHOOK_SECRET=<generar con openssl rand -hex 32>
PORT=3001
```

- [ ] **Step 3: Instalar la App en Saleor**

En el Dashboard de Saleor → Apps → Install custom app → URL del manifest: `https://envios.apps.licona-store.com/api/manifest`.

- [ ] **Step 4: Verificar**

Desde el storefront, agregar un producto al carrito, ir a `/checkout/direccion`, completar la dirección, ir a `/checkout/envio`. Deben aparecer los 3 métodos de envío con sus precios.

- [ ] **Step 5: Commit**

```bash
git add apps/envios/Dockerfile
git commit -m "feat: add Dockerfile for app-envios Railway deployment"
```

---

## Verificación final de Fase 2

- [ ] Agregar producto al carrito desde el PDP → aparece en el CartDrawer.
- [ ] Flujo completo hasta resumen: carrito → dirección → método de envío (con tarifas de las 3 transportadoras) → confirmación.
- [ ] El carrito persiste al recargar la página (cookie `saleor-checkout-id`).
- [ ] El estado del checkout es visible en el Dashboard de Saleor.
- [ ] `npx vitest run` pasa todos los tests.
- [ ] Actualizar `STATUS.md`: Fase 2 → ✅ Completada.
