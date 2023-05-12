#!/usr/bin/env lua5.3

-- needs xsel, clipnotify, pyclip, wclip
-- luarocks-5.3 install --local luaposix
-- luarocks-5.3 install --local argparse
-- luarocks-5.3 install --local lsqlite3
-- pipx install detect-secrets
local string = require("string")

--- Adds LUA_PATH and LUA_CPATH to the current interpreters path.
local function add_luarocks_modules()
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
add_luarocks_modules()

-- we want to delete a pidfile if we wrote one, otherwise we won't
local wrote_a_pidfile = false

local signal = require("posix.signal")
local argparse = require("argparse")
local sys_stat = require("posix.sys.stat")
local unistd = require("posix.unistd")
local posix_syslog = require("posix.syslog")
local sqlite3 = require("lsqlite3")
local posix_wait = require("posix.sys.wait")
local posix_socket = require("posix.sys.socket")
local libgen = require("posix.libgen")

-- vendored dependency
-- https://github.com/rxi/json.lua
local base_path = libgen.dirname(arg[0])
package.path = package.path .. ";" .. base_path .. "/?.lua"
local json = require("json")

local sql_create_table = [=[
create table if not exists lclipd (
    id integer primary key,
    content text unique not null,
    dateAdded integer unique not null
);
]=]

-- We are deleting old entries in groups of 20 instead of one by one
local sql_old_reap_trigger = [=[
create trigger if not exists hist_old_reap before insert on lclipd
begin
    delete from lclipd
    where id = (
        select id from lclipd
        order by dateAdded
        asc
        limit 20
    ) and (
        select count(id)
        from lclipd
    ) >= %s;
end;
]=]

local sql_insert = [=[
insert into lclipd(content,dateAdded) values('%s', unixepoch());
]=]

-- the shell command used to call detect-secrets.
-- we are using a heredoc string without expansion to bypass the
-- need for escaping.
local detect_secrets_cmd = [=[
%s scan %s --string <<- STR | grep True
%s
STR
]=]

local tmp_dir = "/tmp/lclipd"
local pid_file = "/tmp/lclipd/lclipd.pid"

--- We are not longer running.
local function remove_pid_file() if wrote_a_pidfile then os.remove(pid_file) end end

--- exits lclipd, effectively killing all children
-- @param n the exit status code
local function lclip_exit(n)
    os.exit(n)
    remove_pid_file()
end

local parser = argparse()
parser:option("-s --hist_size",
              "number of distinct entries for clipboard history", 200)
parser:option("-e --detect_secrets_exe",
              "the command used to call detect-secrets", "detect-secrets")
parser:option("-d --detect_secrets_args",
              "options that will be passed to detect secrets", "")
parser:option("-a --address", "address to bind to", "127.0.0.1")
parser:option("-p --port", "port to bind to", 9999)
parser:option("-c --custom_clip_command", "custom clipboard read command", "")
parser:option("--x_clip_cmd", "the command used to get the X clipboard content",
              "xsel -ob")
parser:option("--wayland_clip_cmd",
              "the command used to get the wayland clipboard content",
              "wl-paste")
parser:option("--tmux_clip_cmd",
              "the command used to get the tmux paste-buffer content",
              "tmux show-buffer")
parser:option("--db_path",
              "path to the db location,currently :memory: and ''(empty) is not supported",
              "/dev/shm/lclipd")

--- Log the given string to syslog with the given priority.
-- @param log_str the string passed to the logging facility
-- @param log_priority the priority of the log string
-- functions called through pcall will return nil when we
-- try to get their name from debug.getinfo
local function log_to_syslog(log_str, log_priority)
    local caller_name = debug.getinfo(2, "n").name
    posix_syslog.openlog("clipd",
                         posix_syslog.LOG_NDELAY | posix_syslog.LOG_PID,
                         posix_syslog.LOG_LOCAL0)
    posix_syslog.syslog(log_priority, tostring(caller_name) .. ": " .. log_str)
    posix_syslog.closelog()
end

--- checks the uid and gid to make sure that we are the same id as the one
-- that created the db
local function check_uid_gid()
    log_to_syslog(tostring(unistd.getuid()) .. ":" .. tostring(unistd.getgid()),
                  posix_syslog.LOG_INFO)
end

