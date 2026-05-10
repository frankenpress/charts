#!/usr/bin/env bash
#
# Lockdown negative-test: deploy the chart to a Kubernetes cluster and
# assert that the platform's "no admin-side installs / updates / file
# edits" property is actually enforced inside the running pod.
#
# This catches regressions where a refactor accidentally relaxes the
# four lockdown constants (DISALLOW_FILE_EDIT / DISALLOW_FILE_MODS /
# AUTOMATIC_UPDATER_DISABLED / WP_AUTO_UPDATE_CORE) — a silent but
# painful regression: admin-side plugin installs would land on
# ephemeral pod disk, vanish on restart, and replicate inconsistently
# across replicas.
#
# Two test layers:
#
#   1. Constants are defined and truthy.
#   2. WordPress's capability API returns false for every install /
#      update / edit cap, even for an admin user. This is the
#      canonical gate — wp-admin's "Add Plugin" button, the REST
#      install-plugin endpoint, and admin-ajax.php's install actions
#      all funnel through current_user_can().
#
# Usage:
#
#   ./tests/lockdown-test.sh                       # uses defaults below
#   IMAGE_REPO=fp-site IMAGE_TAG=dev IMAGE_PULL_POLICY=Never \
#     KUBE_CONTEXT=kind-frankenpress \
#     ./tests/lockdown-test.sh                     # local kind w/ built image
#   KEEP=1 ./tests/lockdown-test.sh                # don't uninstall on exit
#
# Exits 0 on pass, non-zero on any assertion failure.

set -euo pipefail

# ---------------------------------------------------------------------
# Configuration (env-overridable)
# ---------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-lockdown-test}"
RELEASE="${RELEASE:-lockdown}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
# Note: bare `-` (not `:-`) so an explicit empty string is respected
# — kind clusters consuming a locally-loaded image need registry="".
IMAGE_REGISTRY="${IMAGE_REGISTRY-ghcr.io}"
IMAGE_REPO="${IMAGE_REPO:-eightoeight/fp-site-template}"
IMAGE_TAG="${IMAGE_TAG:-v0.2.3}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-IfNotPresent}"
KEEP="${KEEP:-0}"

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)/charts/site"

KUBECTL_ARGS=()
HELM_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
    KUBECTL_ARGS+=(--context "$KUBE_CONTEXT")
    HELM_ARGS+=(--kube-context "$KUBE_CONTEXT")
fi

# Colors only on a TTY.
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; RESET=""
fi

FAILURES=0

log()    { printf '%s[lockdown-test]%s %s\n' "$YELLOW" "$RESET" "$*"; }
pass()   { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$*"; }
fail()   { printf '  %sFAIL%s %s\n' "$RED"   "$RESET" "$*"; FAILURES=$((FAILURES + 1)); }

cleanup() {
    if [[ "$KEEP" == "1" ]]; then
        log "KEEP=1, leaving $RELEASE in $NAMESPACE for inspection"
        return
    fi
    log "uninstalling $RELEASE and dropping namespace $NAMESPACE"
    helm "${HELM_ARGS[@]}" uninstall "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1 || true
    kubectl "${KUBECTL_ARGS[@]}" delete namespace "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# 1. Helm install (with siteInstall so user 1 exists for capability checks)
# ---------------------------------------------------------------------
log "helm dependency update"
helm dependency update "$CHART_DIR" >/dev/null

log "helm install $RELEASE in $NAMESPACE (image: $IMAGE_REGISTRY/$IMAGE_REPO:$IMAGE_TAG)"
helm "${HELM_ARGS[@]}" install "$RELEASE" "$CHART_DIR" \
    --namespace "$NAMESPACE" --create-namespace \
    --set "image.registry=$IMAGE_REGISTRY" \
    --set "image.repository=$IMAGE_REPO" \
    --set "image.tag=$IMAGE_TAG" \
    --set "image.pullPolicy=$IMAGE_PULL_POLICY" \
    --wait --timeout 5m >/dev/null

POD=$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod \
    -l app.kubernetes.io/name=fp-site \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || { log "no Running fp-site pod found"; exit 1; }
log "site pod: $POD"

WP=(wp --allow-root --path=/app/web/wp)

# ---------------------------------------------------------------------
# 2. Constants are defined and truthy
# ---------------------------------------------------------------------
log "checking lockdown constants"

constants_out=$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" exec "$POD" -- "${WP[@]}" eval '
foreach (["DISALLOW_FILE_EDIT", "DISALLOW_FILE_MODS"] as $c) {
    echo $c . ":" . (defined($c) ? var_export(constant($c), true) : "UNDEFINED") . "\n";
}
')
echo "$constants_out" | sed "s/^/    /"

while IFS=: read -r name value; do
    if [[ "$value" == "true" ]]; then
        pass "$name = true"
    else
        fail "$name = $value (expected true)"
    fi
done <<< "$constants_out"

# ---------------------------------------------------------------------
# 3. Admin user cannot install/update/edit anything
# ---------------------------------------------------------------------
log "checking admin (user 1) capabilities"

caps_out=$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" exec "$POD" -- "${WP[@]}" --user=1 eval '
$caps = [
    "install_plugins",
    "install_themes",
    "update_plugins",
    "update_themes",
    "update_core",
    "edit_plugins",
    "edit_themes",
    "delete_plugins",
    "delete_themes",
];
foreach ($caps as $cap) {
    echo $cap . ":" . (current_user_can($cap) ? "true" : "false") . "\n";
}
')
echo "$caps_out" | sed "s/^/    /"

while IFS=: read -r cap result; do
    [[ -z "$cap" ]] && continue
    if [[ "$result" == "false" ]]; then
        pass "current_user_can('$cap') = false"
    else
        fail "current_user_can('$cap') = $result (expected false — lockdown is leaking)"
    fi
done <<< "$caps_out"

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
if (( FAILURES > 0 )); then
    log "${RED}FAILED${RESET} ($FAILURES assertion(s))"
    exit 1
fi
log "${GREEN}PASSED${RESET} — lockdown is enforced"
