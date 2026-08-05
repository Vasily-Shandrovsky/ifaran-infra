# ifaran GitOps — гайд по эксплуатации и переносу на боевой проект

Документ для будущего: когда этот тестовый шаблон прикручивается к реальному приложению.

---

## Архитектура (напоминание)

```
app-repo (push) → build-agent (poll) → registry → infra-repo (commit tag)
                                                          ↓
                                              GitHub webhook → deploy-agent → stack deploy
```

- **Webhook** ускоряет только **деплой** (push в `ifaran-infra`).
- **Poll** (`POLL_INTERVAL`) — обнаружение изменений в app-repo. Для одного VPS это нормально: `git pull` без изменений ≈ несколько KB.

---

## Хранение образов (реализовано)

### `KEEP_IMAGES` (default: `3`)

После успешного `docker push` build-agent:

1. Оставляет **N самых новых** тегов `ifaran-app` (по дате на хосте).
2. Удаляет остальные из **локального Docker** и **registry** (Registry API v2).
3. Запускает `registry garbage-collect`, если что-то удалено.
4. Чистит **dangling build cache** (`docker builder prune -f`).

Переменная в `.env`:

```bash
KEEP_IMAGES=3
```

### Ручная уборка на VPS (если нужно)

```bash
# Безопасно: только неиспользуемое
sudo docker image prune -f
sudo docker builder prune -f

# Агрессивно (не трогает образы запущенных контейнеров)
sudo docker image prune -af
sudo docker builder prune -af

# Полная уборка Swarm-мусора
sudo docker system prune -af
```

### Cron (опционально, раз в неделю)

```bash
# /etc/cron.weekly/docker-ifaran-prune
#!/bin/bash
docker builder prune -af --filter until=168h
docker container prune -f
```

Не добавлять `docker system prune -af` в cron без фильтров — может удалить образы агентов между рестартами.

---

## Чеклист: прикрутить шаблон к боевому приложению

### 1. Репозитории

| Шаг | Действие |
|-----|----------|
| App | Форк/копия `ifaran-app` → свой Dockerfile + `VERSION` (или semver из git tag) |
| Infra | Форк `ifaran-infra` → переименовать image (`myapp` вместо `ifaran-app`) |
| Имена | Обновить `STACK_NAME`, сервис `web` → осмысленное имя в `stack.yml` |

### 2. Секреты и ключи (пересоздать, не копировать с теста)

- [ ] SSH deploy key → GitHub deploy key на **infra** repo (write)
- [ ] `WEBHOOK_SECRET` → новый `openssl rand -hex 20`
- [ ] GitHub webhook URL → `https://deploy.example.com/hooks/infra-deploy` (см. TLS ниже)
- [ ] `.env` на VPS — не коммитить

### 3. Сеть и безопасность

| Тест (сейчас) | Бой (рекомендация) |
|---------------|-------------------|
| HTTP :80, :9000 | **Caddy/Traefik** на 443, webhook за TLS |
| Registry :5000 на localhost | Оставить закрытым; в бою — Harbor/ECR/GHCR |
| Poll 60s | Poll 15–30s или webhook на app-repo |
| `insecure-registries` | TLS registry или внешний registry |

### 4. Registry в проде

`registry:2` без auth — **только для теста на localhost**.

Для боя:

| Вариант | Когда |
|---------|-------|
| **GHCR / Docker Hub** | Простой CI, не хочется поднимать registry |
| **Harbor** | Self-hosted, lifecycle policies, сканирование |
| **ECR/GCR** | Облако |

Lifecycle policy в облаке заменяет `KEEP_IMAGES` из build-agent.

### 5. build-agent: что поменять

- `APP_REPO` — HTTPS (публичный) или SSH (приватный + deploy key)
- `INFRA_REPO_PUSH_URL` — SSH с write key
- Имя образа в `build-agent.sh` и `stack.yml` (сейчас захардкожено `ifaran-app`)
- `KEEP_IMAGES` — 3–5 для теста, 10–30 для боя с rollback
- Добавить webhook на app-repo → мгновенная сборка (доработка)

### 6. deploy-agent

- `INFRA_REPO` — HTTPS clone (публичный infra) или SSH
- Все env из `stack.yml` должны быть в `environment` deploy-agent (см. инсайт #8 в CONTEXT.md)
- Healthcheck после deploy (опционально)

### 7. Swarm / оркестратор

| Тест | Бой |
|------|-----|
| Single-node Swarm | Multi-node или k8s/k3s при росте |
| 1 replica web | 2+ replicas + load balancer |
| Нет бэкапов volume | Бэкап `registry-data` если local registry |

### 8. Мониторинг

```bash
docker service ls
docker service logs -f <stack>_build-agent
docker service logs -f <stack>_deploy-agent
docker system df
df -h /
```

Алерты: диск >80%, сервис не 1/1, webhook delivery failed в GitHub.

### 9. Rollback

```bash
# В infra-repo
git revert HEAD && git push
# → webhook → deploy предыдущего тега
```

Swarm `update_config.failure_action: rollback` уже в stack.yml.

---

## Типичные грабли (не повторять)

1. Registry: `127.0.0.1`, не `localhost` (IPv6 hang).
2. `insecure-registries` в `/etc/docker/daemon.json`.
3. SSH key volume: `ifaran-gitops_ssh-key`, не `ssh-key`.
4. Один deploy key = один GitHub repo (app по HTTPS, infra по SSH).
5. `docker stack deploy` не читает `.env` с хоста — env в deploy-agent container.
6. Удаление тегов из registry без `garbage-collect` не освобождает диск.
7. Webhook без `-urlprefix /` в adnanh/webhook.

---

## Минимальные ресурсы VPS

| | Тест | Бой (минимум) |
|---|------|---------------|
| RAM | 2 GB | 4 GB |
| Disk | 15 GB | 40 GB+ |
| CPU | 1 vCPU | 2 vCPU |

---

## Порядок первого деплоя на новый VPS

См. `CONTEXT.md` в корне рабочей копии или README.md bootstrap-секцию:

1. Docker + Swarm + UFW + fail2ban
2. Clone infra, `.env`, deploy key
3. Build agent images
4. `docker stack deploy`
5. SSH key → volume `*_ssh-key`
6. Initial app image build + push
7. GitHub webhook
8. Проверка end-to-end: push VERSION → новая версия на сайте

---

## Когда переходить с шаблона на «взрослую» схему

- Несколько приложений → отдельные stack / общий registry с auth
- Команда >1 человека → GitHub Actions вместо poll build-agent
- SLA / compliance → Harbor, TLS everywhere, secrets manager
- >1 VPS → внешний registry, не local `registry:2`
