local event = require("nui.utils.autocmd").event
local workspace_cfg = require("remote-nvim.config")()
local NuiLine = require("nui.line")
local NuiTree = require("nui.tree")
local Popup = require("nui.popup")
local Split = require("nui.split")
local hl_groups = require("remote-nvim.colors").hl_groups
---@type remote-nvim.RemoteNeovim
local remote_nvim = require("remote-nvim")

---@alias workspaces_node_type "root_node"|"ws_node"|"toggle_head"|"toggle_node"
---@alias workspace_toggle_value "yes"|"no"|"ask"
---@alias connections_node_type "root_node"|"conn_node"|"conn_info_node"

---@class remote-nvim.ui.Dashboard.Keymaps: vim.api.keyset.keymap
---@field key string Key which invokes the keymap action
---@field action function Action to apply when the keymap gets invoked

---@class remove-nvim.ui.Dashboard
---@field private nui NuiSplit|NuiPopup Progress View UI holder
---@field private layout_type "split"|"popup" Type of layout we are using for progress view
---@field private nui_options nui_popup_options|nui_split_options
---@field private hl_namespace integer Namespace for all progress view custom highlights
---@field private buf_options table<string, any> Buffer options for Progress View
---@field private win_options table<string, any> Window options for Progress View
---
---@field private workspaces_pane_bufnr integer Buffer ID of the workspaces buffer
---@field private connections_pane_bufnr integer Buffer ID of the connections buffer
---@field private help_pane_bufnr integer Buffer ID of the help buffer
---
---@field private progress_view_pane_tree NuiTree Tree used to render "Progress View" pane
---@field private workspaces_pane_tree NuiTree Tree used to render "Workspaces" pane
---@field private connections_pane_tree NuiTree Tree used to render "Connections" pane
---
---@field private progress_view_tree_render_linenr number What line number should the tree be rendered from
---@field private worspaces_tree_render_linenr number What line number should the tree be rendered from
---@field private connections_tree_render_linenr number What line number should the tree be rendered from
---
---
---@field private progress_view_keymap_options vim.api.keyset.keymap Default keymap options
---
---@field private run_counter integer Number of runs started

---@class remove-nvim.ui.Dashboard
local Dashboard = {}

local toggle_key_strings = {}

function Dashboard:init()
  local progress_view_config = remote_nvim.config.progress_view
  self.layout_type = progress_view_config.type
  self.hl_namespace = vim.api.nvim_create_namespace("remote_nvim_dashboard_ns")
  self.buf_options = {
    bufhidden = "hide",
    buflisted = false,
    buftype = "nofile",
    modifiable = false,
    readonly = true,
    swapfile = false,
    undolevels = 0,
  }
  self.win_options = {
    number = false,
    relativenumber = false,
    cursorline = false,
    cursorcolumn = false,
    foldcolumn = "0",
    spell = false,
    list = false,
    signcolumn = "auto",
    colorcolumn = "",
    statuscolumn = "",
    fillchars = "eob: ",
  }

  if self.layout_type == "split" then
    self.nui_options = {
      ns_id = self.hl_namespace,
      relative = progress_view_config.relative or "editor",
      position = progress_view_config.position or "right",
      size = progress_view_config.size or "30%",
      win_options = self.win_options,
    }
    ---@diagnostic disable-next-line:param-type-mismatch
    self.nui = Split(self.nui_options)
  else
    self.nui_options = {
      ns_id = self.hl_namespace,
      relative = progress_view_config.relative or "editor",
      position = progress_view_config.position or "50%",
      size = progress_view_config.size or "50%",
      win_options = self.win_options,
      border = progress_view_config.border or "rounded",
      anchor = progress_view_config.anchor,
    }
    ---@diagnostic disable-next-line:param-type-mismatch
    self.nui = Popup(self.nui_options)

    self.nui:on(event.VimResized, function()
      ---@diagnostic disable-next-line:param-type-mismatch
      self.nui:update_layout()
    end)
  end

  self.workspaces_pane_bufnr = vim.api.nvim_create_buf(false, true)
  self.connections_pane_bufnr = vim.api.nvim_create_buf(false, true)
  self.help_pane_bufnr = vim.api.nvim_create_buf(false, true)

  self.progress_view_pane_tree = nil
  self.workspaces_pane_tree = nil
  self.connections_pane_tree = nil

  self.active_progress_view_section_node = nil
  self.progress_view_keymap_options = { noremap = true, nowait = true }

  self.run_counter = 0

  self:_setup_progress_view_pane()
  self:_setup_workspaces_pane()
  self:_setup_connections_pane()
  self:_setup_help_pane()

  return self
