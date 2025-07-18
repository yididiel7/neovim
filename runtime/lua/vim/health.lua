--- @brief
---
--- vim.health is a minimal framework to help users troubleshoot configuration and any other
--- environment conditions that a plugin might care about. Nvim ships with healthchecks for
--- configuration, performance, python support, ruby support, clipboard support, and more.
---
--- To run all healthchecks, use:
--- ```vim
--- :checkhealth
--- ```
--- Plugin authors are encouraged to write new healthchecks. |health-dev|
---
---<pre>help
--- COMMANDS                                *health-commands*
---
---                                                              *:che* *:checkhealth*
--- :che[ckhealth]  Run all healthchecks.
---                                         *E5009*
---                 Nvim depends on |$VIMRUNTIME|, 'runtimepath' and 'packpath' to
---                 find the standard "runtime files" for syntax highlighting,
---                 filetype-specific behavior, and standard plugins (including
---                 :checkhealth).  If the runtime files cannot be found then
---                 those features will not work.
---
--- :che[ckhealth] {plugins}
---                 Run healthcheck(s) for one or more plugins. E.g. to run only
---                 the standard Nvim healthcheck: >vim
---                         :checkhealth vim.health
--- <
---                 To run the healthchecks for the "foo" and "bar" plugins
---                 (assuming they are on 'runtimepath' and they have implemented
---                 the Lua `require("foo.health").check()` interface): >vim
---                         :checkhealth foo bar
--- <
---                 To run healthchecks for Lua submodules, use dot notation or
---                 "*" to refer to all submodules. For example Nvim provides
---                 `vim.lsp` and `vim.treesitter`:  >vim
---                         :checkhealth vim.lsp vim.treesitter
---                         :checkhealth vim*
--- <
---
--- USAGE                                                        *health-usage*
---
--- Local mappings in the healthcheck buffer:
---
--- q               Closes the window.
---
--- Global configuration:
---                                                              *g:health*
--- g:health  Dictionary with the following optional keys:
---           - `style` (`'float'|nil`) Set to "float" to display :checkhealth in
---           a floating window instead of the default behavior.
---
---           Example: >lua
---             vim.g.health = { style = 'float' }
---
---</pre>
---
--- Local configuration:
---
--- Checkhealth sets its buffer filetype to "checkhealth". You can customize the buffer by handling
--- the |FileType| event. For example if you don't want emojis in the health report:
--- ```vim
--- autocmd FileType checkhealth :set modifiable | silent! %s/\v( ?[^\x00-\x7F])//g
--- ```
---
---<pre>help
--- --------------------------------------------------------------------------------
--- Create a healthcheck                                    *health-dev*
---</pre>
---
--- Healthchecks are functions that check the user environment, configuration, or any other
--- prerequisites that a plugin cares about. Nvim ships with healthchecks in:
--- - $VIMRUNTIME/autoload/health/
--- - $VIMRUNTIME/lua/vim/lsp/health.lua
--- - $VIMRUNTIME/lua/vim/treesitter/health.lua
--- - and more...
---
--- To add a new healthcheck for your own plugin, simply create a "health.lua" module on
--- 'runtimepath' that returns a table with a "check()" function. Then |:checkhealth| will
--- automatically find and invoke the function.
---
--- For example if your plugin is named "foo", define your healthcheck module at
--- one of these locations (on 'runtimepath'):
--- - lua/foo/health/init.lua
--- - lua/foo/health.lua
---
--- If your plugin also provides a submodule named "bar" for which you want a separate healthcheck,
--- define the healthcheck at one of these locations:
--- - lua/foo/bar/health/init.lua
--- - lua/foo/bar/health.lua
---
--- All such health modules must return a Lua table containing a `check()` function.
---
--- Copy this sample code into `lua/foo/health.lua`, replacing "foo" in the path with your plugin
--- name:
---
--- ```lua
--- local M = {}
---
--- M.check = function()
---   vim.health.start("foo report")
---   -- make sure setup function parameters are ok
---   if check_setup() then
---     vim.health.ok("Setup is correct")
---   else
---     vim.health.error("Setup is incorrect")
---   end
---   -- do some more checking
---   -- ...
--- end
---
--- return M
--- ```

