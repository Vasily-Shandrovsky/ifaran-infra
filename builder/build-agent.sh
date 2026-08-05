#!/bin/bash

APP_DIR="${APP_DIR:-/app-repo}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
REGISTRY="${REGISTRY:-127.0.0.1:5000}"
KEEP_IMAGES="${KEEP_IMAGES:-3}"
LAST_BUILT_FILE="$APP_DIR/.last_built"
REGISTRY_API="http://${REGISTRY}/v2"
export GIT_SSH_COMMAND="ssh -i /root/.ssh/ifaran_deploy_key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts"

log() {
  echo "[$(date -Iseconds)] $*"
}

delete_registry_tag() {
  local image=$1
  local tag=$2
  local digest

  digest=$(curl -fsI \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "${REGISTRY_API}/${image}/manifests/${tag}" \
    | grep -i Docker-Content-Digest | awk '{print $2}' | tr -d '\r')

  if [ -z "$digest" ]; then
    return 1
  fi

  curl -fsX DELETE "${REGISTRY_API}/${image}/manifests/${digest}" >/dev/null
}

run_registry_gc() {
  local cid

  cid=$(docker ps -q --filter "label=com.docker.swarm.service.name=ifaran-gitops_registry" | head -1)
  if [ -z "$cid" ]; then
    cid=$(docker ps -q --filter "ancestor=registry:2" | head -1)
  fi
  if [ -z "$cid" ]; then
    log "Registry container not found, skipping garbage collection"
    return 0
  fi

  if docker exec "$cid" registry garbage-collect /etc/docker/registry/config.yml >/dev/null 2>&1; then
    log "Registry garbage collection completed"
  else
    log "WARNING: Registry garbage collection failed"
  fi
}

prune_old_images() {
  local keep="${KEEP_IMAGES:-3}"
  local repo="${REGISTRY}/ifaran-app"
  local deleted=0
  local tag

  if [ "$keep" -lt 1 ]; then
    log "KEEP_IMAGES=$keep is invalid, skipping prune"
    return 0
  fi

  log "Pruning old images (keeping ${keep} newest)..."

  while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    log "Removing ${repo}:${tag}"
    if delete_registry_tag "ifaran-app" "$tag"; then
      deleted=$((deleted + 1))
    else
      log "WARNING: Could not delete ${repo}:${tag} from registry"
    fi
    docker rmi "${repo}:${tag}" 2>/dev/null || true
  done < <(
    docker images "$repo" --format '{{.CreatedAt}} {{.Tag}}' \
      | sort -r \
      | awk '{print $2}' \
      | grep -v '^<none>$' \
      | tail -n +$((keep + 1))
  )

  if [ "$deleted" -gt 0 ]; then
    run_registry_gc
  fi

  if docker builder prune -f >/dev/null 2>&1; then
    log "Dangling build cache pruned"
  fi
}

ensure_app_repo() {
  if [ ! -d "$APP_DIR/.git" ]; then
    log "Cloning app repo from $APP_REPO..."
    git clone "$APP_REPO" "$APP_DIR"
  fi
}

if [ -z "${APP_REPO:-}" ]; then
  log "ERROR: APP_REPO is not set"
  exit 1
fi

if [ -z "${INFRA_REPO_PUSH_URL:-}" ]; then
  log "ERROR: INFRA_REPO_PUSH_URL is not set"
  exit 1
fi

ensure_app_repo

while true; do
  cd "$APP_DIR"

  log "Pulling app repo..."
  if ! git pull; then
    log "ERROR: git pull failed, will retry on next iteration"
    sleep "$POLL_INTERVAL"
    continue
  fi

  CURRENT_HASH=$(git rev-parse --short HEAD)
  LAST_BUILT=""
  if [ -f "$LAST_BUILT_FILE" ]; then
    LAST_BUILT=$(cat "$LAST_BUILT_FILE")
  fi

  if [ "$CURRENT_HASH" = "$LAST_BUILT" ]; then
    log "No changes (hash=$CURRENT_HASH), skipping build"
  else
    log "New commit detected: $CURRENT_HASH (last built: ${LAST_BUILT:-none})"

    VERSION=$(tr -d '[:space:]' < VERSION)
    IMAGE="$REGISTRY/ifaran-app:$CURRENT_HASH"

    log "Building image $IMAGE with VERSION=$VERSION..."
    if ! docker build --build-arg "VERSION=$VERSION" -t "$IMAGE" .; then
      log "ERROR: Docker build failed, infra repo will not be updated"
    elif ! docker push "$IMAGE"; then
      log "ERROR: Docker push failed, infra repo will not be updated"
    else
      log "Build and push succeeded, updating infra repo..."

      INFRA_WORK=$(mktemp -d)
      if ! git clone "$INFRA_REPO_PUSH_URL" "$INFRA_WORK"; then
        log "ERROR: Failed to clone infra repo"
        rm -rf "$INFRA_WORK"
      else
        cd "$INFRA_WORK"

        sed -i "s|image: 127.0.0.1:5000/ifaran-app:.*|image: 127.0.0.1:5000/ifaran-app:$CURRENT_HASH|" stack.yml

        git add stack.yml
        if ! git commit -m "deploy ifaran-app:$CURRENT_HASH (v$VERSION)"; then
          log "ERROR: git commit failed, infra repo will not be updated"
        elif ! git push; then
          log "ERROR: Failed to push infra repo changes"
        else
          echo "$CURRENT_HASH" > "$LAST_BUILT_FILE"
          log "Infra repo updated, .last_built set to $CURRENT_HASH"
        fi

        rm -rf "$INFRA_WORK"
      fi

      prune_old_images
    fi
  fi

  log "Sleeping ${POLL_INTERVAL}s..."
  sleep "$POLL_INTERVAL"
done