end

---@private
---@param bufnr integer Buffer ID
function Dashboard:_set_buffer(bufnr)
  vim.api.nvim_win_set_buf(self.nui.winid, bufnr)
  if bufnr ~= self.nui.bufnr then
    for key, value in pairs(self.win_options) do
      vim.api.nvim_set_option_value(key, value, {
        win = self.nui.winid,
      })
    end
  end
end

-- ---Switch to one of the pane in Progress View window
-- ---@param pane "progress_view"|"session_info"|"help"
-- ---@param collapse_nodes boolean?
-- function Dashboard:switch_to_pane(pane, collapse_nodes)
--   collapse_nodes = collapse_nodes or false
--   if pane == "progress_view" then
--     self:_set_buffer(self.nui.bufnr)
--     if collapse_nodes then
--       self:_collapse_all_nodes(self.progress_view_pane_tree, self.progress_view_tree_render_linenr)
--     end
--   elseif pane == "session_info" then
--     self:_set_buffer(self.session_info_pane_bufnr)
--     if collapse_nodes then
--       self:_collapse_all_nodes(self.session_info_pane_tree, self.session_info_tree_render_linenr)
--     end
--   else
--     self:_set_buffer(self.help_pane_bufnr)
--   end
-- end

---@private
---Set top line for each of the buffer
---@param bufnr number Buffer ID
function Dashboard:_set_top_line(bufnr)
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true

  local active_hl = hl_groups.RemoteNvimActiveHeading.name
  local inactive_hl = hl_groups.RemoteNvimInactiveHeading.name
  local progress_hl = (bufnr == self.nui.bufnr) and active_hl or inactive_hl
  local workspaces_hl = (bufnr == self.workspaces_pane_bufnr) and active_hl or inactive_hl
  local conn_hl = (bufnr == self.connections_pane_bufnr) and active_hl or inactive_hl
  local help_hl = (bufnr == self.help_pane_bufnr) and active_hl or inactive_hl

  vim.api.nvim_buf_set_lines(bufnr, 0, vim.api.nvim_buf_line_count(bufnr) - 1, true, {})
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, true, { "" })
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  local line = NuiLine()
  line:append(" ")
  line:append(" Progress View (P) ", progress_hl)
  line:append(" ")
  line:append(" Workspaces (W) ", workspaces_hl)
  line:append(" ")
  line:append(" Connections (C) ", conn_hl)
  line:append(" ")
  line:append(" Help (?) ", help_hl)
  line:render(bufnr, -1, line_count)

  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, true, { "" })

  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modifiable = false
end

---Show the progress viewer
function Dashboard:show()
  -- Update layout because progressview internally holds the window ID relative to which
  -- it should create the split/popup in case of rel="win". If it no longer exists, it
  -- will throw an error. So, we update the layout to get the latest window ID.
  if self.layout_type == "split" then
    self.nui:update_layout(self.nui_options)
  end
  self.nui:show()
  vim.api.nvim_set_current_win(self.nui.winid)
end

---Hide the progress viewer
function Dashboard:hide()
  self.nui:hide()
end

