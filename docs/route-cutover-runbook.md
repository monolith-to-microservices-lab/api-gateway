# Runbook: route cutover (monolith → microservice)

**Scope:** moving one gateway route, for example `users-read`, from the
monolith to its microservice. **Default path:** READS first. Moving writes is
a *write cutover* and has its own gate in step 3.

> The real cutover is **not** done in this phase. The monolith is still the
> source of truth, and CDC only flows *monolith → Kafka → microservices*.
> This runbook is the process to follow when it is done.

All commands run from the `api-gateway` repo in PowerShell.

## 0. Pre-conditions (go / no-go)

- [ ] The route is compatible, or the incompatibility is understood and
      accepted, per [api-compatibility-matrix.md](api-compatibility-matrix.md).
- [ ] You know the rollback command (step 8) and who decides to use it.
- [ ] Grafana is open on **API Gateway | Strangler Routing** and
      **API Gateway | Overview**.

## 1. Check health

```powershell
.\scripts\health-check.ps1        # must end with: OVERALL  HEALTHY
.\scripts\route-status.ps1        # current routing, "in sync", upstream health
```

The **target** service must show `UP` (Kong's active health check), and
"Persisted routing" must be `IN SYNC`. Drift means someone changed Kong
outside the scripts; stop and investigate.

## 2. Check CDC lag

The microservice serves a **replica**. Reads are only as fresh as CDC:

```powershell
# from observability-infrastructure (Git Bash / WSL):  ./scripts/health-check.sh
#   User Consumer Lag       0
#   User CDC Last Event     <few>s ago
```

In Grafana (**Kafka | Migration Pipeline**, **User CDC | End-to-End**):

- consumer lag for `user-service-cdc` is ~0 and stable
- p95 end-to-end CDC latency is < 1 s
- the connector is `RUNNING`, and the replication slot is active

No-go if lag grows, the connector is not RUNNING, or the consumer is erroring.

## 3. Check destination consistency

Compare source and replica **before** sending traffic:

```powershell
# row counts
(Invoke-RestMethod http://localhost:8000/users).Count   # monolith (direct)
(Invoke-RestMethod http://localhost:8001/users).Count   # user-service (direct)

# same rows, same content (sample a few ids, including the latest)
Invoke-RestMethod http://localhost:8000/users/1
Invoke-RestMethod http://localhost:8001/users/1
```

For a full reconciliation, use `migration-tool` (it compares legacy vs
destination and reports divergences).

**Write cutover gate (writes only):** do not continue unless *all* of these hold:

- a reverse path (microservice → monolith) or an ownership change exists, and
- everything still reading the monolith (sales JOINs, reports) can live with it, and
- the switch is done with `-AcceptWriteDivergence`, written into the change
  record, knowing that **rollback will not bring those rows back** (see the
  rollback runbook).

## 4. Switch the route

```powershell
# reads only (the normal Strangler step)
.\scripts\route-users-to-service.ps1 -Reason "CHG-123 users reads to user-service"

# or a named, versioned mode
.\scripts\set-routing-profile.ps1 -List
.\scripts\set-routing-profile.ps1 -Name mode-2r-users-reads-service -Reason "CHG-123"
```

What happens: the template is rendered → `POST /config` on the Admin API.
Kong validates the whole document and swaps it atomically, with no restart and
no dropped connections. The runtime is read back and verified, and only then is
the state persisted to `state/` (so a Kong restart keeps it) and appended to
`state/history.log`. If Kong rejects the config, **nothing changes**.

Guards refuse known-risky changes without the explicit flags
(`-AcceptIncompatibility`, `-AcceptWriteDivergence`).

## 5. Monitor gateway metrics (first 5-15 minutes)

**API Gateway | Overview / Strangler Routing:**

- "Where the traffic actually goes": the area moves to the service
- 5xx ratio for the route stays ~0 (the alert `ApiGatewayHigh5xxRatio` is > 5%)
- upstream p95 of the service vs the monolith's before the switch
- 4xx by route/code: new 404/422 patterns point to contract differences

## 6. Monitor service metrics

- the service's own dashboard and logs (Loki: `{compose_project="user-service"}`)
- its database (connections, errors) in **Migration | PostgreSQL**
- CDC lag keeps ~0 (reads must stay fresh)

## 7. Validate requests

Use the **same public URL** before and after the switch:

```powershell
$r = Invoke-WebRequest http://localhost:8088/users/1 -UseBasicParsing
$r.StatusCode; $r.Headers['X-Upstream-Service']; $r.Headers['X-Request-ID']; $r.Content
```

`X-Upstream-Service` is lab-only and tells you who answered. Follow one
`X-Request-ID` through Loki (gateway access line → service log) and one
trace in Tempo (`api-gateway` span → service span).

## 8. Rollback if necessary

Criteria (any of): the 5xx ratio for the route is above 1% for 2 min, p95 is
worse than 2x the monolith baseline, data-freshness complaints, or a
contract break in a client.

```powershell
.\scripts\route-users-to-monolith.ps1 -Reason "CHG-123 rollback: <why>"
```

Details: [route-rollback-runbook.md](route-rollback-runbook.md).
