#!/usr/bin/env lua5.3

-- needs xsel, clipnotify
-- luarocks-5.3 install --local luaposix
-- luarocks-5.3 install --local argparse
-- luarocks-5.3 install --local lsqlite3
-- sqlite3 $(cat /tmp/lclipd_db_name) 'select content from lclipd;' | dmenu -l 10 | xsel -ib
local string = require("string")

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

local signal = require("posix.signal")
local argparse = require("argparse")
local sys_stat = require("posix.sys.stat")
local unistd = require("posix.unistd")
local posix_syslog = require("posix.syslog")
local sqlite3 = require("lsqlite3")
local posix_wait = require("posix.sys.wait")

local sql_create_table = [=[
create table if not exists lclipd (
    id integer primary key,
    content text unique not null,
    dateAdded integer unique not null
);
]=]

local sql_dupe_trigger = [=[
create trigger if not exists hist_dupe_prune before insert on lclipd
begin
    delete from lclipd
    where id = (
        select id
        from lclipd as o
        where (select count(id) from lclipd where content == o.content) > 1
        order by id
        limit 1
    );
end;
]=]

-- We are deleting old entries in groups of 20 instead of one by one
local sql_old_reap_trigger = [=[
create trigger if not exists hist_old_reap before insert on lclipd
begin
    delete from lclipd
    where id = (
        select id from lclipd
        order by timeAdded
        asc
        limit 20
    ) and (
        select count(id)
        from lclipd
    ) >= XXX;
end;
]=]

local sql_insert = [=[
insert into lclipd(content,dateAdded) values('XXX', unixepoch());
]=]

local pid_file = "/tmp/lclipd.pid"
local db_file_name = "/tmp/lclipd_db_name"

--- A sleep function
local function sleep(n) os.execute("sleep " .. tonumber(n)) end

--- We are not longer running.
local function remove_pid_file() os.remove(pid_file) end

--- Adds LUA_PATH and LUA_CPATH to the current interpreters path.

local function lclip_exit(n)
    os.exit(n)
    remove_pid_file()
end

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

local function check_uid_gid()
    log_to_syslog(tostring(unistd.getuid()) .. ":" .. tostring(unistd.getgid()),
                  posix_syslog.LOG_INFO)
end

--- Checks to make sure that the pid file for clipd does not exist.
local function check_pid_file()
    local f = sys_stat.stat(pid_file)
    if f ~= nil then
        log_to_syslog("clipd is already running", posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end
end

--- instance running.
local function write_pid_file()
    local f = io.open(pid_file, "w")
    if f == nil then
        log_to_syslog("cant open pid file for writing", posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end
    f:write(tostring(unistd.getpid()))
end

--- Get the clipboard content from X or wayland.
local function get_clipboard_content()
    -- if we use a plain os.execute for clipnotify we wont get the ctrl-c
    -- when it is pressed. doing it manually though the parent receives 
    -- the SIGINT just fine.
    local pid, errmsg = unistd.fork()
    if pid == nil then
        log_to_syslog("could not fork", posix_syslog.LOG_CRIT)
        log_to_syslog(errmsg, posix_syslog.LOG_CRIT)
        remove_pid_file()
        os.exit(1)
    elseif pid == 0 then
        -- clipnotify exits when there is a new entry on the clipboard
        -- so we do want a blocking call here
        os.execute("clipnotify")
        os.exit(0)
    else
        posix_wait.wait(pid)
        -- we dont care whether all the calls to clipboard progs succeed
        -- or not. so we just mask the errors.
        local _, handle_x = pcall(io.popen, "xsel -ob")
        local last_clip_entry_x = handle_x:read("*a")

        local _, handle_w = pcall(io.popen, "wl-paste")
        local last_clip_entry_w = handle_w:read("*a")

        local _, handle_p = pcall(io.popen, "pyclip paste")
        local last_clip_entry_p = handle_p:read("*a")

        if last_clip_entry_p ~= "" then
            return last_clip_entry_p
        elseif last_clip_entry_x ~= "" and last_clip_entry_x ~= nil then
            return last_clip_entry_x
        elseif last_clip_entry_w ~= "" and last_clip_entry_w ~= nil then
            return last_clip_entry_w
        end
    end
end

--- Get the sqlite DB handle.
local function get_sqlite_handle()
    local tmp_db_name = "/tmp/" ..
                            io.popen(
                                "tr -dc A-Za-z0-9 </dev/urandom | head -c 17"):read(
                                "*a")
    log_to_syslog(tmp_db_name, posix_syslog.LOG_INFO)
    local clipDB = sqlite3.open(tmp_db_name,
                                sqlite3.OPEN_READWRITE + sqlite3.OPEN_CREATE)
    if clipDB == nil then
        log_to_syslog("could not open the database", posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end

    local tmp_db_file = io.open(db_file_name, "w")
    local stdout = io.output()
    io.output(tmp_db_file)
    io.write(tmp_db_name .. "\n")
    io.close(tmp_db_file)
    io.output(stdout)

    return clipDB
end

--- The clipboard's main loop
-- @param clip_hist_size number of entries limit for the clip history file
local function loop(clip_hist_size)
    local sqlite_handle = get_sqlite_handle()

    -- create the table if it does not exist
    local return_code = sqlite_handle:exec(sql_create_table)
    if return_code ~= sqlite3.OK then
        log_to_syslog(tostring(return_code), posix_syslog.LOG_CRIT)
        log_to_syslog("could not create table", posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end

    -- add the de-dupe trigger
    return_code = sqlite_handle:exec(sql_dupe_trigger)
    if return_code ~= sqlite3.OK then
        log_to_syslog(tostring(return_code), posix_syslog.LOG_CRIT)
        log_to_syslog("could not add dupe trigger to table",
                      posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end

    -- add the old_reap trigger
    sql_old_reap_trigger = sql_old_reap_trigger:gsub("XXX", clip_hist_size)
    return_code = sqlite_handle:exec(sql_dupe_trigger)
    if return_code ~= sqlite3.OK then
        log_to_syslog(tostring(return_code), posix_syslog.LOG_CRIT)
        log_to_syslog("could not add old_reap trigger to table",
                      posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end

    log_to_syslog("starting the main loop", posix_syslog.LOG_INFO)
    while true do
        local clip_content = get_clipboard_content()
        -- remove trailing/leading whitespace
        if clip_content == nil then goto continue end
        clip_content = string.gsub(clip_content, '^%s*(.-)%s*$', '%1')
        sleep(0.2)

        if clip_content ~= nil then
            local insert_string = sql_insert:gsub("XXX", clip_content)
            sqlite_handle:exec(insert_string)
            if return_code ~= sqlite3.OK then
                log_to_syslog(tostring(return_code), posix_syslog.LOG_WARNING)
            end
        end
        ::continue::
    end
end

--- The entry point.
local function main()
    -- local pgrpid = unistd.getpgrp()
    signal.signal(signal.SIGINT, function(signum)
        remove_pid_file()
        io.write("\n")
        os.exit(128 + signum)
    end)
    signal.signal(signal.SIGTERM, function(signum)
        remove_pid_file()
        io.write("\n")
        os.exit(128 + signum)
    end)

    local args = parser:parse()
    -- check_pid_file()
    -- write_pid_file()
    check_uid_gid()
    local status, err = pcall(loop, args["hist_size"])
    if status ~= true then log_to_syslog(err, posix_syslog.LOG_CRIT) end
end

local status, _ = pcall(main)
if status ~= true then remove_pid_file() end
