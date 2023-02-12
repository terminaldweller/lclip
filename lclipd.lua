#!/usr/bin/env lua5.3

-- needs xsel, clipnotify
-- luarocks-5.3 install --local luaposix
-- luarocks-5.3 install --local argparse
-- cat .clip_history | dmenu -l 10 | xsel -ib
local string = require("string")
local signal = require("posix.signal")
local argparse = require("argparse")
local sys_stat = require("posix.sys.stat")
local unistd = require("posix.unistd")
local posix_syslog = require("posix.syslog")

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
local function trim(s) return s:gsub("^%s+", ""):gsub("%s+$", "") end

local parser = argparse()
parser:option("-s --hist_size", "history file size", 200)
parser:option("-f --hist_file", "history file location",
              "/home/devi/.clip_history")

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

--- Checks to make sure the cliphistory file's permission is 0600.
-- @param clip_hist the history file's path
local function check_clip_hist_perms(clip_hist)
    local uid = unistd.getuid()
    local gid = unistd.getgid()
    for k, v in pairs(sys_stat.stat(clip_hist)) do
        if k == "st_uid" and v ~= uid then
            log_to_syslog(
                "clipboard history file owned by uid other than the clipd uid",
                posix_syslog.LOG_CRIT)
            os.exit(1)
        end
        if k == "st_gid" and v ~= gid then
            log_to_syslog(
                "clipboard history file owned by gid other than the clipd gid",
                posix_syslog.LOG_CRIT)
            os.exit(1)
        end
        if k == "st_mode" and v and (sys_stat.S_IRUSR or sys_stat.S_IWUSR) ~=
            (sys_stat.S_IRUSR or sys_stat.S_IWUSR) then
            log_to_syslog(
                "file permissions are too open. they need to be 0600.",
                posix_syslog.LOG_CRIT)
            os.exit(1)
        end
    end
end

--- Checks to make sure there the pid file for clipd does not exist.
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

--- The clipboard's main loop
-- @param clip_hist path to the clip history file
-- @param clip_hist_size number of entries limit for the clip history file
local function loop(clip_hist, clip_hist_size)
    local clips_table = {}
    local hist_current_count = 0

    local hist_file = io.open(clip_hist, "r")
    if hist_file ~= nil then
        for line in hist_file:lines() do
            if line ~= "\n" and line ~= "" and line ~= "\r\n" and line ~= " " then
                clips_table[line] = true
                hist_current_count = hist_current_count + 1
            end
        end
    end
    hist_file:close()

    while true do
        local wait_for_event = io.popen("clipnotify")
        local handle = io.popen("xsel -ob")
        local last_clip_entry = handle:read("*a")

        if last_clip_entry[-1] == "\n" then
            clips_table[string.sub(last_clip_entry, 0,
                                   string.len(last_clip_entry))] = true
        else
            clips_table[last_clip_entry] = true;
        end
        hist_current_count = hist_current_count + 1

        if hist_current_count >= tonumber(clip_hist_size) then
            table.remove(clips_table, 1)
            hist_current_count = hist_current_count - 1
        end

        hist_file = io.open(clip_hist, "w")
        for k, _ in pairs(clips_table) do
            if clips_table[k] then hist_file:write(trim(k) .. "\n") end
        end
        hist_file:close()

        wait_for_event:close()
        handle:close()
        sleep(.2)
    end
end

--- The entry point
local function main()
    signal.signal(signal.SIGINT, function(signum) os.exit(128 + signum) end)
    local args = parser:parse()
    check_clip_hist_perms(args["hist_file"])
    check_pid_file()
    -- write_pid_file()
    local status, err = pcall(loop(args["hist_file"], args["hist_size"]))
    if ~status then log_to_syslog(err, posix_syslog.LOG_CRIT) end
    remove_pid_file()
end

main()
