FROM docker:cli

RUN apk add --no-cache git openssh-client bash

COPY build-agent.sh /build-agent.sh
RUN chmod +x /build-agent.sh

CMD ["/build-agent.sh"]