---@private
---Collapse all nodes for a tree
---@param tree NuiTree The tree whose all nodes should be collapsed
---@param start_linenr integer On which line should tree start rendering
local collapse_all_nodes = function(tree, start_linenr)
  local updated = false

  for _, node in pairs(tree.nodes.by_id) do
    updated = node:collapse() or updated
  end

  if updated then
    tree:render(start_linenr)
  end
end

---@private
---Expand all nodes for a tree
---@param tree NuiTree The tree whose all nodes should be expanded
---@param start_linenr integer On which line should tree start rendering
local expand_all_nodes = function(tree, start_linenr)
  local updated = false

  for _, node in pairs(tree.nodes.by_id) do
    updated = node:expand() or updated
  end

  if updated then
    tree:render(start_linenr)
  end
end

---Returns next run counter
---@return integer cnt
function Dashboard:get_next_run_counter()
  local cnt = self.run_counter
  self.run_counter = self.run_counter + 1
  return cnt
end

---@private
---Set up progress view pane
function Dashboard:_setup_progress_view_pane()
  self.progress_view_pane_tree = NuiTree({
    ns_id = self.hl_namespace,
    winid = self.nui.winid,
    bufnr = self.nui.bufnr,
    prepare_node = function(node, _)
      local line = NuiLine()

      line:append(string.rep(" ", node:get_depth()))

      ---@type progress_view_node_type
      local node_type = node.type
      ---@type progress_view_status
      local node_status = node.status or "no_op"

      local highlight = nil

      if node_status == "success" then
        highlight = hl_groups.RemoteNvimSuccess
      elseif node_status == "failed" then
        highlight = hl_groups.RemoteNvimFailure
      elseif node_status == "running" then
        highlight = hl_groups.RemoteNvimRunning
      elseif vim.tbl_contains({ "run_node", "section_node" }, node_type) then
        highlight = hl_groups.RemoteNvimHeading
      elseif node_type == "stdout_node" then
        highlight = hl_groups.RemoteNvimOutput
      elseif node_type == "command_node" then
        highlight = hl_groups.RemoteNvimInfoValue
      end
      highlight = highlight and highlight.name

      ---@type progress_view_node_type[]
      local section_nodes = { "section_node", "run_node" }
      if vim.tbl_contains(section_nodes, node.type) then
        line:append(node:is_expanded() and " " or " ", highlight)
      else
        line:append(" ")
      end

      if node_type == "command_node" then
        line:append("Command: ", hl_groups.RemoteNvimInfoKey.name)
      end
      line:append(node.text, highlight)

      if node_type == "run_node" and vim.tbl_contains({ "success", "failed" }, node_status) then
        line:append(" (no longer active)", hl_groups.RemoteNvimSubInfo.name)
      end

      if node_type == "command_node" then
        return {
          line,
          NuiLine(),
        }
      end
      return line
    end,
  })
  self:_set_top_line(self.nui.bufnr)
  self.progress_view_tree_render_linenr = vim.api.nvim_buf_line_count(self.nui.bufnr) + 1

  -- Set up key bindings
  local keymaps = self:_get_common_keymaps()
  local tree_keymaps = self:_get_tree_keymaps(self.progress_view_pane_tree, self.progress_view_tree_render_linenr)
  keymaps = vim.list_extend(keymaps, tree_keymaps)
  self:_set_buffer_keymaps(self.nui.bufnr, keymaps)
end

function Dashboard:update_progress_view()
  self.progress_view_pane_tree:render(self.progress_view_tree_render_linenr)
end

