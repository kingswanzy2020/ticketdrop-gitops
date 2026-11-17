# Shared by teardown.sh, rebuild.sh and check.sh. Sourced, not run.
# The order and the reasons for it are in the Phase 2 workbook, "Starting again".

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The only cluster these scripts may touch. Set KUBE_CONTEXT to override.
KUBE_CONTEXT="${KUBE_CONTEXT:-docker-desktop}"

# Chart versions, pinned. Change them here and in DECISIONS together.
CNPG_VERSION=0.29.1
KEDA_VERSION=2.21.0
TRAEFIK_VERSION=42.1.3

# Install order: each release brings its own NetworkPolicy before default-deny.
SVCS="catalog inventory orders payments fulfillment notifications scheduler gateway web"

T0=$(date +%s)

# Prints the command, then runs it. With pipefail and errexit the script
# stops at the first failure, so no later step reports success over it.
run() {
  printf '\n$ %s\n' "$*"
  eval "$*"
}

step() { printf '\n%s %s (%ss)\n' "$(date +%T)" "$*" "$(( $(date +%s) - T0 ))"; }

fail() { printf '\nFAILED: %s\n' "$*" >&2; exit 1; }

on_exit() {
  local s=$?
  if [ "$s" -ne 0 ]; then
    printf '\n%s FAILED with status %s after %ss. The last $ line above is the step that failed.\n' \
      "$(date +%T)" "$s" "$(( $(date +%s) - T0 ))" >&2
  fi
}
trap on_exit EXIT

require_context() {
  for t in kubectl helm curl jq; do
    command -v "$t" >/dev/null || fail "$t is not installed"
  done
  local ctx
  ctx="$(kubectl config current-context)"
  [ "$ctx" = "$KUBE_CONTEXT" ] || fail "kubectl points at '$ctx', not '$KUBE_CONTEXT'"
  kubectl get --raw /readyz >/dev/null || fail "the cluster at '$ctx' is not answering"
}

# True if the API server knows this resource type (its CRD is installed).
has_kind() { kubectl api-resources -o name 2>/dev/null | grep -qx "$1"; }

# Waits until no namespace is Terminating, or fails naming what holds it.
wait_no_terminating() {
  local i ns
  for i in $(seq 1 "${1:-60}"); do
    ns="$(kubectl get ns --no-headers | awk '$2=="Terminating"{print $1}')"
    [ -z "$ns" ] && return 0
    sleep 2
  done
  for n in $ns; do
    kubectl get ns "$n" -o json | jq -r '.status.conditions[] | select(.status=="True") | "\(.type): \(.message)"' >&2
  done
  fail "namespace(s) still Terminating: $ns. Capture the conditions above before changing anything (TROUBLESHOOTING 6)"
}
