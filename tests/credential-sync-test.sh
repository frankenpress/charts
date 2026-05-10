#!/usr/bin/env bash
#
# syncAdminCredentials initContainer e2e: deploy the chart with replicas: 2,
# rotate the install Secret, and assert the chart's claimed rotation
# behaviour from .aidocs/install-job-credential-sync-gaps.md:
#
#   1. After Secret rotation + rolling restart, the WP DB hash matches
#      the new Secret value (rotation is end-to-end self-driving once
#      the Pod rolls).
#   2. With replicas: 2, exactly one Pod's initContainer runs
#      `wp user update`; the other short-circuits via the
#      idempotency check. Single rotation = single DB write.
#
# We simulate the Reloader-driven rolling restart with `kubectl rollout
# restart` — testing the chart's responsibility (sync correctly when
# the Pod rolls). The Reloader integration itself is verified
# separately in eoe-staging.
#
# Usage:
#
#   ./tests/credential-sync-test.sh                         # uses defaults below
#   IMAGE_REPO=fp-site IMAGE_TAG=dev IMAGE_PULL_POLICY=Never \
#     KUBE_CONTEXT=kind-frankenpress \
#     ./tests/credential-sync-test.sh                       # local kind w/ built image
#   KEEP=1 ./tests/credential-sync-test.sh                  # don't uninstall on exit
#
# Exits 0 on pass, non-zero on any assertion failure.

set -euo pipefail

# ---------------------------------------------------------------------
# Configuration (env-overridable)
# ---------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-credsync-test}"
RELEASE="${RELEASE:-credsync}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
# Bare `-` (not `:-`) so an explicit empty string is respected — kind
# clusters consuming a locally-loaded image need registry="".
IMAGE_REGISTRY="${IMAGE_REGISTRY-ghcr.io}"
IMAGE_REPO="${IMAGE_REPO:-eightoeight/fp-site-template}"
IMAGE_TAG="${IMAGE_TAG:-v0.2.4}"
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

log()    { printf '%s[credsync-test]%s %s\n' "$YELLOW" "$RESET" "$*"; }
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

INSTALL_SECRET="${RELEASE}-fp-site-install"
DEPLOYMENT="${RELEASE}-fp-site"
POD_SELECTOR="app.kubernetes.io/name=fp-site,app.kubernetes.io/instance=${RELEASE}"

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

# Pods belonging to the deployment's *current* ReplicaSet revision —
# excludes Terminating pods from a previous rollout.
running_pods_in_current_revision() {
    local hash
    hash=$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get rs \
        -l "$POD_SELECTOR" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1:].metadata.labels.pod-template-hash}')
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get pod \
        -l "${POD_SELECTOR},pod-template-hash=${hash}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

# wp_check_password from inside a pod. Echoes "ok" or "mismatch".
check_password_in_db() {
    local expected="$1"
    local pod="$2"
    kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" exec "$pod" -c site -- \
        env EXPECTED="$expected" WP_LOGIN="$ADMIN_USER" \
        wp --allow-root --path=/app/web/wp eval '
            $u = get_user_by("login", getenv("WP_LOGIN"));
            if ( ! $u ) { echo "no-user"; return; }
            echo wp_check_password(getenv("EXPECTED"), $u->user_pass, $u->ID) ? "ok" : "mismatch";
        ' 2>/dev/null
}

# ---------------------------------------------------------------------
# 1. Initial install
# ---------------------------------------------------------------------
log "helm dependency update"
helm dependency update "$CHART_DIR" >/dev/null

log "helm install $RELEASE in $NAMESPACE (image: $IMAGE_REGISTRY/$IMAGE_REPO:$IMAGE_TAG, replicas: 2)"
helm "${HELM_ARGS[@]}" install "$RELEASE" "$CHART_DIR" \
    --namespace "$NAMESPACE" --create-namespace \
    --set "image.registry=$IMAGE_REGISTRY" \
    --set "image.repository=$IMAGE_REPO" \
    --set "image.tag=$IMAGE_TAG" \
    --set "image.pullPolicy=$IMAGE_PULL_POLICY" \
    --set "replicaCount=2" \
    --wait --timeout 5m >/dev/null

log "waiting for both replicas to be Available"
kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" wait --for=condition=Available \
    "deployment/$DEPLOYMENT" --timeout=3m >/dev/null

