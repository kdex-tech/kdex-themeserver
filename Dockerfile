FROM caddy:2.10.2

COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /

ENTRYPOINT ["tini", "-v", "--", "/entrypoint.sh"]

ENV LANG="C.UTF-8"

RUN apk add --no-cache bash tini tree && \
	\
	mkdir -p /etc/caddy.d /public; \
	\
	caddy validate --config /etc/caddy/Caddyfile