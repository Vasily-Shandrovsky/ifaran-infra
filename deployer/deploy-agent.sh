#!/bin/bash

log() {
  echo "[$(date -Iseconds)] $*"
}

cd /infra-repo

log "Pulling latest infra repo..."
if ! git pull; then
  log "ERROR: git pull failed"
  exit 1
fi

STACK_NAME="${STACK_NAME:-ifaran-gitops}"
COMMIT=$(git rev-parse --short HEAD)
log "Deploying stack $STACK_NAME from commit $COMMIT..."

if docker stack deploy -c stack.yml "$STACK_NAME"; then
  log "Stack deploy succeeded (commit $COMMIT)"
else
  log "ERROR: Stack deploy failed (commit $COMMIT)"
  exit 1
fi
