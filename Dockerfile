FROM alpine:3.18
RUN apk update && \
      apk add --no-cache \
      sqlite \
      lua5.3 \
      lua-posix \
      lua-sqlite \
      lua-argparse \
      py3-pip && \
      pip3 install --no-cache-dir detect-secrets
WORKDIR /lclipd
COPY ./*.lua /lclipd/
ENTRYPOINT ["/lclipd/lclipd.lua"]