local M = {}

local s_output = {} ---@type string[]
local check_summary = { warn = 0, error = 0 }

-- From a path return a list [{name}, {func}, {type}] representing a healthcheck
local function filepath_to_healthcheck(path)
  path = vim.fs.abspath(vim.fs.normalize(path))
  local name --- @type string
  local func --- @type string
  local filetype --- @type string
  if path:find('vim$') then
    name = vim.fs.basename(path):gsub('%.vim$', '')
    func = 'health#' .. name .. '#check'
    filetype = 'v'
  else
    local rtp_lua = vim
      .iter(vim.api.nvim_get_runtime_file('lua/', true))
      :map(function(rtp_lua)
        return vim.fs.abspath(vim.fs.normalize(rtp_lua))
      end)
      :find(function(rtp_lua)
        return vim.fs.relpath(rtp_lua, path)
      end)
    -- "/path/to/rtp/lua/foo/bar/health.lua" => "foo/bar/health.lua"
    -- "/another/rtp/lua/baz/health/init.lua" => "baz/health/init.lua"
    local subpath = path:gsub('^' .. vim.pesc(rtp_lua), ''):gsub('^/+', '')
    if vim.fs.basename(subpath) == 'health.lua' then
      -- */health.lua
      name = vim.fs.dirname(subpath)
    else
      -- */health/init.lua
      name = vim.fs.dirname(vim.fs.dirname(subpath))
    end
    name = assert(name:gsub('/', '.')) --- @type string

    func = 'require("' .. name .. '.health").check()'
    filetype = 'l'
  end
  return { name, func, filetype }
end

