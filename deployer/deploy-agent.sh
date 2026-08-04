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

COMMIT=$(git rev-parse --short HEAD)
log "Deploying stack from commit $COMMIT..."

if docker stack deploy -c stack.yml ifaran; then
  log "Stack deploy succeeded (commit $COMMIT)"
else
  log "ERROR: Stack deploy failed (commit $COMMIT)"
  exit 1
fi
