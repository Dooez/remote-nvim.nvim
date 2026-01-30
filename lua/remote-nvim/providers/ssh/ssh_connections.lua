local Connections = require("remote-nvim.providers.connections")
local Path = require("plenary.path")
local ScanDir = require("plenary.scandir")
local const = require("remote-nvim.constants")
local utils = require("remote-nvim.utils")
local remote_nvim = require("remote-nvim")

---@class remote-nvim.providers.ssh.SSHConnections: remote-nvim.providers.Connections
---@field super remote-nvim.providers.Connections
---@field private _connections_path Path
---@field ssh_binary string
local SSHConnections = Connections:subclass("SSHConnections")

---


---@class BoundConnection
---@field executor remote-nvim.providers.Executor
---@field info remote-nvim.providers.Connections.ConnectionInfo

---@type table<string, BoundConnection>
local bound_connections = {}

---Initialize SSH connections instance
function SSHConnections:init(opts)
  SSHConnections.super.init(self, opts)

  self.ssh_binary = remote_nvim.config.ssh_config.ssh_binary

  self._connections_path = Path:new({ vim.fn.stdpath("data"), const.PLUGIN_NAME, "ssh_connections.json" })
  self._connections_path:touch({ mode = 493, parents = true }) -- Ensure that the path exists
end

---@private
---Reads currenttly saved connections info
---@return table<string, remote-nvim.providers.Connections.ConnectionInfo> saved_connections
function SSHConnections:_read_persistent_connections()
  local data = self._connections_path:read()
  if not data or data == "" then
    return {}
  else
    return vim.json.decode(data)
  end
end

---@private
---@param connections table<string, remote-nvim.providers.Connections.ConnectionInfo> Sessions infos to save
function SSHConnections:_save_persistent_connections(connections)
  self._connections_path:write(vim.json.encode(connections), "w")
end

local function get_or_create_sock_path(id)
  local sock_path = Path:new((vim.uv or vim.loop).os_tmpdir(), const.PLUGIN_NAME)
  if not sock_path:exists() then
    sock_path:mkdir({ parents = true, exists_ok = true })
  end
  if id then
    return Path:new(sock_path, "ssh_connection_" .. id .. ".sock"):absolute()
  end
  return sock_path:absolute()
end


---@private
---@param id string connection id
function SSHConnections:_raw_close_persistent_connection(id)
  local socket_path = get_or_create_sock_path(id)
  utils.get_logger().debug(("killing %s"):format(socket_path))
  return vim.fn.jobstart({ self.ssh_binary, "-S", socket_path, "-O", "exit", "dummyhost" })
end

local socket_lock = false
local acquire_m = function()
  while (socket_lock) do
  end
  socket_lock = true
end
local release_m = function()
  socket_lock = false
end


---@private
---@return table<string, remote-nvim.providers.Connections.ConnectionInfo> saved_connections
function SSHConnections:_update_connections()
  local path = get_or_create_sock_path()
  local files = ScanDir.scan_dir(path)
  local conn_ids = {}
  for _, v in ipairs(files) do
    local id = v:match("ssh_connection_([%w_-]+)%.sock")
    if id then
      table.insert(conn_ids, id)
    else
      vim.notify(("Found ssh connection socket with unexpected name '%s'. Skipping..."):format(v), vim.log.levels.WARN)
    end
  end
  local old_connection_data = self:_read_persistent_connections()
  local new_connection_data = {}
  for _, id in ipairs(conn_ids) do
    if old_connection_data[id] then
      new_connection_data[id] = old_connection_data[id]
      old_connection_data[id] = nil
    else
      vim.notify(("Found ssh connection socket with id '%s' with missing info. Closing..."):format(id),
        vim.log.levels.INFO)
      self:_raw_close_persistent_connection(id)
    end
  end
  for id, _ in pairs(old_connection_data) do
    -- vim.notify(("Found ssh connection with id '%s' with missing socket. "):format(id),
    --   vim.log.levels.INFO)
  end
  self:_save_persistent_connections(new_connection_data)

  local updated_b_c = {}
  for id, b_c in pairs(bound_connections) do
    if b_c.executor:last_job_status() <= -1 then
      updated_b_c[id] = b_c
      new_connection_data[id] = b_c.info
    else
      vim.notify(("Remote cnnection %s job status %s"):format(id, b_c.executor:last_job_status()),
        vim.log.levels.WARN)
    end
  end
  bound_connections = updated_b_c
  return new_connection_data
end

---@return table<string, remote-nvim.providers.Connections.ConnectionInfo> connections Currently active connections
function SSHConnections:update_connections()
  acquire_m()
  local connections = self:_update_connections()
  release_m()
  return connections
