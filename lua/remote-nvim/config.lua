---@class remote-nvim.ConfigProvider: remote-nvim.Object
---@field private _workspaces_path table Plenary path object representing configuration path
local ConfigProvider = require("remote-nvim.middleclass")("ConfigProvider")
local Path = require("plenary.path")
local const = require("remote-nvim.constants")
local utils = require("remote-nvim.utils")

---@type table<string, remote-nvim.providers.WorkspaceConfig> Configuration data
local config_data = {}


---Initialize config provider instance
function ConfigProvider:init()
  self._workspaces_path =
      Path:new({ vim.fn.stdpath("data"), const.PLUGIN_NAME, "workspaces.json" })
  self._workspaces_path:touch({ mode = 493, parents = true }) -- Ensure that the path exists

  config_data = self:_read_workspace_data()
end

---@private
function ConfigProvider:_read_workspace_data()
  local data = self._workspaces_path:read()
  if not data or data == "" then
    return {}
  else
    return vim.json.decode(data) or {}
  end
end

---@private
---@param workspaces table<string, remote-nvim.providers.WorkspaceConfig>
function ConfigProvider:_save_workspace_data(workspaces)
  self._workspaces_path:write(vim.json.encode(workspaces), "w")
end

---Get configuration data by host or provider type
---@param host_id string? Host identifier
---@param provider_type provider_type? Provider type for the configuration records
---@return table<string,remote-nvim.providers.WorkspaceConfig>|remote-nvim.providers.WorkspaceConfig wk_config Workspace configuration filtered by provided type
function ConfigProvider:get_workspace_config(host_id, provider_type)
  config_data = self:_read_workspace_data()

  local workspace_config
  if provider_type then
    workspace_config = {}
    for ws_id, ws_config in pairs(config_data) do
      if ws_config.provider == provider_type then
        workspace_config[ws_id] = ws_config
      end
    end
  else
    workspace_config = config_data or {}
  end

  if host_id then
    return workspace_config[host_id] or {}
  end

  return workspace_config or {}
end

---Add a workspace config record
---@param unique_ws_id string Host identifier
---@param ws_config remote-nvim.providers.WorkspaceConfig Workspace config to be added
---@return remote-nvim.providers.WorkspaceConfig wk_config Added host configuration
function ConfigProvider:add_workspace_config(unique_ws_id, ws_config)
  assert(ws_config ~= nil, "Workspace config cannot be nil")
  local wk_config = self:update_workspace_config(unique_ws_id, ws_config)
  assert(wk_config ~= nil, ("Added configuration for host %s should not be nil"):format(unique_ws_id))
  return wk_config
end

---Update workspace configuration given host identifier
---@param unique_ws_id string Host identifier for the configuration record
---@param ws_config remote-nvim.providers.WorkspaceConfig? Workspace configuration that should be merged with existing record
---@return remote-nvim.providers.WorkspaceConfig? wk_config nil, if record is deleted, else the updated workspace configuration
function ConfigProvider:update_workspace_config(unique_ws_id, ws_config)
  config_data = self:_read_workspace_data()
  if ws_config then
    utils.get_logger().debug("before " .. unique_ws_id)
    for k, v in pairs(self:get_workspace_config(unique_ws_id)) do
      utils.get_logger().debug(k .. " " .. v)
    end
    local new_conf = vim.tbl_extend("force", self:get_workspace_config(unique_ws_id), ws_config)
    utils.get_logger().debug("after" .. unique_ws_id)
    for k, v in pairs(new_conf) do
      utils.get_logger().debug(k .. " " .. tostring(v))
    end
    config_data[unique_ws_id] = new_conf
  else
    utils.get_logger().debug("removing workspace " .. unique_ws_id)
    config_data[unique_ws_id] = nil
  end
  self._workspaces_path:write(vim.json.encode(config_data), "w")
  return config_data[unique_ws_id]
end

---Delete workspace configuration
---@param host_id string Host identifier for the configuration to be deleted
---@return nil
function ConfigProvider:remove_workspace_config(host_id)
  return self:update_workspace_config(host_id, nil)
end

return ConfigProvider