---@private
---Initialize session tree
function Dashboard:_initialize_workspaces_tree()
  self.workspaces_pane_tree = NuiTree({
    ns_id = self.hl_namespace,
    winid = self.nui.winid,
    bufnr = self.workspaces_pane_bufnr,
    prepare_node = function(node, parent_node)
      local line = NuiLine()

      line:append(string.rep(" ", node:get_depth()))

      ---@type workspaces_node_type
      local node_type = node.type

      if node_type == "root_node" then
        line:append((node:is_expanded() and " " or " ") .. node.key .. ": ", hl_groups.RemoteNvimHeading.name)
      elseif node_type == "toggle_head" then
        line:append((node:is_expanded() and " " or " ") .. node.key, hl_groups.RemoteNvimInfoKey.name)
      elseif node_type == "toggle_node" then
        local toggle = node.value == nil and "ask" or node.value and "yes" or "no"
        local active = hl_groups.RemoteNvimToggleActive.name
        local inactive = hl_groups.RemoteNvimToggleInactive.name
        line:append(" " .. toggle_key_strings[node.key] .. ": ", hl_groups.RemoteNvimInfoKey.name)
        line:append(" ask ", toggle == "ask" and active or inactive)
        line:append(" yes ", toggle == "yes" and active or inactive)
        line:append(" no ", toggle == "no" and active or inactive)
      else
        line:append(node.key .. ": ", hl_groups.RemoteNvimInfoKey.name)
        line:append(node.value or "<not-provided>", hl_groups.RemoteNvimInfoValue.name)
      end

      if parent_node and parent_node.last_child_id == node:get_id() then
        return {
          line,
          NuiLine(),
        }
      end
      return line
    end,
  })

  ---@param ws_cfg remote-nvim.providers.WorkspaceConfig
  local add_workspace_node = function(ws_cfg)
    local root_node = NuiTree.Node({
      key = ws_cfg.workspace_id,
      value = ws_cfg.host,
      type = "root_node",
      workspace_config = ws_cfg,
    })
    self.workspaces_pane_tree:add_node(root_node)
    local root_id = root_node:get_id()
    local function add_line(key, value)
      value = value or "<not-provided>"
      local node = NuiTree.Node({
        key = key,
        value = value,
        type = "ws_node",
        parent_node = root_node,
        workspace_config = ws_cfg,
      })
      self.workspaces_pane_tree:add_node(node, root_id)
      root_node.last_child_id = node:get_id()
    end
    add_line("OS              ", ws_cfg.os)
    add_line("Connection type ", ws_cfg.provider)
    add_line("Host URI        ", ws_cfg.host)
    add_line("Connection opts ", (ws_cfg.connection_options == "" and "<no-extra-options>" or ws_cfg.connection_options))
    add_line("Neovim version  ", ws_cfg.neovim_version)
    add_line("Last sync       ", ws_cfg.last_sync)
    local toggle_head = NuiTree.Node({
      key = "Launch options",
      -- value = value,
      type = "toggle_head",
      parent_node = root_node,
      workspace_config = ws_cfg,
    })
    self.workspaces_pane_tree:add_node(toggle_head, root_id)
    local toggle_head_id = toggle_head:get_id()
    local add_toggle_line = function(key, value)
      local node = NuiTree.Node({
        key = key,
        value = ws_cfg[key],
        type = "toggle_node",
        locked = false,
        parent_node = root_node,
        workspace_config = ws_cfg,
      })
      self.workspaces_pane_tree:add_node(node, toggle_head_id)
      root_node.last_child_id = node:get_id()
    end
    add_toggle_line("config_copy")
    add_toggle_line("dot_config_copy")
    add_toggle_line("data_copy")
    add_toggle_line("client_auto_start")
  end
  local workspaces = workspace_cfg:get_workspace_config()
  for id, ws in pairs(workspaces) do
    ws.host_id = id --TODO: remove, this is a hack
    add_workspace_node(ws)
  end
end

