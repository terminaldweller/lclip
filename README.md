# lclipd
A minimal clipboard manager in lua.</br>

# How it works
lclipd runs the clipboard contents through `detect-secrets` and then puts the content in a sqlite3 database.</br>

lclipd keeps the clipboard content database in the `tmp` directory.</br>

Both X11 and wayland are supported.</br>

lclipd is meant to be run as a user service. It can also be simply run by just running the script directly.</br>

lclipd puts its logs in the system log.</br>

lclipd does not require elevated privileges to run.</br>

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

lclipd is technically just the "back-end". One way to have a frontend is to use dmenu:</br>
```sh
#!/usr/bin/env sh

SQL_DB="$(cat /tmp/lclipd/lclipd_db_name)"
content=$(sqlite3 "${SQL_DB}" "select replace(content,char(10),' '),id from lclipd;" | dmenu -fn "DejaVuSansMono Nerd Font Mono-11.3;antialias=true;autohint=true" -D "|" -l 20 -p "lclipd:")
sqlite3 "${SQL_DB}" "select content from lclipd where id = ${content}" | xsel -ib
```

## Options

```
Usage: ./lclipd.lua [-h] [-s <hist_size>]

Options:
   -h, --help            Show this help message and exit.
            -s <hist_size>,
   --hist_size <hist_size>
                         number of distinct entries for clipboard history
```

## Supported OSes
lcilpd uses luaposix so any POSIX-half-compliant OS will do.</br>

## TODO
* The DB permissions are not being taken care of.</br>
* allow passing options to `detect-secrets`.</br>
