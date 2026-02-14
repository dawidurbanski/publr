FROM alpine:3.21 AS base

RUN apk add --no-cache nginx && \
    rm -rf /var/cache/apk/* /tmp/*

# Hardening: non-root user, minimal filesystem
RUN addgroup -S publr && adduser -S publr -G publr -h /app -s /sbin/nologin && \
    mkdir -p /app/data /run/nginx && \
    chown -R publr:publr /app /run/nginx /var/log/nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY zig-out/bin/publr /app/publr
RUN chmod +x /app/publr && chown publr:publr /app/publr

USER publr
WORKDIR /app

VOLUME /app/data
EXPOSE 443 80

ENTRYPOINT ["sh", "-c", "nginx && exec /app/publr serve"]
