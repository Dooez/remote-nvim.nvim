---@class remote-nvim.providers.Connections.ConnectionInfo
---@field unique_host_id string Host name
---@field workspace_id string Host workspace identifier
---@field connection_id? string Session identifier
---@field cwd? string CWD of neovim instance
---@field local_port string
---@field workspace remote-nvim.providers.WorkspaceConfig
---@field started_time? string time of start
---@field persistent boolean Is the connection not bound to the current neovim session

---@class remote-nvim.providers.Connections: remote-nvim.Object
---@field private _connections table<string, remote-nvim.providers.Provider> Map of host and associated session
---@field private remote_workspaces_config remote-nvim.ConfigProvider

---@class remote-nvim.providers.Connections
local Connections = require("remote-nvim.middleclass")("Connections")

---Initialize session provider
---@diagnostic disable-next-line: unused-local
function Connections:init(opts)
end

---@return table<string, remote-nvim.providers.Connections.ConnectionInfo> connections Currently active connections
function Connections:update_connections()
  error("not implemented")
end

---@param connection_info remote-nvim.providers.Connections.ConnectionInfo
---@param cmd string command to launch inside the connection
---@param executor remote-nvim.providers.Executor Executor to run remote command on
---@param extra_opts string|string[] extra options passed to the underlying command
---@diagnostic disable-next-line: unused-local
function Connections:new_connection(connection_info, cmd, executor, extra_opts)
  error("not implemented")
end

---@param ids string|string[] Connecion ids to close
---@diagnostic disable-next-line: unused-local
function Connections:close_connections(ids)
  error("not implemented")
end

return Connections
