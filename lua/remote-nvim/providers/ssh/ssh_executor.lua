local Executor = require("remote-nvim.providers.executor")
local Path = require("plenary.path")
local ScanDir = require("plenary.scandir")
local const = require("remote-nvim.constants")
local utils = require("remote-nvim.utils")

---@class remote-nvim.providers.ssh.SSHExecutor: remote-nvim.providers.Executor
---@field super remote-nvim.providers.Executor
---@field ssh_conn_opts string Connection options for SSH command
---@field scp_connection_options string Connection options to SCP command
---@field ssh_binary string Binary to use for SSH operations
---@field scp_binary string Binary to use for SCP operations
---@field private _ssh_prompts remote-nvim.config.PluginConfig.SSHConfig.SSHPrompt[] SSH prompts registered for processing for input
---@field private _job_stdout_processed_idx number Last index processed by output processor
---@field private _job_prompt_responses table<string,string> Responses for prompts provided by user during the job
local SSHExecutor = Executor:subclass("SSHExecutor")

---Initialize SSH executor instance
---@param host string Host name
---@param conn_opts string Connection options
function SSHExecutor:init(host, conn_opts)
  SSHExecutor.super.init(self, host, conn_opts)

  self.ssh_conn_opts = self.conn_opts
  self.scp_conn_opts = self.conn_opts == "" and "-r" or self.conn_opts:gsub("%-p", "-P") .. " -r"

  local remote_neovim = require("remote-nvim")
  self.ssh_binary = remote_neovim.config.ssh_config.ssh_binary
  self.scp_binary = remote_neovim.config.ssh_config.scp_binary
  self._ssh_prompts = vim.deepcopy(remote_neovim.config.ssh_config.ssh_prompts)

  self._job_stdout_processed_idx = 0
  self._job_prompt_responses = {}
end

---Reset ssh executor
function SSHExecutor:reset()
  SSHExecutor.super.reset(self)

  self._job_stdout_processed_idx = 0
  self._job_prompt_responses = {}
end

---Upload data from local path to remote path
---@param localSrcPath string Local path
---@param remoteDestPath string Remote path
---@param job_opts remote-nvim.provider.Executor.JobOpts
function SSHExecutor:upload(localSrcPath, remoteDestPath, job_opts)
  job_opts = job_opts or {}
  job_opts.compression = job_opts.compression or {}

  if job_opts.compression.enabled or false then
    local paths = vim.split(localSrcPath, " ")
    local parent_dir, subdirs = utils.find_common_parent(paths)
    assert(
      parent_dir ~= "",
      ("All directories to be uploaded from local should share a common ancestor. Passed paths: %s"):format(
        table.concat(paths, " ")
      )
    )

    local ssh_command = self:_build_run_command(
      ("tar xvzf - -C %s && chown -R $(whoami) %s"):format(remoteDestPath, remoteDestPath),
      job_opts
    )
    local tar_command = ("tar czf - --no-xattrs %s %s --numeric-owner --no-acls --no-same-owner --no-same-permissions -C %s %s")
        :format(
          utils.os_name() == "macOS" and "--disable-copyfile" or "",
          table.concat(job_opts.compression.additional_opts or {}, " "),
          parent_dir,
          table.concat(subdirs, " ")
        )
    local command = ("%s | %s"):format(tar_command, ssh_command)
    return self:run_executor_job(command, job_opts)
  else
    local remotePath = ("%s:%s"):format(self.host, remoteDestPath)
    local scp_command = ("%s %s %s %s"):format(self.scp_binary, self.scp_conn_opts, localSrcPath, remotePath)

    return self:run_executor_job(scp_command, job_opts)
  end
end

---Download data from remote path to local path
---@param remoteSrcPath string Remote path
---@param localDescPath string Local path
---@param job_opts remote-nvim.provider.Executor.JobOpts
function SSHExecutor:download(remoteSrcPath, localDescPath, job_opts)
  job_opts = job_opts or {}
  local remotePath = ("%s:%s"):format(self.host, remoteSrcPath)
  local scp_command = ("%s %s %s %s"):format(self.scp_binary, self.scp_conn_opts, remotePath, localDescPath)

  return self:run_executor_job(scp_command, job_opts)
