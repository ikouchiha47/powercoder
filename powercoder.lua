-- power-coder.lua
--
local M = {}
local uv = vim.loop
local async = require 'plenary.async'

-- Function to get the entire buffer content
local function get_buffer_content()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
end

-- Function to get the selected text
local function get_selected_text()
  local start_pos = vim.fn.getpos "'<"
  local end_pos = vim.fn.getpos "'>"
  local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
  if #lines == 1 then
    lines[1] = string.sub(lines[1], start_pos[3], end_pos[3])
  else
    lines[1] = string.sub(lines[1], start_pos[3])
    lines[#lines] = string.sub(lines[#lines], 1, end_pos[3])
  end

  return table.concat(lines, '\n')
end

-- Function to create a new buffer and display the result
-- toggle_streaming and dump with append_to_result_buffer
local function display_result(result)
  vim.schedule(function()
    vim.cmd 'new'
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result, '\n'))
    vim.bo[buf].filetype = vim.bo.filetype -- Set the filetype to match the original buffer
    vim.bo[buf].buftype = 'nofile'
  end)
end

local function create_result_buffer(language)
  vim.cmd 'new'
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = language -- vim.bo.filetype -- Set the filetype to match the original buffer
  vim.bo[buf].buftype = 'nofile'
  return buf
end

local line_buffer = ''

