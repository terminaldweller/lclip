FROM alpine:3.20
RUN apk update && \
      apk add --no-cache \
      sqlite \
      lua5.3 \
      lua-posix \
      lua-sqlite \
      lua-socket \
      lua-http \
      lua-argparse \
      lua5.3-cqueues \
      pipx && \
      pipx install detect-secrets
WORKDIR /lclipd
COPY ./*.lua /lclipd/
ENTRYPOINT ["/lclipd/lclipd.lua"]
