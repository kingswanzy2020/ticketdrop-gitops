#!/usr/bin/env bash
# Deletes everything the rebuild creates, in the order that lets each operator
# clear its own finalizers:
#   scripts/teardown.sh          asks before deleting
#   scripts/teardown.sh --yes    does not ask
# Every database in the data namespace is lost: the volume's reclaim policy is
# Delete. The passwords in secrets/ are kept, so a rebuild reuses them.
# CRDs are left in place on purpose (CloudNativePG keeps its own, and the
# Gateway API CRDs are applied separately).

source "$(dirname "$0")/lib.sh"

require_context

if [ "${1:-}" != "--yes" ]; then
  printf 'This deletes ticketdrop, data (every database), keda, traefik and cnpg-system on %s.\nType yes to go on: ' "$KUBE_CONTEXT"
  read -r answer
  [ "$answer" = "yes" ] || fail "nothing deleted"
fi

date
step "teardown starts"
run "kubectl get pods -A | grep -v kube-system"
run "helm list -A -a"
wait_no_terminating 5

# 1. The services first, while KEDA still has its RoleBinding in ticketdrop:
#    deleting the namespace first takes away KEDA's right to drop its finalizer.
for s in $SVCS; do
  run "helm uninstall $s -n ticketdrop --wait --ignore-not-found"
done
if has_kind scaledobjects.keda.sh; then
  run "kubectl get scaledobject,triggerauthentication -n ticketdrop --no-headers 2>/dev/null | wc -l"
  left="$(kubectl get scaledobject,triggerauthentication -n ticketdrop --no-headers 2>/dev/null | wc -l)"
  [ "$left" -eq 0 ] || fail "KEDA objects are still in ticketdrop after the uninstalls"
fi

# 2. The ticketdrop namespace: only Secrets, NetworkPolicies and the HTTPRoute
#    are left, none with a finalizer.
run "kubectl delete ns ticketdrop --ignore-not-found --timeout=120s"

# 3. data while CloudNativePG still runs: it clears cnpg.io/deleteDatabase.
run "kubectl delete ns data --ignore-not-found --timeout=180s"

# 4. The operators, with Helm, so their cluster-wide objects (GatewayClass,
#    webhooks, APIServices, ClusterRoles) go too. Then their namespaces.
run "helm uninstall keda -n keda --ignore-not-found"
run "helm uninstall traefik -n traefik --wait --ignore-not-found"
run "helm uninstall cnpg -n cnpg-system --wait --ignore-not-found"
run "kubectl delete ns keda traefik cnpg-system --ignore-not-found --timeout=180s"

# 5. Nothing left behind.
wait_no_terminating 30
run "kubectl get ns"
run "helm list -A -a"
left="$(helm list -A -a -q | wc -l)"
[ "$left" -eq 0 ] || fail "helm releases are left: $(helm list -A -a -q | xargs)"
run "kubectl get gatewayclass,validatingwebhookconfiguration,mutatingwebhookconfiguration -o name"
leftovers="$(kubectl get gatewayclass,validatingwebhookconfiguration,mutatingwebhookconfiguration -o name | grep -Ei 'keda|cnpg|traefik' || true)"
[ -z "$leftovers" ] || fail "left behind: $leftovers"

step "teardown done"
