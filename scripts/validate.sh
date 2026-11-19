#!/usr/bin/env bash
# Lints the service chart and checks every manifest this repo installs against
# the Kubernetes and CRD schemas, with no cluster:
#   scripts/validate.sh
# CI runs it on every PR (.github/workflows/ci.yaml). Needs helm, kubeconform
# and the Helm repos cnpg, kedacore and traefik.

source "$(dirname "$0")/lib.sh"

# The cluster's version, so a field removed or not yet added in it is refused.
K8S_VERSION=1.36.4
# The schemas, each from a fixed commit so they change only when these lines
# do. kubeconform's own default reads the Kubernetes ones from master.
K8S_SCHEMAS=https://raw.githubusercontent.com/yannh/kubernetes-json-schema/9367d1ce1c88b8bbf6ee06d0e80510f26394913f
# The CRDs: CloudNativePG, KEDA and the Gateway API.
CRDS_CATALOG=https://raw.githubusercontent.com/datreeio/CRDs-catalog/49729e49e8f062933e3716a26540d41b0cd0856c

for t in helm kubeconform; do
  command -v "$t" >/dev/null || fail "$t is not installed"
done

# -strict refuses a field the schema does not know, which is what a typo is.
# CustomResourceDefinitions are skipped: they are upstream's files (the
# Gateway API install, the CRDs inside the operators' charts), and there is no
# schema for the CRD kind itself.
kc() {
  kubeconform -strict -summary -output text \
    -kubernetes-version "$K8S_VERSION" \
    -schema-location "$K8S_SCHEMAS/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
    -schema-location "$CRDS_CATALOG/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    -skip CustomResourceDefinition "$@"
}

# Runs a check and carries on if it fails, so one run reports every problem.
failed=0
check() {
  printf '\n$ %s\n' "$*"
  eval "$*" || { failed=$((failed + 1)); printf 'FAIL: the check above\n'; }
}

date
echo "ticketdrop-gitops at $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . || echo ' (with uncommitted changes)')"
helm version --short
kubeconform -v

step "helm lint, each service's values"
for s in $SVCS; do
  check "helm lint --strict charts/service -f charts/service/values/values-$s.yaml"
done

step "kubeconform, each service as rendered"
for s in $SVCS; do
  check "helm template $s charts/service -n ticketdrop -f charts/service/values/values-$s.yaml | kc -"
done

step "kubeconform, the platform manifests"
check "kc platform/namespaces.yaml platform/goaws platform/network-policies platform/postgres platform/routes"

step "kubeconform, the operators' charts with this repo's values"
check "helm template cnpg cnpg/cloudnative-pg --version $CNPG_VERSION -n cnpg-system -f platform/cnpg/values.yaml | kc -"
check "helm template keda kedacore/keda --version $KEDA_VERSION -n keda -f platform/keda/values.yaml | kc -"
check "helm template traefik traefik/traefik --version $TRAEFIK_VERSION -n traefik -f platform/traefik/values.yaml | kc -"

[ "$failed" -eq 0 ] || fail "$failed check(s) failed"
step "all valid"
