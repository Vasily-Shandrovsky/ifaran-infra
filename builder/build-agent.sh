#!/bin/bash

APP_DIR="${APP_DIR:-/app-repo}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
REGISTRY="${REGISTRY:-127.0.0.1:5000}"
LAST_BUILT_FILE="$APP_DIR/.last_built"
export GIT_SSH_COMMAND="ssh -i /root/.ssh/ifaran_deploy_key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/known_hosts"

log() {
  echo "[$(date -Iseconds)] $*"
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
    fi
  fi

  log "Sleeping ${POLL_INTERVAL}s..."
  sleep "$POLL_INTERVAL"
done
