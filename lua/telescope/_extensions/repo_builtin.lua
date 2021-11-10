local actions = require'telescope.actions'
local actions_set = require'telescope.actions.set'
local actions_state = require'telescope.actions.state'
local conf = require'telescope.config'.values
local entry_display = require'telescope.pickers.entry_display'
local finders = require'telescope.finders'
local from_entry = require'telescope.from_entry'
local log = require "telescope.log"
local pickers = require'telescope.pickers'
local previewers = require'telescope.previewers'
local utils = require'telescope.utils'
local Path = require'plenary.path'

local os_home = vim.loop.os_homedir()

local M = {}

local function search_readme(dir)
  for _, name in pairs{
    'README', 'README.md', 'README.markdown', 'README.mkd',
  } do
    local file = dir / name
    if file:is_file() then return file end
  end
  return nil
end

local function search_doc(dir)
  local doc_path = Path:new(dir, 'doc', '**', '*.txt')
  local maybe_doc = vim.split(vim.fn.glob(doc_path.filename), '\n')
  for _, filepath in pairs(maybe_doc) do
    local file = Path:new(filepath)
    if file:is_file() then return file end
  end
  return nil
end

-- Was gen_from_ghq in telescope-ghq.nvim
local function gen_from_fd(opts)
  local displayer = entry_display.create{
    items = {{}},
  }

  local function make_display(entry)
    local dir = (function(path)
      if path == Path.path.root() then return path end

      local p = Path:new(path)
      if opts.tail_path then
        local parts = p:_split()
        return parts[#parts]
      end

      if opts.shorten_path then return p:shorten() end

      if vim.startswith(path, opts.cwd) and path ~= opts.cwd then
        return Path:new(p):make_relative(opts.cwd)
      end

      if vim.startswith(path, os_home) then
        return (Path:new'~' / p:make_relative(os_home)).filename
      end
      return path
    end)(entry.path)

    return displayer{dir}
  end

  return function(line)
    return {
      value = line,
      ordinal = line,
      path = line,
      display = make_display,
    }
  end
end

-- Wrap entries to remove the part we used to detect the VCS. For instance, for git:
-- - we get entries like “/home/me/repo/.git”
-- - we want to send entries like “/home/me/repo”
local function gen_from_locate_wrapper(opts)
  log.info "Called gen_from_locate_wrapper"
  -- TODO Make this a wrapper over any function, not just gen_from_fd
  -- TODO It’s not great for performance to parse paths in the whole list like this
  return function(line_with_dotgit)
    log.info("line_with_dotgit " .. line_with_dotgit)
    local line = Path:new(line_with_dotgit):parent().filename
    return gen_from_fd(opts)(line)
  end
end

local function project_files(opts)
  local ok = pcall(require'telescope.builtin'.git_files, opts)
  if not ok then require'telescope.builtin'.find_files(opts) end
end

local function call_picker(opts, command, prompt_title_supplement)
  local prompt_title = 'Git repositories'
  if prompt_title_supplement ~= nil then
    prompt_title = prompt_title .. prompt_title_supplement
  end
  pickers.new(opts, {
    prompt_title = prompt_title,
    finder = finders.new_oneshot_job(
      command,
      opts
    ),
    previewer = previewers.new_termopen_previewer{
      get_command = function(entry)
        local dir = Path:new(from_entry.path(entry))
        local doc = search_readme(dir)
        local is_mardown
        if doc then
          is_mardown = true
        else
          -- TODO: doc may be previewed in a plain text. Can I use syntax highlight?
          doc = search_doc(dir)
        end
        if doc then
          if is_mardown and vim.fn.executable'glow' == 1 then
            return {'glow', doc.filename}
          elseif vim.fn.executable'bat' == 1 then
            return {'bat', '--style', 'header,grid', doc.filename}
          end
          return {'cat', doc.filename}
        end
        return {'echo', ''}
      end,
    },
    sorter = conf.file_sorter(opts),
    attach_mappings = function(prompt_bufnr)
      actions_set.select:replace(function(_, type)
        local entry = actions_state.get_selected_entry()
        local dir = from_entry.path(entry)
        if type == 'default' then
          actions._close(prompt_bufnr, true)
          project_files{cwd = dir}
        end
      end)
      return true
    end,
  }):find()
end

-- List of repos built using locate (or variants)
M.cached_list = function(opts)
  opts = opts or {}
  opts.entry_maker = utils.get_lazy_default(opts.entry_maker, gen_from_locate_wrapper, opts)
  opts.cwd = vim.env.HOME
  opts.bin = opts.bin and vim.fn.expand(opts.bin) or nil
  -- Use alternative locate if possible
  if opts.bin == nil then
    if vim.fn.executable'plocate' == 1 then
      opts.bin = 'plocate'
    elseif vim.fn.executable'locate' == 1 then -- Fallback
      opts.bin = 'locate'
    else
      error "Please install locate (or one of its alternatives)"
    end
  end
  local bin = vim.fn.expand(opts.bin)

  local repo_pattern = opts.pattern or [[/\.git$]] -- We match on the whole path
  local locate_command = {bin, '-r', repo_pattern}
  log.info("locate_command: "..vim.inspect(locate_command))

  call_picker(opts, locate_command, ' (cached)')
end

-- Always up to date list of repos built using fd
M.list = function(opts)
  opts = opts or {}
  opts.entry_maker = utils.get_lazy_default(opts.entry_maker, gen_from_fd, opts)
  opts.bin = opts.bin and vim.fn.expand(opts.bin) or 'fd'
  opts.cwd = vim.env.HOME

  local bin = vim.fn.expand(opts.bin)
  local fd_command = {bin}
  local repo_pattern = opts.pattern or [[^\.git$]]

  -- Don’t filter only on directories with fd as git worktrees actually have a
  -- .git file in them.
  local find_repo_opts = {'--hidden', '--case-sensitive', '--absolute-path'}
  local find_user_opts = opts.fd_opts or {}
  local find_exec_opts = {'--exec', 'echo', [[{//}]], ';'}
  local find_pattern_opts = {repo_pattern}

  table.insert(fd_command, find_repo_opts)
  table.insert(fd_command, find_user_opts)
  table.insert(fd_command, find_exec_opts)
  table.insert(fd_command, find_pattern_opts)
  fd_command = vim.tbl_flatten(fd_command)

  call_picker(opts, fd_command, ' (built on the fly)')
end

return M