end

---@private
---Build the SSH command to be run on the remote host
---@param command string Command to be run on the remote host
---@param job_opts remote-nvim.provider.Executor.JobOpts
---@return string generated_command The SSH command that should be run on local to run the passed command on remote
function SSHExecutor:_build_run_command(command, job_opts)
  job_opts = job_opts or {}

  -- Append additional connection options (if any)
  local conn_opts = job_opts.additional_conn_opts == nil and self.ssh_conn_opts
      or (self.ssh_conn_opts .. " " .. job_opts.additional_conn_opts)

  -- Generate connection details (conn_opts + host)
  local host_conn_opts = conn_opts == "" and self.host or conn_opts .. " " .. self.host

  -- Shell escape the passed command
  return ("%s %s %s"):format(self.ssh_binary, host_conn_opts, vim.fn.shellescape(command))
end

---Run command on the remote host
---@param command string Command to be run on the remote host
---@param job_opts remote-nvim.provider.Executor.JobOpts
function SSHExecutor:run_command(command, job_opts)
  job_opts = job_opts or {}
  return self:run_executor_job(self:_build_run_command(command, job_opts), job_opts)
end

---@private
---Handle when the SSH job requires a job input
---@param prompt remote-nvim.config.PluginConfig.SSHConfig.SSHPrompt
function SSHExecutor:_process_prompt(prompt)
  self._job_stdout_processed_idx = #self._job_stdout
  local prompt_response

  -- If it is a "static" value prompt, use cached input values, unless values were passed in config
  -- If prompt's value would not change during the session ("static"), use cached values unless they are unset (denoted
  -- by "" string)
  if prompt.value_type == "static" and prompt.value ~= "" then
    prompt_response = prompt.value
  else
    local job_output = self:job_stdout()
    local label = prompt.input_prompt or ("%s "):format(job_output[#job_output])
    prompt_response = require("remote-nvim.providers.utils").get_input(label, prompt.type)

    -- Saving these prompt responses is handle in the job exit handler
    if prompt.value_type == "static" then
      self._job_prompt_responses[prompt.match] = prompt_response
    end
  end
  vim.api.nvim_chan_send(self._job_id, prompt_response .. "\n")
end

---@private
---Process job output
---@param output_chunks string[]
---@param cb function? Callback to call on job output
function SSHExecutor:process_stdout(output_chunks, cb)
  SSHExecutor.super.process_stdout(self, output_chunks, cb)

  local pending_search_str = table.concat(vim.list_slice(self._job_stdout, self._job_stdout_processed_idx + 1), "")
  for _, prompt in ipairs(self._ssh_prompts) do
    if pending_search_str:find(prompt.match, 1, true) then
      self:_process_prompt(prompt)
    end
  end
end

---@private
---Process job completion
---@param exit_code number Exit code of the job that was just running on the executor
function SSHExecutor:process_job_completion(exit_code)
  SSHExecutor.super.process_job_completion(self, exit_code)

  if self._job_exit_code == 0 then
    -- If the job has successfully concluded, we have the correct prompt values at hand for "static" prompts
    for idx, prompt in ipairs(self._ssh_prompts) do
      if prompt.value_type == "static" and self._job_prompt_responses[prompt.match] ~= nil then
        self._ssh_prompts[idx].value = self._job_prompt_responses[prompt.match]
      end
    end
  end
end

local function get_or_create_sock_path()
  local sock_path = Path:new((vim.uv or vim.loop).os_tmpdir(), const.PLUGIN_NAME)
  if not sock_path:exists() then
    sock_path:mkdir({ parents = true, exists_ok = true })
  end
  return sock_path:absolute()
end

---@return table<string, remote-nvim.provider.Executor.SessionInfo> saved_sessions Sessions infos saved
local function read_sessions()
  local session_path = Path:new({ vim.fn.stdpath("data"), const.PLUGIN_NAME, "sessions.json" })
  session_path:touch({ mode = 493, parents = true }) -- Ensure that the path exists
  local session_data = session_path:read()
  if session_data == "" then
    return {}
  else
    return vim.json.decode(session_data)
  end
end

---@param sessions table<string, remote-nvim.provider.Executor.SessionInfo> Sessions infos to save
local function save_sessions(sessions)
  local session_path = Path:new({ vim.fn.stdpath("data"), const.PLUGIN_NAME, "sessions.json" })
  session_path:touch({ mode = 493, parents = true }) -- Ensure that the path exists
  session_path:write(vim.json.encode(sessions), "w")
end
---@return table<string, remote-nvim.provider.Executor.SessionInfo> sessions Currently active sessions
function SSHExecutor.update_sessions()
  local path = get_or_create_sock_path()
  local files = ScanDir.scan_dir(path)
  local session_ids = {}
  for _, v in ipairs(files) do
    local id = v:match("session_([%w_]+)%.sock")
    if id then
      table.insert(session_ids, id)
    else
      vim.notify(("Found session socket with unexpected name '%s'. Skipping..."):format(v), vim.log.levels.WARNING)
    end
  end
  local old_session_data = read_sessions()
  local new_session_data = {}
  for _, id in ipairs(session_ids) do
    if old_session_data[id] then
      new_session_data[id] = old_session_data[id]
    else
      vim.notify(("Found session socket with session_id '%s' with missing info. Closing..."):format(id),
        vim.log.levels.ERROR)
      SSHExecutor.close_sessions(id)
    end
  end
  save_sessions(new_session_data)
  return new_session_data
end

---@param opts string|string[] options to split into an array
---@return string[] split_options
local split_opts = function(opts)
  local input_opts = type(opts) == "string" and { opts } or opts
  local new_opts = {}
  for _, str in ipairs(input_opts) do
    for opt in str:gmatch("%S+") do
      table.insert(new_opts, opt)
    end
  end
  return new_opts
end

---@param ids string|string[] Session ids to close
function SSHExecutor.close_sessions(ids)
  if type(ids) == "string" then
    ids = { ids }
  end
  ids = ids or {}
  local session_data = read_sessions()
  for _, id in ipairs(ids) do
    local socket_path = Path:new(get_or_create_sock_path(), "session_" .. id .. ".sock"):absolute()
    utils.get_logger().debug(("killing %s"):format(socket_path))

    vim.system({ "ssh", "-S", socket_path, "-O", "exit", "dummyhost" })
    session_data[id] = nil
  end
  save_sessions(session_data)
end

---@param session_info remote-nvim.provider.Executor.SessionInfo
---@param cmd string ssh launch arguments
---@param extra_opts string|string[] extra options passed to the underlying command
function SSHExecutor:new_session(session_info, cmd, extra_opts)
  local logger = utils.get_logger()
  local extra_opts_tbl = split_opts(extra_opts)

  local sessions = self.update_sessions()
  if session_info.session_id and sessions[session_info.session_id] then
    error(("Session with id %s is already exists"):format(session_info.session_id), vim.log.levels.ERROR)
  end
  session_info.session_id = session_info.session_id or utils.generate_random_string(10)

  local socket_path = Path:new(get_or_create_sock_path(), "session_" .. session_info.session_id .. ".sock"):absolute()
  local ssh_args = { "-M", "-S", socket_path }
  vim.list_extend(ssh_args, extra_opts_tbl)
  vim.list_extend(ssh_args, { self.ssh_conn_opts, self.host, cmd })

  local uv = vim.uv or vim.loop

  local handle, pid = uv.spawn(self.ssh_binary, { args = ssh_args, detached = true, })
  if not pid then
    error("Could not spawn new session")
  end
  uv.unref(handle)

  sessions[session_info.session_id] = session_info
  save_sessions(sessions)
  logger.debug(("Spawned: %s %s"):format(self.ssh_binary, table.concat(ssh_args, " ")))
end

return SSHExecutor
