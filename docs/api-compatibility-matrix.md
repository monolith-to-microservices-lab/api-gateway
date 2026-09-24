# API compatibility matrix: monolith vs microservices

Written **before** any routing was implemented and derived from the code on
`main` **and** from real requests against the running lab (2026-09-23), with
the same rows read from both sides. Nothing here is assumed. The
machine-readable version is [`routing/compatibility.json`](../routing/compatibility.json),
and the switch scripts derive their guards from that file.

Sources inspected:

| Service | Routes | Schemas / errors |
|---|---|---|
| monolith | `backend/app/routers/users.py`, `sales.py` | `schemas/user.py`, `schemas/sale.py`, FastAPI default errors |
| user-service | `app/routes/users.py`, `internal.py` | `app/schemas.py`, custom handlers in `app/main.py` |
| sales-service | `app/routes/sales.py`, `internal.py` | `app/schemas.py`, custom handlers in `app/main.py` |

## Users

| PATH | METHOD | MONOLITH | USER-SERVICE | COMPATIBLE? | NOTES |
|---|---|---|---|---|---|
| `/users` | GET | yes | yes | **yes** | Both return a plain JSON array of `{id, name, created_at}` ordered by id, with no pagination on either side. Data on user-service is the CDC replica (eventually consistent; observed < 1 s). |
| `/users/{id}` | GET | yes | yes | **yes (success path)** | 200 bodies were byte-identical for the same row (`{"id":167,"name":"compat_probe_user","created_at":"2026-09-23T22:21:55.925493Z"}` on both). 404 and 422 codes match, but their **bodies differ**: monolith `{"detail": "..."}`, user-service `{"error": {"code", "message", "request_id"}}`. |
| `/users` | HEAD | 405 | 405 | same | Neither backend implements HEAD. |
| `/users` | POST | yes | yes | **no** | Same request `{name}` and same 201 body. But the monolith trims the name and returns **422 for a blank name**, while user-service **accepts `"   "` with 201**, a real difference observed live. Above all, a POST to user-service is **never synced back** to the monolith (source of truth). |
| `/users/{id}` | PUT | 405 | yes | n/a | Exists only on user-service. |
| `/users/{id}` | DELETE | 405 | yes | n/a | Exists only on user-service. The monolith has no user delete endpoint (the E2E suite deletes via SQL). |
| `/users/{id}` | PATCH | 405 | 405 | same | |
| `/internal/users/import` | POST | - | yes | **not routed** | A migration-only surface. The gateway never exposes it. |

Headers: both backends honour and echo `X-Request-ID` and return
`application/json`. Only the monolith sends CORS headers (`CORSMiddleware`,
`allow_credentials=True`).

## Sales

| PATH | METHOD | MONOLITH | SALES-SERVICE | COMPATIBLE? | NOTES |
|---|---|---|---|---|---|
| `/sales` | GET | yes | yes | **no** | The monolith returns **every** row (1008 at the time of writing). sales-service is **paginated**: `limit` defaults to 100 (max 1000, `limit=5000` → 422), plus `offset`. Each item also lacks `user_name` (see the next row). |
| `/sales/{id}` | GET | yes | yes | **no** | The monolith's `SaleRead` has **`user_name`** (a JOIN with users); sales-service has no such field. **The frontend renders `sale.user_name`** (`SalesView.vue`), so this switch breaks the UI. 404 bodies differ (`{"detail"}` vs `{"detail", "correlation_id"}`), and 422 bodies differ (`detail` list vs `detail: "validation error"` + `errors`). |
| `/sales` | POST | yes | yes | **no** | Same request `{user_id, item_name, quantity}` and the same validation rules. However, the monolith returns **404 when the user does not exist**, whereas sales-service does **not** check this (`user_id` is only a logical reference). The 201 body has no `user_name`. Writes are **never synced back** to the monolith. |
| `/sales/{id}` | PUT | 405 | yes | n/a | Exists only on sales-service. |
| `/sales/{id}` | DELETE | 405 | yes | n/a | Exists only on sales-service. |
| `/internal/sales/import` | POST | - | yes | **not routed** | Migration-only. |

## Consequences for routing (what the gateway does with this)

| Route | → microservice | Guard in the scripts |
|---|---|---|
| `users-read` (GET) | **allowed**, the first Strangler step | none; the matrix shows the same contract on the success path |
| `users-write` (POST/PUT/PATCH/DELETE) | only as an explicit, controlled test | `-AcceptWriteDivergence` **and** `-AcceptIncompatibility` |
| `sales-read` (GET) | only knowingly | `-AcceptIncompatibility` (breaks the frontend's `user_name` column and truncates lists at 100) |
| `sales-write` | only as an explicit, controlled test | `-AcceptWriteDivergence` **and** `-AcceptIncompatibility` |

Why **PATH + METHOD** routing and not whole-path routing: the matrix says
reads can move before writes. `GET /users*` is compatible and served from a
CDC replica, while `POST /users` must stay on the source of truth until a
reverse sync or ownership change exists. Whole-path routing would force both
to move together.

### What would make sales reads switchable

This is a backend change in `sales-service`, not something the gateway
should do. Options are adding `user_name` (denormalised via the users CDC
topic, or composed from user-service), plus a non-paginated or
monolith-compatible list mode. Translating response bodies inside the gateway
would hide a domain gap in the edge layer. It was deliberately not done.

### Error-body differences

Clients that only branch on the **status code** (the lab's frontend reads
`response.data.detail` for messages and falls back to a generic text) keep
working on `users-read`. A client that parses user-service's `error.message`
would not, so read it as "compatible for this lab's clients", not
"byte-compatible".
