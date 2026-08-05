FROM docker:cli

RUN apk add --no-cache git openssh-client bash curl

RUN git config --global user.email "build-agent@ifaran.local" \
    && git config --global user.name "ifaran build-agent"

COPY build-agent.sh /build-agent.sh
RUN chmod +x /build-agent.sh

CMD ["/build-agent.sh"]