-- Function to append text to the result buffer
local function append_to_result_buffer(buf, text)
  vim.schedule(function()
    local full_text = line_buffer .. text
    local lines = vim.split(full_text, '\n')

    line_buffer = lines[#lines]
    table.remove(lines)

    if #lines > 0 then
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        vim.api.nvim_buf_set_option(buf, 'modifiable', true)
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
        vim.api.nvim_buf_set_option(buf, 'modifiable', false)

        -- Move cursor to end only if the buffer is actually shown in the current window
        if vim.api.nvim_get_current_buf() == buf then
          local last_line = vim.api.nvim_buf_line_count(buf)
          if last_line < 1 then
            last_line = 1
          end
          pcall(vim.api.nvim_win_set_cursor, 0, { last_line, 0 })
        end
      end
    end

    -- if #lines > 0 then
    --   vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    --   -- Append complete lines to the buffer
    --   vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    --   vim.api.nvim_buf_set_option(buf, 'modifiable', false)
    --   -- Move cursor to the end of the buffer
    --   local last_line = vim.api.nvim_buf_line_count(buf)
    --   vim.api.nvim_win_set_cursor(0, { last_line, 0 })
    -- end
  end)
end

M.prompt = {
  test_prompt = function(language)
    return string.format(
      'Write tests for the %s code. '
        .. 'There should be at least one test case of success and failure. '
        .. 'Break down the test cases into smaller blocks. Use table tests if required. '
        .. 'Add more test cases as required for each branching, for full code coverage. '
        .. 'Only output the test code and nothing else. '
        .. 'Write no more than 20 test cases at max. If there can be more, stop and say there can be more.',
      language
    )
  end,
  refactor_prompt = function(language)
    return string.format(
      'Refactor the %s code. '
        .. 'Refactor should include but not limited to: improving time complexity, better design principle. code locality, single responsibilty. '
        .. 'If a refactor is not needed, do not unnecesarily refactor the code',
      language
    )
  end,
  generate_docs_prompt = function(language)
    -- TODO: add a language to linter mapping. like js; jsdoc, python: pep8
    return string.format(
      'Above is the %s code. Add proper documentation for the function or variable below. Do not rewrite the code, Only generate the appropriate docs',
      language
    )
  end,
}

local function kill_process(handle, pid)
  if handle then
    uv.process_kill(handle, 'sigkill')
    handle:close()
  end
  if pid then
    uv.kill(pid, 'sigkill')
  end
end

local function get_function_definition()
  local bufnr = vim.api.nvim_get_current_buf()

  -- Get cursor position (0-based)
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local row = cursor_pos[1] + 1
  local col = cursor_pos[2]

  -- Get parser for current buffer
  local parser = vim.treesitter.get_parser(bufnr)
  if not parser then
    print 'No parser available for current buffer'
    return nil
  end

  -- Get syntax tree
  local tree = parser:parse()[1]
  local root = tree:root()

  -- Query for function definitions
  local query_string = [[
        (function_declaration) @function
    ]]

  local query = vim.treesitter.query.parse(parser:lang(), query_string)
  if not query then
    print 'Could not create query'
    return nil
  end

  -- print('row, col', row, col)
  -- Find the function node at cursor position
  local function_node = nil
  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    local start_row, start_col, end_row, end_col = node:range()
    -- print('sr', start_row, start_col, end_row, end_col)
    if row >= start_row and row <= end_row then
      if (row > start_row or col >= start_col) and (row < end_row or col <= end_col) then
        function_node = node
        break
      end
    end
  end

  -- Get function text if found
  if function_node then
    local start_row, start_col, end_row, end_col = function_node:range()
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)

    -- Adjust first and last line to respect column bounds
    if #lines > 0 then
      lines[1] = string.sub(lines[1], start_col + 1)
      if #lines > 1 then
        lines[#lines] = string.sub(lines[#lines], 1, end_col)
      end
    end

    return table.concat(lines, '\n')
  end

  return nil
end

-- Function to run ollama command asynchronously
local function run_ollama_async(content, filetype, run_type)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local handle, pid
  -- local result = ''
  local error_msg = ''

  local result_buf = create_result_buffer(filetype)
  local timeout_timer = uv.new_timer()

  local function cleanup()
    stdout:read_stop()
    stderr:read_stop()
    stdout:close()
    stderr:close()
    if timeout_timer then
      timeout_timer:stop()
      timeout_timer:close()
    end
    M.current_handle = nil
    M.current_pid = nil
  end

  local function on_exit(code, signal)
    cleanup()
    if code ~= 0 then
      vim.schedule(function()
        vim.api.nvim_echo({ { 'Generation failed: ' .. error_msg, 'ErrorMsg' } }, false, {})
      end)
    else
      vim.schedule(function()
        vim.api.nvim_echo({ { 'Generation complete', 'Normal' } }, false, {})
      end)
    end
  end

  local function on_stdout(err, chunk)
    assert(not err, err)
    if chunk and M.current_handle then
      append_to_result_buffer(result_buf, chunk)
    end
  end

  local function on_stderr(err, chunk)
    assert(not err, err)
    if chunk and M.current_handle then
      error_msg = error_msg .. chunk
    end
  end

  local prompt = 'Do nothing and exit'
  if run_type == 'test' then
    prompt = M.prompt.test_prompt(filetype)
  elseif run_type == 'refactor' then
    prompt = M.prompt.refactor_prompt(filetype)
  elseif run_type == 'docs' then
    prompt = M.prompt.generate_docs_prompt(filetype)
  end

  local cmd = string.format("echo '%s' | ollama run llama3-coder '%s'", content:gsub("'", "'\\''"), prompt)

  if run_type == 'docs' then
    cmd = string.format("echo '%s' | ollama run docs-builder '%s'", content, prompt)
  end

  -- print(content)
  -- print(prompt)

  handle, pid = uv.spawn('sh', {
    args = { '-c', cmd },
    stdio = { nil, stdout, stderr },
  }, on_exit)

  uv.read_start(stdout, on_stdout)
  uv.read_start(stderr, on_stderr)

  M.current_handle = handle
  M.current_pid = pid

  -- Set up a timeout
  timeout_timer:start(150000, 0, function() -- 5 minutes timeout
    vim.schedule(function()
      vim.api.nvim_echo({ { 'Generation timed out', 'WarningMsg' } }, false, {})
    end)
    kill_process(handle, pid)
    cleanup()
  end)

  -- Set up an autocommand to cancel generation when the result buffer is closed
  vim.api.nvim_create_autocmd('BufWinLeave', {
    buffer = result_buf,
    callback = function()
      if M.current_handle then
        M.cancel_generation()
      end
    end,
    once = true,
  })

  return handle

  -- local function on_exit(code, signal)
  --   stdout:read_stop()
  --   stderr:read_stop()
  --   stdout:close()
  --   stderr:close()
  --
  --   if handle then
  --     handle:close()
  --   end
  --
  --   M.current_handle = nil
  --
  --   if line_buffer ~= '' then
  --     append_to_result_buffer(result_buf, '\n')
  --     line_buffer = ''
  --   end
  --
  --   if code ~= 0 then
  --     vim.schedule(function()
  --       vim.api.nvim_echo({ { 'Generation failed: ' .. error_msg, 'ErrorMsg' } }, false, {})
  --     end)
  --   else
  --     vim.schedule(function()
  --       vim.api.nvim_echo({ { 'Generation complete', 'Normal' } }, false, {})
  --       -- toggle_streaming
  --       -- display_result(result)
  --     end)
  --   end
  -- end
  --
end

-- Main function to refactor code
M.refactor = async.void(function(range)
  if M.current_handle then
    vim.api.nvim_echo({ { 'Generation already in progress', 'WarningMsg' } }, false, {})
    return
  end

  local content
  if range == 0 then
    content = get_buffer_content()
  else
    content = get_selected_text()
  end

  local filetype = vim.bo.filetype

  vim.api.nvim_echo({ { 'Generation in progress...', 'Normal' } }, false, {})

  run_ollama_async(content, filetype, 'refactor')
end)

-- Main function to generate tests
M.generate_tests = async.void(function(range)
  if M.current_handle then
    vim.api.nvim_echo({ { 'Generation already in progress', 'WarningMsg' } }, false, {})
    return
  end

  local content
  if range == 0 then
    content = get_buffer_content()
  else
    content = get_selected_text()
  end

  local filetype = vim.bo.filetype

  vim.api.nvim_echo({ { 'Generation in progress...', 'Normal' } }, false, {})

  run_ollama_async(content, filetype, 'test')
end)

M.generate_docs = async.void(function(range)
  if M.current_handle then
    vim.api.nvim_echo({ { 'Generation already in progress', 'WarningMsg' } }, false, {})
    return
  end

  local content
  if range == 0 then
    content = get_function_definition()
  else
    content = get_selected_text()
  end

  local filetype = vim.bo.filetype

  if not content then
    vim.api.nvim_echo({ { 'No function found ', 'WarningMsg' } }, false, {})
    return
  end

  vim.api.nvim_echo({ { 'Generation in progress...', 'Normal' } }, false, {})

  run_ollama_async(content, filetype, 'docs')
end)

function M.cancel_generation()
  if M.current_handle or M.current_pid then
    kill_process(M.current_handle, M.current_pid)
    M.current_handle = nil
    M.current_pid = nil
    vim.api.nvim_echo({ { 'Generation cancelled.', 'WarningMsg' } }, false, {})
  else
    vim.api.nvim_echo({ { 'No generation in progress.', 'WarningMsg' } }, false, {})
  end
end

-- Set up the plugin commands
return {
  'nvim-lua/plenary.nvim',
  config = function()
    vim.api.nvim_create_user_command('GenTests', function(params)
      M.generate_tests(params.range)
    end, { range = true })

    vim.api.nvim_create_user_command('Refactor', function(params)
      M.refactor(params.range)
    end, { range = true })

    vim.api.nvim_create_user_command('GenDocs', function(params)
      M.generate_docs(params.range)
    end, { range = true })

    vim.api.nvim_create_user_command('CancelGen', M.cancel_generation, {})
  end,
}