--- Creates the necessary dirs
local function make_tmp_dirs()
    local f = sys_stat.stat(tmp_dir)
    if f == nil then
        local ret = sys_stat.mkdir(tmp_dir)
        if ret ~= 0 then
            log_to_syslog(ret, posix_syslog.LOG_CRIT)
            os.exit(1)
        end
    end

    f = sys_stat.stat(tmp_dir .. "/secrets")
    if f == nil then
        local ret = sys_stat.mkdir(tmp_dir .. "/secrets")
        if ret ~= 0 then
            log_to_syslog(ret, posix_syslog.LOG_CRIT)
            os.exit(1)
        end
    end
end

--- Tries to determine whether another instance is running, if yes, quits
-- obvisouly doing it like this is imprecise but the chances of it failing
-- are very low unless we have a constant known way of calling the script
-- so that we can match for that exactly in the procfs cmdline check.
local function check_pid_file()
    local f = sys_stat.stat(pid_file)
    if f ~= nil then
        local pid_file_handle = io.open(pid_file, "r")
        local pid_file_content = pid_file_handle:read("*a")
        pid_file_content = pid_file_content:gsub("\n", "")
        log_to_syslog(pid_file_content, posix_syslog.LOG_INFO)

        local old_pid_file = sys_stat.stat("/proc/" .. pid_file_content)
        if old_pid_file ~= nil then
            local pid_cmdline = io.open("/proc/" .. pid_file_content ..
                                            "/cmdline", "r")
            local pid_cmdline_content = pid_cmdline:read("*a")
            if string.match(pid_cmdline_content, "lclipd") then
                -- we assume a lclipd instance is already running at this point
                log_to_syslog("clipd is already running", posix_syslog.LOG_CRIT)
                lclip_exit(1)
            end
            -- the old pid file is stale, meaning the previous instance
            -- died without being able to clean up after itself because
            -- e.g. it received a SIGKILL
        end
    end
end

