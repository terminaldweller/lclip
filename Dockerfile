FROM alpine:3.21
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
ENV HOME=/home/user
RUN set -eux; \
  adduser -u 1001 -D -h "$HOME" user; \
  chown -R user:user "$HOME"
WORKDIR /home/user/lclipd
COPY ./*.lua ./
RUN chown -R user:user /home/user/lclipd
ENTRYPOINT ["/lclipd/lclipd.lua"]
