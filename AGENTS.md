# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

Headless e-commerce platform for the Colombian market. **Saleor 3.22** (Python/Django/GraphQL) as the commerce backend, **Nuxt 4** as the storefront, Colombian payment gateways (Wompi, PayU, MercadoPago) as independent Payment Apps, and everything deployed on **Railway**.

**Always check `docs/superpowers/plans/STATUS.md` at the start of every session** to see the current phase, what's done, and what's next.

---

## Repositories

This is the `licona-saleor` repo (Saleor fork). The other two repos are yet to be created:

| Repo | Purpose |
|---|---|
| **`licona-saleor`** ← you are here | Fork of `saleor/saleor` — backend API, Celery worker, beat |
| `licona-storefront` | Nuxt 4 storefront |
| `licona-saleor-apps` | Monorepo of Saleor Apps (payment gateways, shipping, invoicing) |

---

## Architecture

```
Nuxt 4 Storefront  →  Saleor Core API (GraphQL)  ←  Saleor Apps (microservices)
                              ↓                              ↓
                       Postgres 16              Payment gateways (CO):
                       Redis 7                  Wompi · PayU · MercadoPago
                       Cloudflare R2            Envíos · Facturación DIAN
```

**Key architectural decisions:**
- Apps over plugins (Saleor plugins are deprecated — all extensions are independent microservices)
- Dashboard is untouched — extended via App iframe extensions only
- Transactions API (not legacy Payments API) for all payment integrations
- COP currency with `decimal_places=0` (Colombian peso has no practical decimal in billing)
- JWT tokens in httpOnly cookies (never localStorage)
- APL for Apps: `UpstashRedisAPL` in production (Railway filesystem doesn't persist)

---

## Project Plans

All implementation plans are in `docs/superpowers/plans/`:

| File | Coverage |
|---|---|
| `STATUS.md` | **Master tracking file** — current phase, repos, services, session log |
| `2026-04-16-fase0-infraestructura.md` | Fork setup, GitHub Actions, Railway services, domains |
| `2026-04-16-fase1-catalogo-storefront.md` | Nuxt 4 scaffold, GraphQL client, PLP/PDP, ISR, brand tokens |
| `2026-04-16-fase2-checkout-envios.md` | Cart, checkout flow, `app-envios-co` (Servientrega/Coordinadora/TCC) |
| `2026-04-16-fase3-pasarelas-co.md` | Wompi, PayU, MercadoPago Payment Apps (Transactions API) |
| `2026-04-16-fase4-cuenta-facturacion.md` | Customer auth, order history, `app-facturacion-co` (Siigo/DIAN) |
| `2026-04-16-fase5-golive.md` | Lighthouse ≥90, k6 load tests, WCAG 2.2 AA, go-live checklist |

To execute a plan use the `superpowers:executing-plans` or `superpowers:subagent-driven-development` skill.

---

## Tech Stack per Repo

**`licona-saleor` (Saleor fork)**
- Python 3.12, Django, Celery, Gunicorn + Uvicorn workers
- `python manage.py migrate` — run migrations
- `celery -A saleor worker` — start worker
- `celery -A saleor beat` — start scheduler

**`licona-storefront` (Nuxt 4)**
- Node 22, Vue 3.5, TypeScript strict, `@urql/vue`, Tailwind CSS v4
- `npm run dev` — development server
- `npm run codegen` — regenerate GraphQL types from Saleor schema
- `npm run build` — production build
- `npx vitest run` — unit tests
- `npx playwright test` — E2E tests

**`licona-saleor-apps` (pnpm monorepo)**
- `pnpm install` — install all workspace deps
- Each app: `pnpm --filter @licona/app-wompi dev`
- Each app test: `pnpm --filter @licona/app-wompi test`

---

## Saleor Upstream Sync Rule

**CRITICAL:** Saleor only guarantees zero-downtime migrations between consecutive minor versions. To upgrade from 3.19 → 3.21 you must go through 3.20 first. Never skip minor versions.

The GitHub Actions workflow `sync-upstream.yml` opens a weekly PR when a new stable tag is detected. Review it, run migration tests, then merge.

All local changes to the fork must be documented in `UPGRADE_NOTES.md` in the fork root.

---

## Payment App Pattern

Every payment gateway App implements these 6 synchronous Saleor webhooks:

1. `PAYMENT_GATEWAY_INITIALIZE_SESSION` — return public key + enabled methods
2. `TRANSACTION_INITIALIZE_SESSION` — create transaction in gateway, return redirect URL
3. `TRANSACTION_PROCESS_SESSION` — handle additional steps (3DS, etc.)
4. `TRANSACTION_CHARGE_REQUESTED` — capture an authorization
5. `TRANSACTION_REFUND_REQUESTED` — issue a refund
6. `TRANSACTION_CANCELATION_REQUESTED` — void an authorization

Plus one incoming webhook from the gateway (e.g. `wompi-incoming`) that calls `transactionEventReport` on Saleor.

Amount conversion: Saleor sends COP amounts (e.g. `120000`). Wompi expects centavos (`12000000`). Multiply by 100 in the App. PayU and MercadoPago have their own conventions — check each provider's docs.

---

## Storefront Design Tokens

The storefront uses a deliberate editorial aesthetic (not generic SaaS):
- **Display font:** Fraunces (serif) — headlines only
- **Body font:** Satoshi (geometric sans) — UI and body text
- **Background:** `#F4EFE6` (warm cream)
- **Ink:** `#1A1613` (deep near-black)
- **Accent:** `#C44536` (terracotta)
- Tokens defined in `app/assets/styles/brand.css`

---

## Railway Services

| Service | Image/Source | Start command |
|---|---|---|
| `saleor-api` | `licona-saleor` repo | `gunicorn --bind 0.0.0.0:$PORT ... saleor.asgi:application` |
| `saleor-worker` | same image | `celery -A saleor worker -E --concurrency=4` |
| `saleor-beat` | same image | `celery -A saleor beat` |
| `saleor-dashboard` | `ghcr.io/saleor/saleor-dashboard:3.22.x` | (official image) |
| `storefront` | `licona-storefront` repo | `node .output/server/index.mjs` |
| `app-wompi` | `licona-saleor-apps` / `apps/wompi` | `node server.js` |
| `app-envios` | `licona-saleor-apps` / `apps/envios` | `node dist/index.js` |
| `app-facturacion` | `licona-saleor-apps` / `apps/facturacion` | `node dist/index.js` |

Internal services communicate via Railway's private IPv6 network (no public ports needed for Postgres/Redis).