---@private
---Set up "Workspaces" pane
function Dashboard:_setup_workspaces_pane()
  self:_set_top_line(self.workspaces_pane_bufnr)
  self.workspaces_tree_render_linenr = vim.api.nvim_buf_line_count(self.workspaces_pane_bufnr) + 1
  self:_initialize_workspaces_tree()

  -- Set up key bindings
  local keymaps = self:_get_common_keymaps()
  local tree_keymaps = self:_get_tree_keymaps(self.workspaces_pane_tree, self.workspaces_tree_render_linenr)
  local ws_keymaps = self:_get_workspaces_keymaps(self.workspaces_pane_tree, self.workspaces_tree_render_linenr)
  keymaps = vim.list_extend(keymaps, tree_keymaps)
  keymaps = vim.list_extend(keymaps, ws_keymaps)
  self:_set_buffer_keymaps(self.workspaces_pane_bufnr, keymaps)

  for key, val in pairs(self.buf_options) do
    vim.api.nvim_set_option_value(key, val, {
      buf = self.workspaces_pane_bufnr,
    })
  end

  self.workspaces_pane_tree:render(self.workspaces_tree_render_linenr)
end

---@private
---Initialize session tree
function Dashboard:_initialize_connections_tree()
  self.connections_pane_tree = NuiTree({
    ns_id = self.hl_namespace,
    winid = self.nui.winid,
    bufnr = self.connections_pane_bufnr,
    prepare_node = function(node, parent_node)
      local line = NuiLine()

      line:append(string.rep(" ", node:get_depth()))

      ---@type connections_node_type
      local node_type = node.type

      if node_type == "root_node" then
        line:append((node:is_expanded() and " " or " ") .. node.key .. ": ", hl_groups.RemoteNvimHeading.name)
      else
        line:append(" ")
        line:append(node.key .. ": ", hl_groups.RemoteNvimInfoKey.name)
      end
      line:append(node.value or "<not-provided>", hl_groups.RemoteNvimInfoValue.name)

      if parent_node and parent_node.last_child_id == node:get_id() then
        return {
          line,
          NuiLine(),
        }
      end
      return line
    end,
  })

  ---@param conn_inf remote-nvim.providers.Connections.ConnectionInfo
  local add_connection_node = function(conn_inf)
    local root_node = NuiTree.Node({
      key = conn_inf.connection_id,
      value = conn_inf.workspace.host,
      type = "root_node",
      connection = conn_inf,
    })
    self.connections_pane_tree:add_node(root_node)
    local root_id = root_node:get_id()
    local function add_line(key, value)
      value = value or "<not-provided>"
      local node = NuiTree.Node({
        key = key,
        value = value,
        type = "conn_node",
        parent_node = root_node,
        connection = conn_inf,
      })
      self.connections_pane_tree:add_node(node, root_id)
      root_node.last_child_id = node:get_id()
    end
    add_line("Connection type ", conn_inf.workspace.provider .. (conn_inf.persistent and "" or " ()"))
    add_line("Local port      ", conn_inf.local_port)
    add_line("Started         ", conn_inf.started_time)
  end
  local ssh_conn = require("remote-nvim.providers.ssh.ssh_connections")()
  for _, ws in pairs(ssh_conn:update_connections()) do
    add_connection_node(ws)
  end
end

---@private
---Set up "connections" pane
function Dashboard:_setup_connections_pane()
  self:_set_top_line(self.connections_pane_bufnr)
  self.connections_tree_render_linenr = vim.api.nvim_buf_line_count(self.connections_pane_bufnr) + 1
  self:_initialize_connections_tree()

  -- Set up key bindings
  local keymaps = self:_get_common_keymaps()
  local tree_keymaps = self:_get_tree_keymaps(self.connections_pane_tree, self.connections_tree_render_linenr)
  local conn_keymaps = self:_get_connections_keymaps(self.connections_pane_tree, self.connections_tree_render_linenr)
  keymaps = vim.list_extend(keymaps, tree_keymaps)
  keymaps = vim.list_extend(keymaps, conn_keymaps)
  self:_set_buffer_keymaps(self.connections_pane_bufnr, keymaps)

  for key, val in pairs(self.buf_options) do
    vim.api.nvim_set_option_value(key, val, {
      buf = self.connections_pane_bufnr,
    })
  end

  self.connections_pane_tree:render(self.connections_tree_render_linenr)
