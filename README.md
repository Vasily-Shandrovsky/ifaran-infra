# ifaran-infra

Pull-based GitOps test stand on Docker Swarm.

Pipeline: push to `ifaran-app` → build-agent polls and builds image → push to registry → commit tag to this repo → GitHub webhook → deploy-agent runs `docker stack deploy`.

## Prerequisites (VPS)

- Docker Engine with Swarm initialized (`docker swarm init`)
- Open ports:
  - **8080** — demo web app (public)
  - **9000** — webhook listener (public, for GitHub)
  - **5000** — registry (internal only; block in firewall/security group)
- Two Git repositories:
  - `ifaran-app` — application source (read access for build-agent)
  - `ifaran-infra` — this repo (read for deploy-agent, write for build-agent)
- SSH deploy key with **write** access to `ifaran-infra`, mounted into build-agent

## Environment variables

Copy `.env.example` to `.env` and fill in values:

```bash
cp .env.example .env
```

| Variable | Description |
|----------|-------------|
| `APP_REPO` | Read-only clone URL for ifaran-app (HTTPS or SSH) |
| `INFRA_REPO` | Read-only clone URL for ifaran-infra (used by deploy-agent) |
| `INFRA_REPO_PUSH_URL` | Write-enabled clone URL for ifaran-infra (used by build-agent) |
| `REGISTRY` | Registry address (default: `localhost:5000`) |
| `POLL_INTERVAL` | Build-agent poll interval in seconds (default: `60`) |
| `WEBHOOK_SECRET` | Shared secret for GitHub webhook HMAC validation |

## SSH key setup

Generate a deploy key and add it to both repos on GitHub (read for app, write for infra):

```bash
ssh-keygen -t ed25519 -f deploy_key -N ""
```

On the VPS, create a Docker volume with the key:

```bash
docker volume create ssh-key
docker run --rm -v ssh-key:/keys -v $(pwd):/src alpine \
  sh -c "cp /src/deploy_key /src/deploy_key.pub /keys/ && chmod 600 /keys/deploy_key"
```

Add a config file to the volume so git uses the key:

```bash
docker run --rm -v ssh-key:/keys alpine sh -c 'cat > /keys/config <<EOF
Host github.com
  IdentityFile /root/.ssh/deploy_key
  StrictHostKeyChecking accept-new
EOF
chmod 600 /keys/config'
```

## Bootstrap (first deploy)

Swarm does not build images from `stack.yml`. Build agent images and the initial app image manually:

```bash
# 1. Build agent images
docker build -t ifaran-build-agent:latest ./builder
docker build -t ifaran-deploy-agent:latest ./deployer

# 2. Start the stack (registry + agents; web may fail until step 3)
export $(grep -v '^#' .env | xargs)
docker stack deploy -c stack.yml ifaran

# 3. Build and push the initial app image
git clone <APP_REPO_URL> /tmp/ifaran-app
cd /tmp/ifaran-app
VERSION=$(cat VERSION)
HASH=$(git rev-parse --short HEAD)
docker build --build-arg VERSION=$VERSION -t localhost:5000/ifaran-app:$HASH .
docker push localhost:5000/ifaran-app:$HASH

# 4. Update stack.yml with the real tag and push to infra repo
#    (or wait for build-agent to detect the commit and do this automatically)
```

After bootstrap, build-agent handles subsequent app changes automatically.

## GitHub webhook

In the `ifaran-infra` repository settings on GitHub:

1. Go to **Settings → Webhooks → Add webhook**
2. **Payload URL**: `http://<VPS_IP>:9000/hooks/infra-deploy`
3. **Content type**: `application/json`
4. **Secret**: same value as `WEBHOOK_SECRET` in `.env`
5. **Events**: select **Just the push event**
6. Active: checked

Webhook triggers on every push to any branch; deploy-agent always pulls latest and redeploys.

## Day-to-day workflow

1. Change `VERSION` in `ifaran-app` and push to `main`
2. Within ~60 seconds, build-agent detects the new commit, builds and pushes the image, commits the new tag to `ifaran-infra`
3. GitHub sends a webhook to deploy-agent
4. Deploy-agent pulls infra repo and runs `docker stack deploy`
5. Open `http://<VPS_IP>:8080` — the page shows the new version in large text

## Rollback

Revert the last commit in `ifaran-infra` and push:

```bash
git revert HEAD
git push
```

The webhook triggers deploy-agent, which redeploys the previous image tag.

## Monitoring

```bash
# Build-agent logs
docker service logs -f ifaran_build-agent

# Deploy-agent logs
docker service logs -f ifaran_deploy-agent

# Web service status
docker service ps ifaran_web
```

## Acceptance criteria

1. **Version update**: Change `VERSION` in ifaran-app and push → within ~1 minute the web page shows the new version.
2. **Failed build**: Break the Dockerfile in ifaran-app → build-agent logs the error, infra repo and deployment remain unchanged.
3. **Git rollback**: `git revert` the last commit in ifaran-infra + push → webhook fires, deployment rolls back within seconds.
4. **Service restart**: Kill the web container manually → Swarm restarts it automatically.
5. **Healthcheck rollback**: Corrupt `stack.yml` so web fails healthcheck → Swarm rolls back the deployment (`failure_action: rollback`), visible in service logs.

## Stack services

| Service | Role |
|---------|------|
| `registry` | Local Docker registry (`registry:2`) on port 5000 |
| `web` | Demo nginx app, port 8080, with healthcheck and rollback config |
| `build-agent` | Polls ifaran-app, builds/pushes images, commits to infra repo |
| `deploy-agent` | Listens for webhooks on port 9000, deploys stack |
