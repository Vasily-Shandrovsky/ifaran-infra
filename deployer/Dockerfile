FROM alpine:3.19

RUN apk add --no-cache git docker-cli curl bash

ARG WEBHOOK_VERSION=2.8.1
RUN curl -fsSL "https://github.com/adnanh/webhook/releases/download/${WEBHOOK_VERSION}/webhook-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin webhook-linux-amd64 \
    && mv /usr/local/bin/webhook-linux-amd64 /usr/local/bin/webhook

COPY deploy-agent.sh /deploy/deploy-agent.sh
COPY hooks.json.template /deploy/hooks.json.template
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /deploy/deploy-agent.sh /entrypoint.sh

EXPOSE 9000

CMD ["/entrypoint.sh"]