end

---@private
---Keymaps to apply on the buffer
---@param bufnr integer Buffer ID on which the keymap should be set
---@param keymaps remote-nvim.ui.Dashboard.Keymaps[] List of keymaps to set up on the buffer
function Dashboard:_set_buffer_keymaps(bufnr, keymaps)
  for _, val in ipairs(keymaps) do
    local options = vim.deepcopy(self.progress_view_keymap_options)
    options["callback"] = val.action
    vim.api.nvim_buf_set_keymap(bufnr, "n", val.key, "", options)
  end
end

---@private
---Set up "Help" pane
function Dashboard:_setup_help_pane()
  self:_set_top_line(self.help_pane_bufnr)
  local line_nr = vim.api.nvim_buf_line_count(self.help_pane_bufnr) + 1

  local keymaps = self:_get_common_keymaps()
  self:_set_buffer_keymaps(self.help_pane_bufnr, keymaps)

  -- Get tree keymaps (we use this to set help and do not set up any extra keybindings)
  local tree_keymaps = self:_get_tree_keymaps(self.progress_view_pane_tree, self.progress_view_tree_render_linenr)
  vim.list_extend(keymaps, tree_keymaps)

  local max_length = 0
  for _, v in ipairs(keymaps) do
    max_length = math.max(max_length, #v.key)
  end

  vim.bo[self.help_pane_bufnr].readonly = false
  vim.bo[self.help_pane_bufnr].modifiable = true

  -- Add Keyboard shortcuts heading
  local line = NuiLine()
  line:append(" Keyboard shortcuts", hl_groups.RemoteNvimHeading.name)
  line:render(self.help_pane_bufnr, -1, line_nr)
  vim.api.nvim_buf_set_lines(self.help_pane_bufnr, line_nr, line_nr, true, { "" })
  line_nr = line_nr + 2

  for _, v in ipairs(keymaps) do
    line = NuiLine()

    line:append("  " .. v.key .. string.rep(" ", max_length - #v.key), hl_groups.RemoteNvimInfoKey.name)
    line:append(" " .. v.desc, hl_groups.RemoteNvimInfoValue.name)
    line:render(self.help_pane_bufnr, -1, line_nr)
    line_nr = line_nr + 1
  end

  for key, val in pairs(self.buf_options) do
    vim.api.nvim_set_option_value(key, val, {
      buf = self.help_pane_bufnr,
    })
  end
end

---@private
---@param tree NuiTree Tree on which keymaps will be set
---@param start_linenr number What line number on the buffer should the tree be rendered from
---@return remote-nvim.ui.Dashboard.Keymaps[]
function Dashboard:_get_tree_keymaps(tree, start_linenr)
  if tree == nil or start_linenr == nil then
    return {}
  end
  return {
    {
      key = "l",
      action = function()
        local node = tree:get_node()

        if node and node:expand() then
          tree:render(start_linenr)
        else
          vim.api.nvim_feedkeys("l", "n", true)
        end
      end,
      desc = "Expand current heading",
    },
    {
      key = "h",
      action = function()
        local node = tree:get_node()

        if node and node:collapse() then
          tree:render(start_linenr)
        else
          vim.api.nvim_feedkeys("h", "n", true)
        end
      end,
      desc = "Collapse current heading",
    },
    {
      key = "<CR>",
      action = function()
        local node = tree:get_node()

        if node then
          if node:is_expanded() then
            node:collapse()
          else
            node:expand()
          end
          tree:render(start_linenr)
        else
          vim.api.nvim_feedkeys("<CR>", "n", true)
        end
      end,
      desc = "Toggle current heading",
    },
    {
      key = "L",
      action = function()
        expand_all_nodes(tree, start_linenr)
      end,
      desc = "Expand all headings",
    },
    {
      key = "H",
      action = function()
        collapse_all_nodes(tree, start_linenr)
      end,
      desc = "Collapse all headings",
    },
  }
end

---@private
---Get keymaps that apply to all panes
---@return remote-nvim.ui.Dashboard.Keymaps[]
function Dashboard:_get_common_keymaps()
  return {
    {
      key = "P",
      action = function()
        self:_set_buffer(self.nui.bufnr)
      end,
      desc = "Switch to Progress view",
    },
    {
      key = "W",
      action = function()
        self:_set_buffer(self.workspaces_pane_bufnr)
        self:_setup_workspaces_pane()
      end,
      desc = "Switch to Workspaces view",
    },
    {
      key = "C",
      action = function()
        self:_set_buffer(self.connections_pane_bufnr)
        self:_setup_connections_pane()
      end,
      desc = "Switch to Connections view",
    },
    {
      key = "?",
      action = function()
        local switch_to_bufnr = (vim.api.nvim_win_get_buf(self.nui.winid) == self.help_pane_bufnr)
            and self.nui.bufnr
            or self.help_pane_bufnr
        self:_set_buffer(switch_to_bufnr)
      end,
      desc = "Toggle help window",
    },
    {
      key = "q",
      action = function()
        self:hide()
      end,
      desc = "Close Progress view",
    },
  }
end

---@private
---@param tree NuiTree Tree on which keymaps will be set
---@param start_linenr number What line number on the buffer should the tree be rendered from
---@return remote-nvim.ui.Dashboard.Keymaps[]
function Dashboard:_get_workspaces_keymaps(tree, start_linenr)
  if tree == nil or start_linenr == nil then
    return {}
  end
  return {
    {
      key = "t",
      action = function()
        local node = tree:get_node()
        if not node then return end
        if not node.type == "toggle_node" then return end

        ---@type remote-nvim.providers.WorkspaceConfig
        local ws_cfg = node.workspace_config
        local new_ws_cfg = workspace_cfg:get_workspace_config(ws_cfg.host_id, ws_cfg.provider)
        local value = new_ws_cfg[node.key]

        if value == nil then
          new_ws_cfg[node.key] = true
        elseif value then
          new_ws_cfg[node.key] = false
        else
          new_ws_cfg[node.key] = nil
        end
        workspace_cfg:update_workspace_config(ws_cfg.host_id)
        workspace_cfg:update_workspace_config(ws_cfg.host_id, new_ws_cfg)
        node.value = new_ws_cfg[node.key]
        tree:render(start_linenr)
      end,
      desc = "[t]oggle launch option",
    },
    {
      key = "A",
      action = function()
        local ssh_args = vim.trim(vim.fn.input("ssh "))
        if ssh_args == "" then
          return
        end
        local ssh_host = ssh_args:match("%S+@%S+")

        --- If there is only one parameter provided, it must be remote host
        if #vim.split(ssh_args, "%s") == 1 then
          ssh_host = ssh_args
        end

        if ssh_host == nil or ssh_host == "" then
          vim.notify("Could not automatically determine host", vim.log.levels.WARN)
          ssh_host = vim.fn.input("Enter hostname in conn. string: ")
        end

        -- If no valid host name has been provided, exit
        if ssh_host == "" then
          vim.notify("Failed to determine the host to connect to. Aborting..", vim.log.levels.ERROR)
          return
        end

        remote_nvim.session_provider
            :get_or_initialize_session({
              host = ssh_host,
              provider_type = "ssh",
              conn_opts = { ssh_args },
            }):sync()
      end,
      desc = "Spawn [N]ew Connection",
    },
    {
      key = "N",
      action = function()
        local node = tree:get_node()
        if not node then return end

        local devpod_utils = require("remote-nvim.providers.devpod.devpod_utils")
        ---@type remote-nvim.providers.WorkspaceConfig
        local ws_cfg = node.workspace_config
        ---@type remote-nvim.providers.ProviderOpts
        local opts = {
          host = ws_cfg.host,
          provider_type = ws_cfg.provider,
          conn_opts = { ws_cfg.connection_options },
          devpod_opts = devpod_utils.get_workspace_devpod_opts(ws_cfg),
          progress_view = require("remote-nvim.ui.progressview")(),
        }
        ---@type remote-nvim.providers.Provider
        local provider
        if opts.provider_type == "ssh" then
          provider = require("remote-nvim.providers.ssh.ssh_provider")(opts)
        elseif opts.provider_type == "devpod" then
          provider = require("remote-nvim.providers.devpod.devpod_provider")(devpod_utils.get_devpod_provider_opts(opts))
        else
          error("Unknown provider type")
        end
        self:_set_buffer(self.nui.bufnr)
        provider:spawn()
      end,
      desc = "Spawn [N]ew Connection",
    },
    {
      key = "E",
      action = function()
        local node = tree:get_node()
        if not node then return end

        local devpod_utils = require("remote-nvim.providers.devpod.devpod_utils")
        ---@type remote-nvim.providers.WorkspaceConfig
        local ws_cfg = node.workspace_config
        ---@type remote-nvim.providers.ProviderOpts
        local opts = {
          host = ws_cfg.host,
          provider_type = ws_cfg.provider,
          conn_opts = { ws_cfg.connection_options },
          devpod_opts = devpod_utils.get_workspace_devpod_opts(ws_cfg),
          progress_view = require("remote-nvim.ui.progressview")(),
        }
        ---@type remote-nvim.providers.Provider
        local provider
        if opts.provider_type == "ssh" then
          provider = require("remote-nvim.providers.ssh.ssh_provider")(opts)
        elseif opts.provider_type == "devpod" then
          provider = require("remote-nvim.providers.devpod.devpod_provider")(devpod_utils.get_devpod_provider_opts(opts))
        else
          error("Unknown provider type")
        end
        self:_set_buffer(self.nui.bufnr)
        provider:sync()
      end,
      desc = "Sync Workspace",
    },
  }
end

---@private
---@param tree NuiTree Tree on which keymaps will be set
---@param start_linenr number What line number on the buffer should the tree be rendered from
---@return remote-nvim.ui.Dashboard.Keymaps[]
function Dashboard:_get_connections_keymaps(tree, start_linenr)
  if tree == nil or start_linenr == nil then
    return {}
  end
  return {
    {
      key = "Y",
      action = function()
        local node = tree:get_node()
        if not node then return end
        ---@type remote-nvim.providers.Connections.ConnectionInfo
        local info = node.connection
        local launch_cmd = "nvim --remote-ui --server localhost:" .. info.local_port
        vim.fn.setreg("+", launch_cmd)
        vim.notify(("Yanked `%s`"):format(launch_cmd), vim.log.levels.INFO)
      end,
      desc = "[Y]ank Connection String",
    },
    {
      key = "L",
      action = function()
        local node = tree:get_node()
        if not node then return end
        ---@type remote-nvim.providers.Connections.ConnectionInfo
        local info = node.connection
        remote_nvim.config.client_callback(info.local_port, info.workspace)
      end,
      desc = "[L]aunch new local client",
    },
    {
      key = "K",
      action = function()
        local node = tree:get_node()
        if not node then return end
        ---@type remote-nvim.providers.Connections.ConnectionInfo
        local info = node.connection
        local ssh_conn = require("remote-nvim.providers.ssh.ssh_connections")()
        ssh_conn:close_connections(info.connection_id)
        self:_setup_connections_pane()
      end,
      desc = "[K]ill the connection",
    },
  }
end

---@format disable
toggle_key_strings = {
  config_copy =       "Sync neovim config ",
  dot_config_copy =   "Sync .config       ",
  data_copy =         "Sync neovim data   ",
  client_auto_start = "Start local client "
}

return Dashboard:init()
