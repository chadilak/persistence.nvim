local Config = require("persistence.config")

local uv = vim.uv or vim.loop

local M = {}
M._active = false

local e = vim.fn.fnameescape

---@param file_path string
---@return boolean
local file_exists = function(file_path)
  return uv.fs_stat(file_path) and true or false
end

local function session_files(path)
  local files = {}
  local f = io.open(path, "r")
  if not f then
    return files
  end
  for line in f:lines() do
    local file = line:match("^badd%s+%+%d+%s+(.+)$")
    if file then
      table.insert(files, file)
    end
  end
  f:close()
  return files
end

local function build_preview(item)
  local lines = {
    'dir: "' .. item.dir .. '"',
    "",
    'session: "' .. item.session .. '"',
    "",
    "files:",
  }
  for _, f in ipairs(session_files(item.session)) do
    table.insert(lines, '"' .. f .. '"')
  end
  return table.concat(lines, "\n")
end

---@param opts? {branch?: boolean}
function M.current(opts)
  opts = opts or {}
  local name = vim.fn.getcwd():gsub("[\\/:]+", "%%")
  if Config.options.branch and opts.branch ~= false then
    local branch = M.branch()
    if branch and branch ~= "main" and branch ~= "master" then
      name = name .. "%%" .. branch:gsub("[\\/:]+", "%%")
    end
  end
  return Config.options.dir .. name .. ".vim"
end

function M.setup(opts)
  Config.setup(opts)
  M.start()
end

function M.fire(event)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "Persistence" .. event,
  })
end

-- Check if a session is active
function M.active()
  return M._active
end

function M.start()
  M._active = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("persistence", { clear = true }),
    callback = function()
      M.fire("SavePre")

      if Config.options.need > 0 then
        local bufs = vim.tbl_filter(function(b)
          if vim.bo[b].buftype ~= "" or vim.tbl_contains({ "gitcommit", "gitrebase", "jj" }, vim.bo[b].filetype) then
            return false
          end
          return vim.api.nvim_buf_get_name(b) ~= ""
        end, vim.api.nvim_list_bufs())
        if #bufs < Config.options.need then
          return
        end
      end

      M.save()
      M.fire("SavePost")
    end,
  })
end

function M.stop()
  M._active = false
  pcall(vim.api.nvim_del_augroup_by_name, "persistence")
end

function M.save()
  vim.cmd("mks! " .. e(M.current()))
end

---@param opts? { last?: boolean, replace?: boolean }
function M.load(opts)
  opts = opts or {}
  ---@type string
  local file
  if opts.last then
    file = M.last()
  else
    file = M.current()
    if vim.fn.filereadable(file) == 0 then
      file = M.current({ branch = false })
    end
  end
  if file and vim.fn.filereadable(file) ~= 0 then
    M.fire("LoadPre")
    if opts.replace then
      vim.cmd("silent! %bd")
    end
    vim.cmd("silent! source " .. e(file))
    M.fire("LoadPost")
  end
end

---@return string[]
function M.list()
  local sessions = vim.fn.glob(Config.options.dir .. "*.vim", true, true)
  table.sort(sessions, function(a, b)
    return uv.fs_stat(a).mtime.sec > uv.fs_stat(b).mtime.sec
  end)
  return sessions
end

function M.last()
  return M.list()[1]
end

---@param opts { prompt: string, handler: function}
function M.handle_selected(opts)
  local items = {}
  local have = {}
  for _, session in ipairs(M.list()) do
    if uv.fs_stat(session) then
      local file = session:sub(#Config.options.dir + 1, -5)
      local dir, branch = unpack(vim.split(file, "%%", { plain = true }))
      dir = dir:gsub("%%", "/")
      if jit.os:find("Windows") then
        dir = dir:gsub("^(%w)/", "%1:/")
      end
      if (not have[dir]) and file_exists(dir) then
        have[dir] = true
        items[#items + 1] = { session = session, dir = dir, branch = branch }
      end
    end
  end

  local ok_snacks, Snacks = pcall(require, "snacks")
  if ok_snacks and Snacks.picker then
    local picker_items = {}
    for idx, item in ipairs(items) do
      item.idx = idx
      picker_items[idx] = {
        text = vim.fn.fnamemodify(item.dir, ":p:~"),
        item = item,
        preview = { text = build_preview(item) },
      }
    end
    Snacks.picker.pick({
      source = "persistence_sessions",
      items = picker_items,
      title = "Sessions",
      preview = "preview",
      format = function(entry, _)
        return {
          { string.format("%2d ", entry.item.idx), "SnacksPickerBufNr" },
          { entry.text, "SnacksPickerDir" },
        }
      end,
      layout = {
        layout = {
          box = "horizontal",
          width = 0.8,
          min_width = 120,
          height = 0.8,
          {
            box = "vertical",
            border = true,
            title = "Sessions",
            { win = "input", height = 1, border = "bottom" },
            { win = "list", border = "none" },
          },
          { win = "preview", title = "Info", border = true, width = 0.5 },
        },
      },
      confirm = function(picker, picked)
        picker:close()
        if picked then
          opts.handler(picked.item)
        end
      end,
    })
    return
  end

  vim.ui.select(items, {
    prompt = opts.prompt,
    format_item = function(item)
      return vim.fn.fnamemodify(item.dir, ":p:~")
    end,
  }, function(item)
    if item then
      opts.handler(item)
    end
  end)
end

-- select a session to load
---@param opts? { replace?: boolean }
function M.select(opts)
  opts = opts or {}
  M.handle_selected({
    prompt = "Select a session: ",
    handler = function(item)
      vim.fn.chdir(item.dir)
      M.load({ replace = opts.replace })
    end,
  })
end

-- select a session to delete
function M.delete()
  M.handle_selected({
    prompt = "Delete a session: ",
    handler = function(item)
      os.remove(item.session)
      print("Deleted " .. item.session)
    end,
  })
end

--- get current branch name
---@return string?
function M.branch()
  if uv.fs_stat(".git") then
    local ret = vim.fn.systemlist("git branch --show-current")[1]
    return vim.v.shell_error == 0 and ret or nil
  end
end

return M
