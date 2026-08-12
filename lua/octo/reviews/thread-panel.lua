local OctoBuffer = require("octo.model.octo-buffer").OctoBuffer
local utils = require "octo.utils"
local vim = vim

local M = {}

---Show review threads under cursor if there are any
---@param jump_to_buffer boolean
function M.show_review_threads(jump_to_buffer)
  -- This function is called from a very broad CursorHold event
  -- Check if we are in a diff buffer and otherwise return early
  local bufnr = vim.api.nvim_get_current_buf()
  local split, path = utils.get_split_and_path(bufnr)
  if not split or not path then
    -- not on a diff buffer
    return
  end

  local review = require("octo.reviews").get_current_review()
  if not review then
    -- cant find an active review
    return
  end

  local file = review.layout:get_current_file()
  if not file then
    -- cant find the changed file metadata
    return
  end

  local pr = file.pull_request
  local review_level = review:get_level()
  ---@type octo.ReviewThread[]
  local threads = vim.tbl_values(review.threads)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  local is_unified = review.layout:is_unified()
  if is_unified then
    -- Unified rows are display rows; threads are numbered against a single side.
    local line_ok, line_map = pcall(vim.api.nvim_buf_get_var, bufnr, "octo_unified_line_map")
    if not line_ok or not line_map then
      return
    end
    local entry = line_map[line]
    if not entry or entry.side == "HEADER" then
      M.hide_thread_buffer_unified(review)
      return
    end
    line = entry.line
  end

  -- get threads associated with current line
  local threads_at_cursor = {}
  for _, thread in ipairs(threads) do
    local side_matches = not is_unified or thread.diffSide == split
    if
      review_level == "PR"
      and side_matches
      and utils.is_thread_placed_in_buffer(thread, bufnr)
      and thread.startLine <= line
      and thread.line >= line
    then
      table.insert(threads_at_cursor, thread)
    elseif review_level == "COMMIT" and side_matches then
      for _, comment in ipairs(thread.comments.nodes) do
        if
          review.layout.right.commit == comment.originalCommit.oid
          and utils.is_thread_placed_in_buffer(thread, bufnr)
          and thread.originalLine == line
        then
          table.insert(threads_at_cursor, thread)
          break
        end
      end
    end
  end

  if #threads_at_cursor == 0 then
    -- no threads at the current line, hide the thread buffer
    if is_unified then
      M.hide_thread_buffer_unified(review)
    else
      M.hide_thread_buffer(split, file)
    end
    return
  end

  review.layout:ensure_layout()

  local origin_win = vim.api.nvim_get_current_win()

  -- Pick the window the thread buffer goes in, and how "q" gets back to the diff.
  local thread_win, on_close
  if is_unified then
    thread_win = M.get_thread_win_unified(review)
    on_close = function()
      M.hide_thread_buffer_unified(review)
      if vim.api.nvim_win_is_valid(review.layout.unified_winid) then
        vim.api.nvim_set_current_win(review.layout.unified_winid)
      end
    end
  else
    thread_win = file:get_alternative_win(split)
    if not vim.api.nvim_win_is_valid(thread_win) then
      return
    end
    on_close = function()
      M.hide_thread_buffer(split, file)
      local file_win = file:get_win(split)
      if vim.api.nvim_win_is_valid(file_win) then
        vim.api.nvim_set_current_win(file_win)
      end
    end
  end

  local thread_buffer = M.create_thread_buffer(threads_at_cursor, pr.repo, pr.number, split, file.path)
  if not thread_buffer then
    return
  end
  table.insert(file.associated_bufs, thread_buffer.bufnr)
  vim.api.nvim_win_set_buf(thread_win, thread_buffer.bufnr)
  thread_buffer:configure()

  vim.keymap.set("n", "q", on_close, { buffer = thread_buffer.bufnr })

  if jump_to_buffer then
    vim.api.nvim_set_current_win(thread_win)
  elseif vim.api.nvim_win_is_valid(origin_win) then
    -- Opening the split focused it; skimming the diff should not move the cursor.
    vim.api.nvim_set_current_win(origin_win)
  end
  vim.api.nvim_buf_call(thread_buffer.bufnr, function()
    vim.cmd [[diffoff!]]
    if not is_unified then
      pcall(vim.cmd.normal, "]c")
    end
  end)
end

---Return the unified-mode thread window, opening it beside the diff if needed.
---@param review Review
---@return integer
function M.get_thread_win_unified(review)
  local thread_win = review.layout.thread_winid
  if thread_win and vim.api.nvim_win_is_valid(thread_win) then
    return thread_win
  end
  -- Comments read better in a tall narrow column than a short wide one.
  vim.cmd "botright vsplit"
  thread_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(thread_win, math.max(60, math.floor(vim.o.columns * 0.35)))
  vim.wo[thread_win].wrap = true
  vim.wo[thread_win].linebreak = true
  review.layout.thread_winid = thread_win
  return thread_win
end

---Hide the thread buffer in unified mode by closing the thread window.
---@param review Review
function M.hide_thread_buffer_unified(review)
  local thread_win = review.layout.thread_winid
  if thread_win and vim.api.nvim_win_is_valid(thread_win) then
    vim.api.nvim_win_close(thread_win, true)
    review.layout.thread_winid = nil
  end
end

---@param split OctoSplit
---@param file FileEntry
function M.hide_thread_buffer(split, file)
  local alt_buf = file:get_alternative_buf(split)
  local alt_win = file:get_alternative_win(split)
  if vim.api.nvim_win_is_valid(alt_win) and vim.api.nvim_buf_is_valid(alt_buf) then
    local current_alt_bufnr = vim.api.nvim_win_get_buf(alt_win)
    if current_alt_bufnr ~= alt_buf then
      -- if we are not showing the corresponding alternative diff buffer, do so
      vim.api.nvim_win_set_buf(alt_win, alt_buf)

      -- Save cursor position before show_diff (which scrolls to sync windows)
      local current_win = vim.api.nvim_get_current_win()
      local cursor_pos = vim.api.nvim_win_get_cursor(current_win)

      -- show the diff
      file:show_diff()

      -- Restore cursor position (show_diff scrolls which can disrupt cursor)
      if vim.api.nvim_win_is_valid(current_win) then
        pcall(vim.api.nvim_win_set_cursor, current_win, cursor_pos)
      end
    end
  end
end

---Create a thread buffer
---@param threads ReviewThread[]
---@param repo string
---@param number integer
---@param side string
---@param path string
---@return OctoBuffer | nil
function M.create_thread_buffer(threads, repo, number, side, path)
  local current_review = require("octo.reviews").get_current_review()
  if not current_review then
    return
  end

  if not vim.startswith(path, "/") then
    path = "/" .. path
  end
  local line = threads[1].originalStartLine ~= vim.NIL and threads[1].originalStartLine or threads[1].originalLine
  local bufname = string.format("octo://%s/review/%s/threads/%s%s:%d", repo, current_review.id, side, path, line)
  local existing_bufnr = vim.fn.bufnr(bufname)

  if existing_bufnr ~= -1 then
    if vim.api.nvim_buf_is_loaded(existing_bufnr) then
      return octo_buffers[existing_bufnr]
    end

    -- Weird situation, force delete buffer and start from scratch
    vim.api.nvim_buf_delete(existing_bufnr, { force = true })
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, bufname)
  local buffer = OctoBuffer:new {
    bufnr = bufnr,
    number = number,
    repo = repo,
  }
  buffer:render_threads(threads)
  buffer:render_signs()
  vim.api.nvim_buf_call(bufnr, function()
    utils.clear_history()
  end)
  return buffer
end

return M
