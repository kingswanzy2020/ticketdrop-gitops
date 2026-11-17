#!/usr/bin/env bash
# Checks that the local stack is whole, and exits non-zero naming what is not:
#   scripts/check.sh
# rebuild.sh runs it at the end; run it on its own at any time.

source "$(dirname "$0")/lib.sh"

require_context

problems=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; problems=$((problems + 1)); }
# Retries a check for up to $1 seconds, for things that settle just after a rollout.
eventually() {
  local secs=$1; shift
  for _ in $(seq 1 $((secs / 2))); do "$@" && return 0; sleep 2; done
  "$@"
}

printf '\n%s checks\n' "$(date +%T)"

applied() { [ "$(kubectl get "$1" -n data -o json | jq '[.items[] | select(.status.applied != true)] | length')" -eq 0 ] \
  && [ "$(kubectl get "$1" -n data --no-headers | wc -l)" -eq 5 ]; }
for k in databaserole database; do
  if eventually 60 applied $k; then ok "5 ${k}s applied"; else
    bad "${k}s not all applied:"; kubectl get $k -n data; fi
done

for s in $SVCS; do
  [ "$s" = fulfillment ] && continue
  r="$(kubectl get deploy "$s" -n ticketdrop -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  a="$(kubectl get deploy "$s" -n ticketdrop -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  [ -n "$r" ] || { bad "$s has no Deployment"; continue; }
  if [ "${a:-0}" -eq "$r" ]; then ok "$s $a/$r available"; else bad "$s ${a:-0}/$r available"; fi
done

so="$(kubectl get scaledobject fulfillment -n ticketdrop -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [ "$so" = True ]; then ok "fulfillment ScaledObject Ready"; else bad "fulfillment ScaledObject Ready is '${so}'"; fi

gw="$(kubectl get gateway ticketdrop -n traefik -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
if [ "$gw" = True ]; then ok "Gateway Programmed"; else bad "Gateway Programmed is '${gw}'"; fi

np="$(kubectl get netpol -n ticketdrop --no-headers 2>/dev/null | wc -l)"
if [ "$np" -eq 11 ]; then ok "11 NetworkPolicies"; else bad "$np NetworkPolicies, expected 11"; fi

leaders() {
  local n=0 p
  for p in $(kubectl get pods -n ticketdrop -l app.kubernetes.io/name=scheduler --field-selector=status.phase=Running -o name); do
    kubectl get --raw "/api/v1/namespaces/ticketdrop/pods/${p#pod/}:9090/proxy/metrics" | grep -q '^scheduler_leader 1' && n=$((n + 1))
  done
  [ "$n" -eq 1 ]
}
if eventually 30 leaders; then ok "one scheduler leads"; else bad "not exactly one scheduler leader"; fi

body="$(curl -s -w '\n%{http_code}' localhost:8088/v1/drops/x/availability || true)"
if [ "$(tail -1 <<<"$body")" = 404 ] && head -1 <<<"$body" | jq -e .error >/dev/null 2>&1; then
  ok "gateway answers: $(head -1 <<<"$body" | jq -r .error)"
else bad "localhost:8088/v1/drops/x/availability gave: $body"; fi

code="$(curl -s -o /dev/null -w '%{http_code}' localhost:8088/ || true)"
if [ "$code" = 200 ]; then ok "shopfront 200"; else bad "shopfront gave $code"; fi

echo
kubectl get pods -n ticketdrop
echo
if [ "$problems" -eq 0 ]; then echo "all checks passed"; else fail "$problems check(s) failed"; fi
