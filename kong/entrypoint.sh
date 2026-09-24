#!/bin/sh
# ---------------------------------------------------------------------------
# Chooses which declarative config Kong boots with, then hands over to the
# image's own entrypoint.
#
#   state/kong.yml present  -> the routing last APPLIED by scripts/*.ps1
#                              (a restart must not silently change routing,
#                              least of all move writes back and forth)
#   otherwise               -> kong/kong.default.yml = mode-1-all-monolith
#
# The runtime switch itself never restarts Kong: scripts POST the new config
# to the Admin API /config (atomic hot reload) and write state/ afterwards.
# ---------------------------------------------------------------------------
set -eu

STATE_CONFIG=/gateway/state/kong.yml
DEFAULT_CONFIG=/gateway/kong/kong.default.yml

if [ -s "$STATE_CONFIG" ]; then
  KONG_DECLARATIVE_CONFIG="$STATE_CONFIG"
  echo "api-gateway: booting with the last APPLIED routing ($STATE_CONFIG)"
else
  KONG_DECLARATIVE_CONFIG="$DEFAULT_CONFIG"
  echo "api-gateway: no applied routing found, booting the DEFAULT ($DEFAULT_CONFIG: every route -> monolith)"
fi
export KONG_DECLARATIVE_CONFIG

exec /docker-entrypoint.sh kong docker-start
