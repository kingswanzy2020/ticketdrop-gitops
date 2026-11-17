#!/usr/bin/env bash
# Builds the whole local stack from the files in this repo, then checks it:
#   scripts/rebuild.sh
#   scripts/rebuild.sh 2>&1 | tee ../ticketdrop/docs/evidence/phase-2/<name>.txt
# Meant for an empty cluster (after scripts/teardown.sh), but every step can be
# run again over an existing stack. Needs the ticketdrop/<service>:dev images
# on the node (Phase 2 step 3) and the Helm repos cnpg, kedacore and traefik.

source "$(dirname "$0")/lib.sh"

require_context
for r in cnpg kedacore traefik; do
  helm repo list -o json | jq -e --arg r "$r" 'any(.[]; .name == $r)' >/dev/null \
    || fail "helm repo $r is missing (helm repo add)"
done
if command -v docker >/dev/null; then
  for s in $SVCS; do
    docker image inspect "ticketdrop/$s:dev" >/dev/null 2>&1 || fail "image ticketdrop/$s:dev is not built"
  done
fi
# A namespace being deleted refuses new objects, and every later step would fail.
wait_no_terminating 30

date
echo "ticketdrop-gitops at $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . || echo ' (with uncommitted changes)')"
step "rebuild starts"

# 1. Namespaces, each with its Pod Security level.
run "kubectl apply -f platform/namespaces.yaml"

# 2. Gateway API CRDs, server-side: the HTTPRoute CRD is too big for the
#    client-side annotation (DECISIONS 42).
run "kubectl apply --server-side -f platform/gateway-api/standard-install-v1.6.3.yaml"

# 3. CloudNativePG: the Cluster, roles and databases are refused until its
#    webhook answers.
run "helm upgrade --install cnpg cnpg/cloudnative-pg --version $CNPG_VERSION -n cnpg-system -f platform/cnpg/values.yaml --wait"

# 4. goaws, which creates the topic and queues at start.
run "kubectl apply -f platform/goaws/"
run "kubectl rollout status deploy/goaws -n data --timeout=120s"

# 5. Database Secrets: pg-<svc> in data, <svc>-db in ticketdrop.
run "scripts/db-secrets.sh"

# 6. Postgres, then the roles and databases inside it.
run "kubectl apply -f platform/postgres/cluster.yaml"
# The Cluster has no status for a moment after it is created.
run "until kubectl get cluster/pg -n data -o jsonpath='{.status.phase}' 2>/dev/null | grep -q .; do sleep 2; done"
run "kubectl wait cluster/pg -n data --for=condition=Ready --timeout=300s"
run "kubectl apply -f platform/postgres/roles.yaml -f platform/postgres/databases.yaml"

# 7. KEDA before the services: fulfillment's chart renders a ScaledObject.
run "helm upgrade --install keda kedacore/keda --version $KEDA_VERSION -n keda -f platform/keda/values.yaml --wait"

# 8. Traefik, then the Gateway and HTTPRoute that use its GatewayClass.
run "helm upgrade --install traefik traefik/traefik --version $TRAEFIK_VERSION -n traefik -f platform/traefik/values.yaml --wait"
run "kubectl apply -f platform/routes/"

# 9-11. DNS allow, the services with their own policies, default-deny last.
run "kubectl apply -f platform/network-policies/dns.yaml"
for s in $SVCS; do
  run "helm upgrade --install $s charts/service -n ticketdrop -f charts/service/values/values-$s.yaml"
done
run "kubectl apply -f platform/network-policies/default-deny.yaml"
run "kubectl wait --for=condition=Available deploy --all -n ticketdrop --timeout=300s"

step "everything Available"

# 12. Check it all came back.
"$(dirname "$0")/check.sh"

step "rebuild done"
