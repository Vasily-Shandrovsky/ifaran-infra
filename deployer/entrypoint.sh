#!/bin/bash
set -euo pipefail

if [ -z "${WEBHOOK_SECRET:-}" ]; then
  echo "WEBHOOK_SECRET is required"
  exit 1
fi

if [ -z "${INFRA_REPO:-}" ]; then
  echo "INFRA_REPO is required"
  exit 1
fi

sed "s/__WEBHOOK_SECRET__/${WEBHOOK_SECRET}/" /deploy/hooks.json.template > /deploy/hooks.json

if [ ! -d /infra-repo/.git ]; then
  echo "Cloning infra repo from $INFRA_REPO..."
  git clone "$INFRA_REPO" /infra-repo
fi

exec /usr/local/bin/webhook -hooks /deploy/hooks.json -verbose -port 9000
