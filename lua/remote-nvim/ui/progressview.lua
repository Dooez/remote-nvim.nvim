local Deque = require("remote-nvim.structs.deque")
local NuiTree = require("nui.tree")
---@type remote-nvim.RemoteNeovim
local remote_nvim = require("remote-nvim")

---@alias progress_view_node_type "run_node"|"section_node"|"command_node"|"stdout_node"
---@alias session_node_type "local_node"|"remote_node"|"config_node"|"root_node"|"info_node"
---@alias workspaces_node_type "root_node"|"ws_node"|"ws_info_node"
---@alias connections_node_type "root_node"|"conn_node"|"conn_info_node"
---@alias progress_view_status "running"|"success"|"failed"|"no_op"

---@class remote-nvim.ui.ProgressView.Keymaps: vim.api.keyset.keymap
---@field key string Key which invokes the keymap action
---@field action function Action to apply when the keymap gets invoked

---@class remote-nvim.ui.ProgressView.ProgressInfoNode
---@field text string? Text to insert
---@field set_parent_status boolean? Should set parent status
---@field status progress_view_status? Status of the node
---@field type progress_view_node_type Type of line

---@class remote-nvim.ui.ProgressView.SessionInfoNode
---@field key string? Key for the info
---@field value string? Text to insert
---@field holds session_node_type? Type of nodes it contains
---@field type session_node_type Type of the node
---@field last_child_id NuiTree.Node? Last inserted child's ID

---@class remote-nvim.ui.ProgressView
---@field private progress_view_pane_tree NuiTree Tree used to render "Progress View" pane
---@field private active_progress_view_section_node NuiTree.Node?
---@field private active_progress_view_run_node NuiTree.Node?
---@field private section_deque_map table<string, remote-nvim.structs.Deque> Deque to handle too much output
---@field private max_output_lines integer

---@class remote-nvim.ui.ProgressView
local ProgressView = require("remote-nvim.middleclass")("ProgressView")

function ProgressView:init()
  self.progress_view_pane_tree = remote_nvim.dashboard.progress_view_pane_tree
  self.section_deque_map = {}
  self.max_output_lines = 30
end

function ProgressView:start_run(title)
  local run_node = self:add_progress_node({
    text = title,
    type = "run_node",
  })
  return run_node
end

---Add a node to the progress view pane
---@param node remote-nvim.ui.ProgressView.ProgressInfoNode Node to insert into progress view tree
---@param parent_node NuiTree.Node? Node under which the new node should be inserted
---@return NuiTree.Node created_node The node that was created and inserted into the progress tree
function ProgressView:add_progress_node(node, parent_node)
  ---@type progress_view_status
  local status = node.status or "no_op"

  ---@type NuiTree.Node
  local created_node
  if node.type == "run_node" then
    created_node = self:_add_progress_view_run_heading(node)
  elseif node.type == "section_node" then
    created_node = self:_add_progress_view_section_heading(node, parent_node)
  else
    created_node = self:_add_progress_view_output_node(node, parent_node)
  end

  self:update_status(status, node.set_parent_status, created_node)

  return created_node
end

---Update status of the node and if needed, it's parent nodes
---@param status progress_view_status Status to apply on the node
---@param should_update_parent_status boolean? Should all parent nodes of the node being updated be updated as well
---@param node NuiTree.Node?
function ProgressView:update_status(status, should_update_parent_status, node)
  node = node or self.active_section_node or self.active_run_node
  assert(node ~= nil, "Node should not be nil")
  node.status = status

  -- Update parent node's status as well
  if should_update_parent_status then
    local parent_node_id = node:get_parent_id()
    while parent_node_id ~= nil do
      local parent_node = self.progress_view_pane_tree:get_node(parent_node_id)
      parent_node.status = status
      ---@diagnostic disable-next-line:need-check-nil
      parent_node_id = parent_node:get_parent_id()
    end
  end

  -- If it is a successful node, we close it
  if status == "success" then
    node:collapse()
  else
    node:expand()
  end

  remote_nvim.dashboard:update_progress_view()
end

---@private
---Add new progress view section to an active run
---@param node remote-nvim.ui.ProgressView.ProgressInfoNode Section node to be inserted into progress view
---@param parent_node NuiTree.Node? Node under which the new node should be inserted
---@return NuiTree.Node section_node The created section node
function ProgressView:_add_progress_view_section_heading(node, parent_node)
  parent_node = parent_node or self.active_run_node
  assert(parent_node ~= nil, "Run section node should not be nil")

  -- If we were working with a previous active section, collapse it
  if self.active_section_node then
    self.active_section_node:collapse()
  end

  local section_node = NuiTree.Node({
    text = node.text,
    ---@type progress_view_node_type
    type = node.type,
  }, {})
  self.progress_view_pane_tree:add_node(section_node, parent_node:get_id())
  self.active_section_node = section_node
  self.active_section_node:expand()

  -- We initialize a dequeu for the section
  self.section_deque_map[section_node:get_id()] = Deque()

  return section_node
end

---@private
---Add new progress view run section
---@param node remote-nvim.ui.ProgressView.ProgressInfoNode Run node to insert into progress view
---@return NuiTree.Node created_node Created run node
function ProgressView:_add_progress_view_run_heading(node)
  self.active_run_node = NuiTree.Node({
    text = node.text,
    type = node.type,
    id = node.text .. remote_nvim.dashboard:get_next_run_counter()
  }, {})
  self.progress_view_pane_tree:add_node(self.active_run_node)
  self.active_run_node:expand()
  remote_nvim.dashboard:show()

  return self.active_run_node
end

---@private
---Add output node to the progress view tree
---@param node remote-nvim.ui.ProgressView.ProgressInfoNode Output to be inserted
---@param parent_node NuiTree.Node? Node to which the output node should be attached
---@return NuiTree.Node created_node Created output node
function ProgressView:_add_progress_view_output_node(node, parent_node)
  parent_node = parent_node or self.active_section_node
  assert(parent_node ~= nil, "Parent node should not be nil")

  ---@type remote-nvim.structs.Deque
  local deque = self.section_deque_map[parent_node:get_id()]

  -- Add node as child to the section node
  local created_node = NuiTree.Node({
    text = node.text,
    type = node.type,
  })
  self.progress_view_pane_tree:add_node(created_node, parent_node:get_id())

  if created_node.type == "stdout_node" then
    deque:pushright(created_node)
  end

  if deque:len() == self.max_output_lines - 1 then
    self.progress_view_pane_tree:add_node(
      NuiTree.Node({
        text = "More than 30 lines of output. Will only show last 30 lines...",
        type = "stdout_node",
      }),
      parent_node:get_id()
    )
    for _, elem_node in deque:ipairs_left() do
      local rnode = self.progress_view_pane_tree:remove_node(elem_node:get_id())
      self.progress_view_pane_tree:add_node(rnode, parent_node:get_id())
    end
  end

  if deque:len() > self.max_output_lines then
    ---@type NuiTree.Node
    local removed_node = deque:popleft()
    if removed_node ~= nil and self.progress_view_pane_tree:get_node(removed_node:get_id()) ~= nil then
      self.progress_view_pane_tree:remove_node(removed_node:get_id())
    end
  end

  return created_node
end

return ProgressView
