FROM alpine:3.21 AS build

RUN apk add --no-cache curl xz
RUN curl -fsSL https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz | tar -xJ -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.15.2/zig /usr/local/bin/zig

WORKDIR /src
COPY . .
RUN zig build -Doptimize=ReleaseFast

# ---

FROM alpine:3.21

RUN apk add --no-cache nginx && \
    rm -rf /var/cache/apk/* /tmp/*

RUN addgroup -S publr && adduser -S publr -G publr -h /app -s /sbin/nologin && \
    mkdir -p /app/data /run/nginx && \
    chown -R publr:publr /app /run/nginx /var/log/nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=build /src/zig-out/bin/publr /app/publr
RUN chmod +x /app/publr && chown publr:publr /app/publr

USER publr
WORKDIR /app

VOLUME /app/data
EXPOSE 8080

ENTRYPOINT ["sh", "-c", "nginx && exec /app/publr serve --port 3000"]