end

---@param connection_info remote-nvim.providers.Connections.ConnectionInfo
---@param cmd string ssh launch arguments
---@param executor remote-nvim.providers.ssh.SSHExecutor Executor to run remote command on
---@param extra_opts string|string[] extra options passed to the underlying command
function SSHConnections:new_connection(connection_info, cmd, executor, extra_opts)
  local logger = utils.get_logger()
  local extra_opts_tbl = (function(opts)
    local input_opts = type(opts) == "string" and { opts } or opts
    local new_opts = {}
    for _, str in ipairs(input_opts) do
      for opt in str:gmatch("%S+") do
        table.insert(new_opts, opt)
      end
    end
    return new_opts
  end)(extra_opts)
  acquire_m()
  local conns = self:_update_connections()
  if connection_info.connection_id and conns[connection_info.connection_id] then
    release_m()
    error(("Connection with id %s is already exists"):format(connection_info.connection_id), vim.log.levels.ERROR)
  end
  connection_info.connection_id = connection_info.connection_id or utils.generate_random_string(10)

  logger.debug(("New connection is persistent: %s"):format(connection_info.persistent))
  if connection_info.persistent then
    local socket_path = get_or_create_sock_path(connection_info.connection_id)
    local ssh_args = { "-M", "-S", socket_path }
    vim.list_extend(ssh_args, extra_opts_tbl)
    vim.list_extend(ssh_args, { executor.ssh_conn_opts, executor.host, cmd })

    local uv = vim.uv or vim.loop
    local handle, pid = uv.spawn(executor.ssh_binary, { args = ssh_args, detached = true, }, function() end)
    if not pid then
      release_m()
      error("Could not spawn new session")
    end
    uv.unref(handle)

    connection_info.started_time = os.date(remote_nvim.config.ui.connection_start_date_format)
    conns[connection_info.connection_id] = connection_info
    self:_save_persistent_connections(conns)

    logger.debug(("Awaiting socket %s creation"):format(socket_path))
    local timeout = 10000
    local socket_created = vim.wait(timeout, function()
      return Path:new({ socket_path }):exists()
    end)
    release_m()
    if not socket_created then
      local err_msg = ("Socket not created after %s ms. Command: %s %s"):format(timeout, executor.ssh_binary,
        table.concat(ssh_args, " "))
      logger.error(err_msg)
      error(err_msg)
    else
      logger.debug(("Spawned: <%s> %s %s"):format(connection_info.connection_id, executor.ssh_binary,
        table.concat(ssh_args, " ")))
    end
  else
    release_m()

    local function _run_code_in_coroutine(fn, desc)
      local co = coroutine.create(function()
        xpcall(fn, function(err)
          logger.error(debug.traceback(coroutine.running(), ("'%s' failed"):format(desc)), err)
          vim.notify("An error occurred. Check logs using :RemoteLog", vim.log.levels.ERROR)
        end)
      end)
      local success, res_or_err = coroutine.resume(co)
      if not success then
        logger.error(debug.traceback(co, ("'%s' failed"):format(desc)), res_or_err)
        vim.notify("An error occurred. Check logs using :RemoteLog", vim.log.levels.ERROR)
      end
    end

    _run_code_in_coroutine(function()
      executor:run_command(cmd, { additional_conn_opts = table.concat(extra_opts_tbl, " "), })
    end, "Spawning Remote Neovim server")
    connection_info.started_time = os.date(remote_nvim.config.ui.connection_start_date_format)
    logger.debug(("Started bound cnnection %s job status %s"):format(connection_info.connection_id,
      executor:last_job_status()))
    bound_connections[connection_info.connection_id] = { executor = executor, info = connection_info }
  end
end

---@param ids string|string[] Connecion ids to close
function SSHConnections:close_connections(ids)
  if type(ids) == "string" then
    ids = { ids }
  end
  ids = ids or {}

  acquire_m()
  local connections = self:_update_connections()
  local jobs = {}
  for _, id in ipairs(ids) do
    if connections[id] then
      if connections[id].persistent then
        table.insert(jobs, self:_raw_close_persistent_connection(id))
      else
        vim.fn.jobstop(bound_connections[id].executor:last_job_id())
        bound_connections[id] = nil
      end
      connections[id] = nil
    end
  end
  local new_persistent = {}
  for id, conn in pairs(connections) do
    if conn.persistent then
      new_persistent[id] = conn
    end
  end
  vim.fn.jobwait(jobs, 1000)
  self:_save_persistent_connections(new_persistent)
  release_m()
end

return SSHConnections