--- Write a pidfile
local function write_pid_file()
    local f = io.open(pid_file, "w")
    if f == nil then
        log_to_syslog("cant open pid file for writing", posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end
    f:write(tostring(unistd.getpid()))
    wrote_a_pidfile = true
end

--- Runs secret detection tests
-- returns true if the string is not a secret
-- @param clipboard_content the content that will be checked against detect-secrets
-- @param detect_secrets_arg extra args that will be passed to detect-secrets scan
local function detect_secrets(clipboard_content, args)
    if clipboard_content == nil or clipboard_content == "" then return false end
    local pipe_read, pipe_write = unistd.pipe()
    if pipe_read == nil then
        log_to_syslog("could not create pipe", posix_syslog.LOG_CRIT)
        log_to_syslog(pipe_write, posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end

    local pid, errmsg = unistd.fork()

    if pid == nil then -- error
        unistd.closr(pipe_read)
        unistd.closr(pipe_write)
        log_to_syslog("could not fork", posix_syslog.LOG_CRIT)
        log_to_syslog(errmsg, posix_syslog.LOG_CRIT)
        lclip_exit(1)
    elseif pid == 0 then -- child
        unistd.close(pipe_read)
        local cmd = string.format(detect_secrets_cmd,
                                  args["detect_secrets_exe"],
                                  args["detect_secrets_args"], clipboard_content)
        local ret = os.execute(cmd)
        if ret == 0 then
            unistd.write(pipe_write, "0")
        else
            unistd.write(pipe_write, "1")
        end

        unistd.close(pipe_write)
        unistd._exit(0)
    elseif pid > 0 then -- parent
        log_to_syslog("spawned " .. tostring(pid), posix_syslog.LOG_INFO)
        unistd.close(pipe_write)
        posix_wait.wait(pid)
        local result = unistd.read(pipe_read, 1)
        unistd.close(pipe_read)
        if result == "0" then
            return false
        else
            return true
        end
    end
end

--- Get the clipboard content from X or wayland.
local function get_clipboard_content(args)
    -- if we use a plain os.execute for clipnotify the parent wont get the
    -- SIGINT when it is passed.clipnotify will end up getting it.
    -- if we fork though, the parent receives the SIGINT just fine.
    local pid, errmsg = unistd.fork()
    if pid == nil then -- error
        log_to_syslog("could not fork", posix_syslog.LOG_CRIT)
        log_to_syslog(errmsg, posix_syslog.LOG_CRIT)
        lclip_exit(1)
    elseif pid == 0 then -- child
        os.execute("clipnotify")
        unistd._exit(0)
    elseif pid > 0 then -- parent
        log_to_syslog("spawned " .. tostring(pid), posix_syslog.LOG_INFO)
        -- clipnotify exits when there is a new entry on the clipboard
        -- so we do want a blocking call here
        posix_wait.wait(pid)

        -- we dont care whether all the calls to the different clipboard apps
        -- succeed or not so we just ignore the errors.
        -- X
        local _, handle_x = pcall(io.popen, args["x_clip_cmd"])
        if handle_x ~= nil then
            local last_clip_entry_x = handle_x:read("*a")
            handle_x:close()
            if last_clip_entry_x ~= "" and last_clip_entry_x ~= nil then
                return last_clip_entry_x
            end
        end

        -- wayland
        local _, handle_w = pcall(io.popen, args["wayland_clip_cmd"])
        if handle_w ~= nil then
            local last_clip_entry_w = handle_w:read("*a")
            handle_w:close()
            if last_clip_entry_w ~= "" and last_clip_entry_w ~= nil then
                return last_clip_entry_w
            end
        end

        -- tmux
        local _, handle_t = pcall(io.popen, args["tmux_clip_cmd"])
        if handle_t ~= nil then
            local last_clip_entry_t = handle_t:read("*a")
            handle_t:close()
            if last_clip_entry_t ~= "" and last_clip_entry_t ~= nil then
                return last_clip_entry_t
            end
        end

        -- custom
        if args["custom_clip_command"] ~= "" then
            local _, handle_c = pcall(io.popen, args["custom_clip_command"])
            if handle_c ~= nil then
                local last_clip_entry_c = handle_c:read("*a")
                handle_c:close()
                if last_clip_entry_c ~= "" and last_clip_entry_c ~= nil then
                    return last_clip_entry_c
                end
            end
        end

        return nil
    end
end

--- Get the sqlite DB handle.
local function get_sqlite_handle(db_path)
    local clipDB = sqlite3.open(db_path)
    if clipDB == nil then
        log_to_syslog("could not open the database", posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end

    return clipDB
end

--- Callback function to get the result when we receive a query from the TCP port
-- @param conn current TCP connection that we will reply to
-- @param columns the columns of the query
-- @param values the value of the query
local function server_query_callback(conn, columns, values, _)
    local result_table = {}
    for i = 1, columns do result_table[i] = values[i] end

    local result_json = json.encode(result_table)

    local bytes_sent, errmsg = posix_socket.send(conn, result_json)
    if bytes_sent == nil then
        log_to_syslog(errmsg, posix_syslog.LOG_WARNING)
        unistd._exit(1)
    end
    return 0
end

--- Starts the lclipd server in a separate process
-- @param args cli args
-- @param sqlite_handle db handle
local function run_server(args, sqlite_handle)
    local server_pid, errmsg = unistd.fork()
    if server_pid == nil then -- error
        log_to_syslog(errmsg, posix_syslog.LOG_CRIT)
        lclip_exit(1)
    elseif server_pid == 0 then -- child
        log_to_syslog("server component forked", posix_syslog.LOG_INFO)
        local sock, errmsg = posix_socket.socket(posix_socket.AF_INET,
                                                 posix_socket.SOCK_STREAM, 0)
        if sock == nil then
            log_to_syslog(errmsg, posix_syslog.LOG_CRIT)
            lclip_exit(1)
        end

        local ret, errmsg = posix_socket.bind(sock, {
            port = args["port"],
            addr = args["address"],
            family = posix_socket.AF_INET,
            socktype = posix_socket.SOCK_STREAM
        })
        if ret == nil then
            log_to_syslog(errmsg, posix_syslog.LOG_CRIT)
            lclip_exit(1)
        end

        ret, errmsg = posix_socket.listen(sock, posix_socket.SOMAXCONN)
        if ret == nil then
            log_to_syslog(errmsg, posix_syslog.LOG_CRIT)
            lclip_exit(1)
        end
        log_to_syslog("listening on " .. args["address"] .. ":" ..
                          tostring(args["port"]), posix_syslog.LOG_INFO)

        while true do
            local conn, conn_addr = posix_socket.accept(sock)
            if conn == nil then
                log_to_syslog(conn_addr, posix_syslog.LOG_CRIT)
                goto server_continue
            end

            -- we fork on every incoming connection
            local pid, errmsg = unistd.fork() -- connection fork
            if pid == nil then -- error
                log_to_syslog(errmsg, posix_syslog.LOG_WARNING)
            elseif pid == 0 then -- child
                local msg = {}
                log_to_syslog("forked on incoming connection",
                              posix_syslog.LOG_INFO)
                while true do
                    local b = posix_socket.recv(conn, 2 ^ 14)
                    if not b or #b == 0 then break end
                    table.insert(msg, b)
                end
                if msg == nil then
                    log_to_syslog(errmsg, posix_syslog.LOG_WARNING)
                    unistd.close(conn)
                    unistd._exit(1)
                end
                msg = table.concat(msg)
                log_to_syslog(msg, posix_syslog.LOG_INFO)
                local return_code = sqlite_handle:exec(msg,
                                                       server_query_callback,
                                                       conn)
                if return_code ~= sqlite3.OK then
                    log_to_syslog(tostring(return_code),
                                  posix_syslog.LOG_WARNING)
                    unistd.close(conn)
                    unistd._exit(1)
                end
                unistd.close(conn)
                unistd._exit(0)
                -- nothing to do for the parent here, we want the parent to return
                -- and wait on accept for a new incoming connection
            end
            unistd.close(conn)
            ::server_continue::
        end
    elseif server_pid > 0 then -- parent
        -- the parent process can just return at this point
        -- we are simply achieving asynchronicity with this
        -- for the server component
        return
    end
end

--- handles writing of the clipboard
-- @pram args the cli args
-- @pram sqlite_handle db handle
local function clipboard_writer(args, sqlite_handle)
    local server_pid, errmsg = unistd.fork()
    if server_pid == nil then -- error
        log_to_syslog(errmsg, posix_syslog.LOG_CRIT)
        lclip_exit(1)
    elseif server_pid == 0 then
        local return_code
        while true do
            local clip_content = get_clipboard_content(args)
            if clip_content == nil then goto continue end
            -- remove trailing/leading whitespace
            clip_content = string.gsub(clip_content, '^%s*(.-)%s*$', '%1')

            if clip_content == nil then goto continue end
            local insert_string = string.format(sql_insert, clip_content)

            local cpid, errmsg = unistd.fork()
            if cpid == nil then -- error
                log_to_syslog(errmsg, posix_syslog.LOG_CRIT)
                lclip_exit(1)
            elseif cpid == 0 then -- child
                if detect_secrets(clip_content, args) then
                    return_code = sqlite_handle:exec(insert_string)
                    if return_code ~= sqlite3.OK then
                        log_to_syslog(tostring(return_code),
                                      posix_syslog.LOG_WARNING)
                    end
                end
                unistd._exit(0)
                -- parent should just return to wait on the next
                -- incoming event from clipnotify
            end
            ::continue::
        end
    elseif server_pid > 0 then
        return
    end
end

--- The clipboard's main loop
-- @param args the cli args
local function loop(args)
    local sqlite_handle = get_sqlite_handle(args["db_path"])

    -- create the table if it does not exist
    local return_code = sqlite_handle:exec(sql_create_table)
    if return_code ~= sqlite3.OK then
        log_to_syslog(tostring(return_code), posix_syslog.LOG_CRIT)
        log_to_syslog("could not create table", posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end

    -- add the old_reap trigger
    sql_old_reap_trigger =
        string.format(sql_old_reap_trigger, args["hist_size"])
    return_code = sqlite_handle:exec(sql_old_reap_trigger)
    if return_code ~= sqlite3.OK then
        log_to_syslog(tostring(return_code), posix_syslog.LOG_CRIT)
        log_to_syslog("could not add old_reap trigger to table",
                      posix_syslog.LOG_CRIT)
        lclip_exit(1)
    end

    -- run the server process
    run_server(args, sqlite_handle)

    -- run the clipboard writer process
    clipboard_writer(args, sqlite_handle)

    while true do
        local pid = posix_wait.wait(-1)
        while pid do pid = posix_wait.wait(-1) end
    end
end

--- The entry point.
local function main()
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
    signal.signal(signal.SIGCHLD, function()
        local pid = posix_wait.wait(-1)
        while pid do pid = posix_wait.wait(-1) end
    end)

    local args = parser:parse()
    make_tmp_dirs()
    check_pid_file()
    write_pid_file()
    check_uid_gid()
    local status, err = pcall(loop, args)
    if status ~= true then log_to_syslog(err, posix_syslog.LOG_CRIT) end
end

local status, _ = pcall(main)
if status ~= true then remove_pid_file() end