--- @param plugin_names string
--- @return table<any,string[]> { {name, func, type}, ... } representing healthchecks
local function get_healthcheck_list(plugin_names)
  local healthchecks = {} --- @type table<any,string[]>
  local plugin_names_list = vim.split(plugin_names, ' ')
  for _, p in pairs(plugin_names_list) do
    -- support vim/lsp/health{/init/}.lua as :checkhealth vim.lsp

    p = p:gsub('%.', '/')
    p = p:gsub('*', '**')

    local paths = vim.api.nvim_get_runtime_file('autoload/health/' .. p .. '.vim', true)
    vim.list_extend(
      paths,
      vim.api.nvim_get_runtime_file('lua/**/' .. p .. '/health/init.lua', true)
    )
    vim.list_extend(paths, vim.api.nvim_get_runtime_file('lua/**/' .. p .. '/health.lua', true))

    if vim.tbl_count(paths) == 0 then
      healthchecks[#healthchecks + 1] = { p, '', '' } -- healthcheck not found
    else
      local unique_paths = {} --- @type table<string, boolean>
      for _, v in pairs(paths) do
        unique_paths[v] = true
      end
      paths = {}
      for k, _ in pairs(unique_paths) do
        paths[#paths + 1] = k
      end

      for _, v in ipairs(paths) do
        healthchecks[#healthchecks + 1] = filepath_to_healthcheck(v)
      end
    end
  end
  return healthchecks
end

--- @param plugin_names string
--- @return table<string, string[]> {name: [func, type], ..} representing healthchecks
local function get_healthcheck(plugin_names)
  local health_list = get_healthcheck_list(plugin_names)
  local healthchecks = {} --- @type table<string, string[]>
  for _, c in pairs(health_list) do
    if c[1] ~= 'vim' then
      healthchecks[c[1]] = { c[2], c[3] }
    end
  end

  return healthchecks
end

--- Indents lines *except* line 1 of a multiline string.
---
--- @param s string
--- @param columns integer
--- @return string
local function indent_after_line1(s, columns)
  return (vim.text.indent(columns, s):gsub('^%s+', ''))
end

--- Changes ':h clipboard' to ':help |clipboard|'.
---
--- @param s string
--- @return string
local function help_to_link(s)
  return vim.fn.substitute(s, [[\v:h%[elp] ([^|][^"\r\n ]+)]], [[:help |\1|]], [[g]])
end

--- Format a message for a specific report item.
---
--- @param status string
--- @param msg string
--- @param ... string|string[] Optional advice
--- @return string
local function format_report_message(status, msg, ...)
  local output = '- ' .. status
  if status ~= '' then
    output = output .. ' '
  end

  output = output .. indent_after_line1(msg, 2)

  local varargs = ...

  -- Optional parameters
  if varargs then
    if type(varargs) == 'string' then
      varargs = { varargs }
    end

    output = output .. '\n  - ADVICE:'

    -- Report each suggestion
    for _, v in ipairs(varargs) do
      if v then
        output = output .. '\n    - ' .. indent_after_line1(v, 6) --- @type string
      end
    end
  end

  return help_to_link(output)
end

--- @param output string
local function collect_output(output)
  vim.list_extend(s_output, vim.split(output, '\n'))
end

--- Starts a new report. Most plugins should call this only once, but if
--- you want different sections to appear in your report, call this once
--- per section.
---
--- @param name string
function M.start(name)
  local input = string.format('\n%s ~', name)
  collect_output(input)
end

--- Reports an informational message.
---
--- @param msg string
function M.info(msg)
  local input = format_report_message('', msg)
  collect_output(input)
end

--- Reports a "success" message.
---
--- @param msg string
function M.ok(msg)
  local input = format_report_message('✅ OK', msg)
  collect_output(input)
end

--- Reports a warning.
---
--- @param msg string
--- @param ... string|string[] Optional advice
function M.warn(msg, ...)
  local input = format_report_message('⚠️ WARNING', msg, ...)
  collect_output(input)
  check_summary['warn'] = check_summary['warn'] + 1
end

--- Reports an error.
---
--- @param msg string
--- @param ... string|string[] Optional advice
function M.error(msg, ...)
  local input = format_report_message('❌ ERROR', msg, ...)
  collect_output(input)
  check_summary['error'] = check_summary['error'] + 1
end

local path2name = function(path)
  if path:match('%.lua$') then
    -- Lua: transform "../lua/vim/lsp/health.lua" into "vim.lsp"

    -- Get full path, make sure all slashes are '/'
    path = vim.fs.normalize(path)

    -- Remove everything up to the last /lua/ folder
    path = path:gsub('^.*/lua/', '')

    -- Remove the filename (health.lua) or (health/init.lua)
    path = vim.fs.dirname(path:gsub('/init%.lua$', ''))

    -- Change slashes to dots
    path = path:gsub('/', '.')

    return path
  else
    -- Vim: transform "../autoload/health/provider.vim" into "provider"
    return vim.fn.fnamemodify(path, ':t:r')
  end
end

local PATTERNS = { '/autoload/health/*.vim', '/lua/**/**/health.lua', '/lua/**/**/health/init.lua' }
--- :checkhealth completion function used by cmdexpand.c get_healthcheck_names()
M._complete = function()
  local unique = vim ---@type table<string,boolean>
    ---@param pattern string
    .iter(vim.tbl_map(function(pattern)
      return vim.tbl_map(path2name, vim.api.nvim_get_runtime_file(pattern, true))
    end, PATTERNS))
    :flatten()
    ---@param t table<string,boolean>
    :fold({}, function(t, name)
      t[name] = true -- Remove duplicates
      return t
    end)
  -- vim.health is this file, which is not a healthcheck
  unique['vim'] = nil
  local rv = vim.tbl_keys(unique)
  table.sort(rv)
  return rv
end

--- Gets the results heading for the current report section.
---
---@return string
local function get_summary()
  local s = ''
  local errors = check_summary['error']
  local warns = check_summary['warn']

  s = s .. (warns > 0 and (' %2d ⚠️'):format(warns) or '')
  s = s .. (errors > 0 and (' %2d ❌'):format(errors) or '')
  if errors == 0 and warns == 0 then
    s = s .. '✅'
  end

  return s
end

--- Runs the specified healthchecks.
--- Runs all discovered healthchecks if plugin_names is empty.
---
--- @param mods string command modifiers that affect splitting a window.
--- @param plugin_names string glob of plugin names, split on whitespace. For example, using
---                            `:checkhealth vim.* nvim` will healthcheck `vim.lsp`, `vim.treesitter`
---                            and `nvim` modules.
function M._check(mods, plugin_names)
  local healthchecks = plugin_names == '' and get_healthcheck('*') or get_healthcheck(plugin_names)

  local emptybuf = vim.fn.bufnr('$') == 1 and vim.fn.getline(1) == '' and 1 == vim.fn.line('$')

  local bufnr ---@type integer
  if
    vim.g.health
    and type(vim.g.health) == 'table'
    and vim.tbl_get(vim.g.health, 'style') == 'float'
  then
    local available_lines = vim.o.lines - 12
    local max_height = math.min(math.floor(vim.o.lines * 0.8), available_lines)
    local max_width = 80
    local float_winid
    bufnr, float_winid = vim.lsp.util.open_floating_preview({}, '', {
      height = max_height,
      width = max_width,
      offset_x = math.floor((vim.o.columns - max_width) / 2),
      offset_y = math.floor((available_lines - max_height) / 2),
      relative = 'editor',
      close_events = {},
    })
    vim.api.nvim_set_current_win(float_winid)
    vim.bo[bufnr].modifiable = true
    vim.wo[float_winid].list = false
  else
    bufnr = vim.api.nvim_create_buf(true, true)
    -- When no command modifiers are used:
    -- - If the current buffer is empty, open healthcheck directly.
    -- - If not specified otherwise open healthcheck in a tab.
    local buf_cmd = #mods > 0 and (mods .. ' sbuffer') or emptybuf and 'buffer' or 'tab sbuffer'
    vim.cmd(buf_cmd .. ' ' .. bufnr)
  end

  if vim.fn.bufexists('health://') == 1 then
    vim.cmd.bwipe('health://')
  end
  vim.cmd.file('health://')

  -- This should only happen when doing `:checkhealth vim`
  if next(healthchecks) == nil then
    vim.fn.setline(1, 'ERROR: No healthchecks found.')
    return
  end
  vim.cmd.redraw()
  vim.print('Running healthchecks...')

  for name, value in vim.spairs(healthchecks) do
    local func = value[1]
    local type = value[2]
    s_output = {}
    check_summary = { warn = 0, error = 0 }

    if func == '' then
      M.error('No healthcheck found for "' .. name .. '" plugin.')
    end
    if type == 'v' then
      vim.fn.call(func, {})
    else
      local f = assert(loadstring(func))
      local ok, output = pcall(f) ---@type boolean, string
      if not ok then
        M.error(
          string.format('Failed to run healthcheck for "%s" plugin. Exception:\n%s\n', name, output)
        )
      end
    end
    -- in the event the healthcheck doesn't return anything
    -- (the plugin author should avoid this possibility)
    if next(s_output) == nil then
      s_output = {}
      M.error('The healthcheck report for "' .. name .. '" plugin is empty.')
    end

    local report = get_summary()
    local replen = vim.fn.strwidth(report)
    local header = {
      string.rep('=', 78),
      -- Example: `foo.health: [ …] 1 ⚠️  5 ❌`
      ('%s: %s%s'):format(name, (' '):rep(76 - name:len() - replen), report),
      '',
    }

    -- remove empty line after header from report_start
    if s_output[1] == '' then
      local tmp = {} ---@type string[]
      for i = 2, #s_output do
        tmp[#tmp + 1] = s_output[i]
      end
      s_output = {}
      for _, v in ipairs(tmp) do
        s_output[#s_output + 1] = v
      end
    end
    s_output[#s_output + 1] = ''
    s_output = vim.list_extend(header, s_output)
    vim.fn.append(vim.fn.line('$'), s_output)
    vim.cmd.redraw()
  end

  -- Clear the 'Running healthchecks...' message.
  vim.cmd.redraw()
  vim.print('')

  -- Quit with 'q' inside healthcheck buffers.
  vim._with({ buf = bufnr }, function()
    if vim.fn.maparg('q', 'n', false, false) == '' then
      vim.keymap.set('n', 'q', function()
        if not pcall(vim.cmd.close) then
          vim.cmd.bdelete()
        end
      end, { buffer = bufnr, silent = true, noremap = true, nowait = true })
    end
  end)

  -- Once we're done writing checks, set nomodifiable.
  vim.bo[bufnr].modifiable = false
  vim.cmd.setfiletype('checkhealth')
end

return M
