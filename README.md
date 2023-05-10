# lclipd
A minimal clipboard manager in lua.</br>

# How it works
* lclipd runs the clipboard contents through `detect-secrets` and then puts the content in a sqlite3 database
* lclipd keeps the clipboard content database in the `tmp` directory
* Both X11 and wayland are supported
* it is meant to be run as a user service. It can also be simply run by just running the script directly
* the logs are put in the system log
* lclipd does not require elevated privileges to run nor does it need to have extra capabilities
* exposes a TCP server which you can use to query the db(on localhost:9999 by default)

## Requirements
* lua5.3
* [luaposix](https://github.com/luaposix/luaposix)
* [argparse](https://github.com/mpeterv/argparse)
* [luasqlite3](http://lua.sqlite.org/index.cgi/home): luasqlite3 comes in two flavours. One include sqlite3 in the lua rock itself and one does not. If you choose to install the rock without sqlite3 you need to have that installed on your system.
* [detect-secrets](https://github.com/Yelp/detect-secrets)
* xclip
* wl-clipboard

```sh
luarocks install --local luaposix
luarocks install --local argparse
luarocks install --local lsqlite3
pip install detect-secrets
```

## Usage

lclipd is technically just the "backend". One way to have a frontend is to use dmenu:</br>
```sh
#!/usr/bin/env sh

SQL_DB="$(cat /tmp/lclipd/lclipd_db_name)"
content=$(sqlite3 "${SQL_DB}" "select replace(content,char(10),' '),id from lclipd;" | dmenu -D "|" -l 20 -p "lclipd:")
sqlite3 "${SQL_DB}" "select content from lclipd where id = ${content}" | xsel -ib
```
For the above to work you have to have added the dynamic patch to dmenu.</br>

One way to query the db through the TCP socket is like this:
```sh
echo 'select * from lclipd;' > ./cmd.sql
nc -v 127.0.0.1:9999 < ./cmd.sql
```
The TCP server will return a JSON array as a response.</br>
You can use `jq` or `jaq` for further processing of the returned JSON object on the shell.</br>

## Options

```
Usage: ./lclipd.lua [-h] [-s <hist_size>] [-d <detect_secrets_args>]
       [-a <address>] [-p <port>]

Options:
   -h, --help            Show this help message and exit.
            -s <hist_size>,
   --hist_size <hist_size>
                         number of distinct entries for clipboard history
                      -d <detect_secrets_args>,
   --detect_secrets_args <detect_secrets_args>
                         options that will be passed to detect secrets (default: )
          -a <address>,  address to bind to (default: 127.0.0.1)
   --address <address>
       -p <port>,        port to bind to
   --port <port>
```

## Supported OSes
lcilpd uses luaposix so any POSIX-half-compliant OS will do.</br>
