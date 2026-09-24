# Runbook: route rollback (microservice → monolith)

```text
/users currently -> user-service
        |
incident detected (5xx, latency, wrong data, contract break)
        |
validate the monolith can safely receive the traffic
        |
switch:  /users -> monolith        (hot reload, seconds)
        |
validate (same URL, X-Upstream-Service: monolith)
        |
monitor (15 min) + write down what happened
```

## 1. Decide

Roll back when the route you switched is the likely cause. The signals are
`ApiGatewayHigh5xxRatio` or `ApiGatewayUpstreamUnhealthy` firing for that
upstream, a p95 regression, stale or wrong data, or a broken client. When in
doubt, roll back first and investigate afterwards: the monolith is still the
source of truth.

## 2. Validate the monolith can take the traffic

```powershell
.\scripts\health-check.ps1      # Monolith must be UP (Kong's own health check)
.\scripts\route-status.ps1
```

In Grafana: MONOLITH is UP and its database is healthy.

## 3. Switch

```powershell
# one domain (reads + writes by default)
.\scripts\route-users-to-monolith.ps1 -Reason "INC-42: 5xx on user-service"
.\scripts\route-sales-to-monolith.ps1 -Reason "INC-42"

# everything, one command (mode-1-all-monolith, the boot default)
.\scripts\rollback-all-to-monolith.ps1 -Reason "INC-42"
```

Rollback to the monolith is **never** blocked by a guard. It is a hot reload,
with no Kong restart. If the Admin API itself is unreachable (Kong is down), note
that a restarted Kong boots from `state/kong.yml`, the last *applied* routing.
To force the default in that situation:

```powershell
Remove-Item .\state\kong.yml, .\state\routing.json   # back to kong/kong.default.yml
docker compose up -d
```

## 4. Validate

```powershell
$r = Invoke-WebRequest http://localhost:8088/users/1 -UseBasicParsing
$r.Headers['X-Upstream-Service']      # -> monolith
.\scripts\route-status.ps1            # users -> monolith, "in sync"
```

In Grafana (**Strangler Routing**), the traffic area goes back to `monolith`
and `gateway_route_on_monolith{route="users-read"}` returns to 1.

## 5. Monitor

Watch the 5xx ratio and latency back at baseline for 15 minutes, and write
the entry in the incident record. `state/history.log` already has the
timestamp, the user, the change and your `-Reason`.

## IMPORTANT: a route rollback does not roll back data

Rolling back **reads** is free: the monolith always had the data, and the
microservice only held a replica.

Rolling back **writes** after a write cutover is different:

```text
t0  POST /users -> user-service   (write cutover)   row id=500 exists ONLY in user-service
t1  rollback: users-write -> monolith
t2  GET /users/500 -> monolith -> 404        the row is not there
t3  POST /users -> monolith creates id=500?   possible PK collision with the replica
```

- There is **no** user-service → monolith sync. CDC only goes monolith → Kafka → microservices.
- Rows created or updated in the microservice while it owned writes must be
  **reconciled explicitly**: export them from the service's DB, decide per row
  (re-insert into the monolith / discard), and check id-sequence collisions.
  `migration-tool` compares both sides and lists the divergences.
- The switch script warns about this whenever a write route goes back to
  the monolith, and a write cutover cannot be started without
  `-AcceptWriteDivergence`.

**The gateway never does this for you.** There is no dual write, no automatic
fallback of a POST to the monolith, and no replay. Those would create silent
inconsistency, which is worse than an explicit error.
