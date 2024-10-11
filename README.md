# lclipd

A small clipboard manager in lua.</br>

# How it works

- lclipd runs the clipboard contents through `detect-secrets` and then puts the content in a sqlite3 database
- X11, Wayland, Tmux and custom clipboard commands are supported
- it is meant to be run as a user service. It can also be simply run by just running the script directly
- the logs are put in the system log
- lclipd does not require elevated privileges to run nor does it need to have extra capabilities
- exposes a TCP server(yes a TCP server, not an HTTP server) which you can use to query the db(on localhost:9999 by default)

## Requirements

- lua5.3
- [luaposix](https://github.com/luaposix/luaposix)
- [argparse](https://github.com/mpeterv/argparse)
- [luasqlite3](http://lua.sqlite.org/index.cgi/home): luasqlite3 comes in two flavours. One includes sqlite3 in the lua rock itself and one does not. If you choose to install the rock without sqlite3 you need to have sqlite3 installed on your system.
- [detect-secrets](https://github.com/Yelp/detect-secrets)
- `xclip` ot `wl-clipboard` or whatever clipboard command you use

```sh
luarocks install --local luaposix
luarocks install --local argparse
luarocks install --local lsqlite3
pipx install detect-secrets
```

## Usage

lclipd is technically just the "backend". One way to have a "frontend" is to use something like dmenu:</br>

```sh
#!/usr/bin/env sh

SQL_DB="$(cat /tmp/lclipd/lclipd_db_name)"
content=$(sqlite3 "${SQL_DB}" "select replace(content,char(10),' '),id from lclipd;" | dmenu -D "|" -l 20 -p "lclipd:")
sqlite3 "${SQL_DB}" "select content from lclipd where id = ${content}" | xsel -ib
```

You can swap `xclip` with `wl-paste` for wayland.</br>
For the above to work you have to have added the `dynamic` patch to dmenu.</br>

You could also query the db through the TCP server.</br>
The TCP server will return a JSON array as a response.</br>
You can use something like `jq` for further processing of the returned JSON object on the shell.</br>
An example of a terminal-oriented "frontend":

```sh
tmux set-buffer $(echo 'select * from lclipd;' | nc 127.0.0.1 9999 | jq '.[1]' | awk '{print substr($0, 2, length($0) - 2)}' | fzf)
```

The author has this setup in their `.zshrc`:

```sh
fzf_lclipd() {
  local clipboard_content=$(echo 'select * from lclipd;' | nc 127.0.0.1 9999 | jq '.[1]' | awk '{print substr($0, 2, length($0) - 2)}' | fzf-tmux -p 80%,80%)
  if [[ -n ${clipboard_content} ]]; then
    tmux set-buffer ${clipboard_content}
  fi
}
zle -N fzf_lclipd
bindkey '^O' fzf_lclipd
```

You can also put the db on a network share and then have different instanecs on different hosts use the same common db, effectively sharing your clipboard between different devices on the same subnet.</br>

You can run lclipd as a user service. The author uses this for runit:</br>

```sh
#!/bin/sh
exec \
  env \
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  XAUTHORITY="${XAUTHORITY}" \
  DISPLAY=:0 \
  /usr/bin/lua5.3 \
  /home/devi/devi/lclip.git/in_memory/lclipd.lua \
  > /dev/null 2>&1
```

## Options

```
Usage: ./lclipd.lua [-h] [-s <hist_size>] [-e <detect_secrets_exe>]
       [-d <detect_secrets_args>] [-a <address>] [-p <port>]
       [-c <custom_clip_command>] [--x_clip_cmd <x_clip_cmd>]
       [--wayland_clip_cmd <wayland_clip_cmd>]
       [--tmux_clip_cmd <tmux_clip_cmd>] [--db_path <db_path>]
       [--sql_file <sql_file>]

Options:
   -h, --help            Show this help message and exit.
            -s <hist_size>,
   --hist_size <hist_size>
                         number of distinct entries for clipboard history
                     -e <detect_secrets_exe>,
   --detect_secrets_exe <detect_secrets_exe>
                         the command used to call detect-secrets (default: detect-secrets)
                      -d <detect_secrets_args>,
   --detect_secrets_args <detect_secrets_args>
                         options that will be passed to detect secrets (default: )
          -a <address>,  address to bind to (default: ::)
   --address <address>
       -p <port>,        port to bind to
   --port <port>
                      -c <custom_clip_command>,
   --custom_clip_command <custom_clip_command>
                         custom clipboard read command (default: )
   --x_clip_cmd <x_clip_cmd>
                         the command used to get the X clipboard content (default: xsel -ob)
   --wayland_clip_cmd <wayland_clip_cmd>
                         the command used to get the wayland clipboard content (default: wl-paste)
   --tmux_clip_cmd <tmux_clip_cmd>
                         the command used to get the tmux paste-buffer content (default: tmux show-buffer)
   --db_path <db_path>   path to the db location,currently :memory: and ''(empty) is not supported (default: /dev/shm/lclipd)
   --sql_file <sql_file> path to the file containing a sql file that will be executed about lclip starting every time (default: )
```

## Supported OSes

lcilpd uses luaposix so any POSIX-half-compliant OS will do.</br>

## Acknowledgements

- [luaposix](https://github.com/luaposix/luaposix) - pretty much all the "heavy lifting" is done using luaposix
- [cqueue](https://github.com/wahern/cqueues)
- [detect-secrets](https://github.com/Yelp/detect-secrets)
- [luasqlite3](http://lua.sqlite.org/index.cgi/home)
- [json.lua](https://github.com/rxi/json.lua) - used as a vendored dependency
- [argparse](https://github.com/mpeterv/argparse)

## TODO

- support `in-memory` and `temporary` databases.