# Helm `--wait` covers the post-install hook Job, so wp_users is now
# populated with the auto-generated admin.
ADMIN_USER=$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get secret "$INSTALL_SECRET" \
    -o jsonpath='{.data.admin_user}' | base64 -d)
ADMIN_EMAIL=$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get secret "$INSTALL_SECRET" \
    -o jsonpath='{.data.admin_email}' | base64 -d)
ORIGINAL_PASSWORD=$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" get secret "$INSTALL_SECRET" \
    -o jsonpath='{.data.admin_password}' | base64 -d)

log "initial admin: $ADMIN_USER ($ADMIN_EMAIL), password length=${#ORIGINAL_PASSWORD}"

# ---------------------------------------------------------------------
# 2. Sanity-check the install: DB hash matches the Secret value
# ---------------------------------------------------------------------
log "checking initial Secret password matches DB hash"
PODS=()
while IFS= read -r p; do
    [[ -n "$p" ]] && PODS+=("$p")
done < <(running_pods_in_current_revision)
if [[ ${#PODS[@]} -ne 2 ]]; then
    fail "expected 2 running Pods after install, got ${#PODS[@]}: ${PODS[*]}"
    exit 1
fi
INITIAL_RESULT=$(check_password_in_db "$ORIGINAL_PASSWORD" "${PODS[0]}")
if [[ "$INITIAL_RESULT" == "ok" ]]; then
    pass "Secret password matches DB hash on ${PODS[0]}"
else
    fail "Secret password does NOT match DB hash on ${PODS[0]} (got: $INITIAL_RESULT)"
fi

# ---------------------------------------------------------------------
# 3. Rotate: patch Secret with new password, then trigger rollout
# ---------------------------------------------------------------------
NEW_PASSWORD="rotated-$(openssl rand -hex 8)"
log "rotating admin_password (${NEW_PASSWORD:0:14}...)"
kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" patch secret "$INSTALL_SECRET" \
    --type=merge -p "{\"stringData\":{\"admin_password\":\"$NEW_PASSWORD\"}}" >/dev/null

log "rollout restart (simulates Reloader on Secret change)"
kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" rollout restart "deployment/$DEPLOYMENT" >/dev/null
kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=3m >/dev/null

# ---------------------------------------------------------------------
# 4. Assert: each new Pod's DB hash matches the rotated password
# ---------------------------------------------------------------------
PODS=()
while IFS= read -r p; do
    [[ -n "$p" ]] && PODS+=("$p")
done < <(running_pods_in_current_revision)
log "post-rollout pods: ${PODS[*]}"
if [[ ${#PODS[@]} -ne 2 ]]; then
    fail "expected 2 running Pods after rollout, got ${#PODS[@]}"
fi

for pod in "${PODS[@]}"; do
    result=$(check_password_in_db "$NEW_PASSWORD" "$pod")
    if [[ "$result" == "ok" ]]; then
        pass "$pod: DB hash matches rotated password"
    else
        fail "$pod: DB hash does NOT match rotated password (got: $result)"
    fi
done

# ---------------------------------------------------------------------
# 5. Assert: exactly one Pod ran wp user update; the other skipped
# ---------------------------------------------------------------------
log "checking initContainer logs for multi-replica idempotency"
DRIFT_COUNT=0
SKIP_COUNT=0
for pod in "${PODS[@]}"; do
    init_log=$(kubectl "${KUBECTL_ARGS[@]}" -n "$NAMESPACE" logs "$pod" -c sync-admin-credentials 2>/dev/null || true)
    if echo "$init_log" | grep -q "credential drift detected; running wp user update"; then
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        log "  $pod: ran wp user update"
    elif echo "$init_log" | grep -q "DB already in sync with Secret; skipping update"; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        log "  $pod: skipped (DB already in sync)"
    else
        fail "$pod initContainer logged neither 'drift' nor 'in sync'; tail of log:"
        echo "$init_log" | tail -10 | sed 's/^/      /'
    fi
done

if [[ $DRIFT_COUNT -eq 1 && $SKIP_COUNT -eq 1 ]]; then
    pass "exactly one Pod ran the update; the other short-circuited (idempotency confirmed)"
else
    fail "expected drift=1 skip=1, got drift=$DRIFT_COUNT skip=$SKIP_COUNT"
fi

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
echo
if (( FAILURES > 0 )); then
    log "${RED}FAILED${RESET} ($FAILURES assertion(s))"
    exit 1
fi
log "${GREEN}PASSED${RESET} — credential rotation works end-to-end with multi-replica idempotency"
