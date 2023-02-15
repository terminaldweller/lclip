#!/usr/bin/env lua5.3

-- needs xsel, clipnotify
-- luarocks-5.3 install --local luaposix
-- luarocks-5.3 install --local argparse
-- luarocks-5.3 install --local lsqlite3
-- sqlite3 $(cat /tmp/lclipd_db_name) 'select content from lclipd;' | dmenu -l 10 | xsel -ib
local string = require("string")
local signal = require("posix.signal")
local argparse = require("argparse")
local sys_stat = require("posix.sys.stat")
local unistd = require("posix.unistd")
local posix_syslog = require("posix.syslog")
local sqlite3 = require("lsqlite3")

local sql_create_table = [=[
create table if not exists lclipd (
    id integer primary key,
    content text unique not null,
    dateAdded integer not null
);
]=]

local sql_trigger = [=[
create trigger if not exists hist_prune before insert on lclipd
begin
    delete from lclipd
    where id = (
        select id
        from lclipd as o
        where (select count(id) from lclipd where content == o.content) > 1
        order by id
        limit 1
    )
    and (
        select count(id)
        from lclipd
    ) >= XXX;
end;
]=]

local sql_insert = [=[
insert into lclipd(content,dateAdded) values('XXX', unixepoch());
]=]

--- Adds LUA_PATH and LUA_CPATH to the current interpreters path.
local function default_luarocks_modules()
    local luarocks_handle = io.popen("luarocks-5.3 path --bin")
    local path_b = false
    local cpath_b = false
    for line in luarocks_handle:lines() do
        local path = string.match(line, "LUA_PATH%s*=%s*('.+')")
        local cpath = string.match(line, "LUA_CPATH%s*=%s*('.+')")
        if path ~= nil then
            package.path = package.path .. ";" .. string.sub(path, 2, -2)
        end
        if cpath ~= nil then
            package.cpath = package.cpath .. ";" .. string.sub(cpath, 2, -2)
        end
    end

    if path_b then os.exit(1) end
    if cpath_b then os.exit(1) end
end
default_luarocks_modules()

local function sleep(n) os.execute("sleep " .. tonumber(n)) end
-- local function trim(s) return s:gsub("^%s+", ""):gsub("%s+$", "") end

local parser = argparse()
parser:option("-s --hist_size", "history file size", 200)

--- Log the given string to syslog with the given priority.
-- @param log_str the string passed to the logging facility
-- @param log_priority the priority of the log string
local function log_to_syslog(log_str, log_priority)
    posix_syslog.openlog("clipd",
                         posix_syslog.LOG_NDELAY | posix_syslog.LOG_PID,
                         posix_syslog.LOG_LOCAL0)
    posix_syslog.syslog(log_priority, log_str)
    posix_syslog.closelog()
end

--- Checks to make sure that the pid file for clipd does not exist.
local function check_pid_file()
    local f = sys_stat.stat("/var/run/clipd.pid")
    if f ~= nil then
        log_to_syslog("clipd is already running", posix_syslog.LOG_CRIT)
        os.exit(1)
    end
end

-- FIXME- we cant write to /var/run since we are running as non-root user
--- Writes the pidfile to we can later check to make sure this is the only
-- instance running.
local function write_pid_file()
    local f = io.open("/var/run/clipd.pid", "w")
    if f == nil then
        log_to_syslog("cant open pid file for writing", posix_syslog.LOG_CRIT)
        os.exit(1)
    end
    f.write(unistd.getpid())
end

-- TODO- implement me
local function remove_pid_file() end

--- Get the clipboard content from X or wayland.
local function get_clipboard_content()
    local wait_for_event_x = io.popen("clipnotify")
    local handle_x = io.popen("xsel -ob")
    local last_clip_entry_x = handle_x:read("*a")

    -- FIXME- fix for wayland
    -- local wait_for_event_w = io.popen("clipnotify")
    -- local handle_w = io.popen("wl-paste")
    -- local last_clip_entry_w = handle_w:read("*a")

    if last_clip_entry_x ~= "" then
        return last_clip_entry_x
    else
        return last_clip_entry_w
    end
end

--- Get the sqlite DB handle.
local function get_sqlite_handle()
    local tmp_db_name = "/tmp/" ..
                            io.popen(
                                "tr -dc A-Za-z0-9 </dev/urandom | head -c 13"):read(
                                "*a")
    log_to_syslog(tmp_db_name, posix_syslog.LOG_INFO)
    local clipDB = sqlite3.open(tmp_db_name,
                                sqlite3.OPEN_READWRITE + sqlite3.OPEN_CREATE)
    if clipDB == nil then
        log_to_syslog("could not open the database")
        os.exit(1)
    end

    local tmp_db_file = io.open("/tmp/lclipd_db_name", "w")
    io.output(tmp_db_file)
    io.write(tmp_db_name .. "\n")
    io.close(tmp_db_file)

    return clipDB
end

--- The clipboard's main loop
-- @param clip_hist_size number of entries limit for the clip history file
local function loop(clip_hist_size)
    local sqlite_handle = get_sqlite_handle()

    -- create the table if it does not exist
    local return_code = sqlite_handle:exec(sql_create_table)
    if return_code ~= sqlite3.OK then log_to_syslog(tostring(return_code)) end

    -- add the trigger
    sql_trigger = sql_trigger:gsub("XXX", clip_hist_size)
    return_code = sqlite_handle:exec(sql_trigger)
    if return_code ~= sqlite3.OK then log_to_syslog(tostring(return_code)) end

    while true do
        local clip_content = get_clipboard_content()

        if clip_content ~= nil then
            local insert_string = sql_insert:gsub("XXX", clip_content)
            sqlite_handle:exec(insert_string)
            if return_code ~= sqlite3.OK then
                log_to_syslog(tostring(return_code))
            end
        end

        sleep(1)
    end
end

--- The entry point
local function main()
    signal.signal(signal.SIGINT, function(signum) os.exit(128 + signum) end)
    local args = parser:parse()
    check_pid_file()
    -- write_pid_file()
    local status, err = pcall(loop(args["hist_size"]))
    if ~status then log_to_syslog(err, posix_syslog.LOG_CRIT) end
    remove_pid_file()
end

main()
