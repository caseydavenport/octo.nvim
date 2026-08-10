local config = require "octo.config"
local constants = require "octo.constants"
local vim = vim

local M = {}

---Line tint for each thread sign, keyed by sign name.
---@type table<string, string>
local thread_line_hl = {}

function M.setup()
  local conf = config.values

  -- A sign icon alone is easy to miss, so tint the commented lines too.
  local thread_signs = {
    { "octo_thread", "OctoBlue", "OctoThreadLine" },
    { "octo_thread_resolved", "OctoGreen", "OctoThreadLineResolved" },
    { "octo_thread_outdated", "OctoRed", "OctoThreadLineResolved" },
    { "octo_thread_pending", "OctoYellow", "OctoThreadLine" },
    { "octo_thread_resolved_pending", "OctoYellow", "OctoThreadLineResolved" },
    { "octo_thread_outdated_pending", "OctoYellow", "OctoThreadLineResolved" },
  }
  for _, sign in ipairs(thread_signs) do
    local name, texthl, linehl = sign[1], sign[2], sign[3]
    vim.cmd(string.format("sign define %s text=%s texthl=%s linehl=%s", name, conf.comment_icon, texthl, linehl))
    thread_line_hl[name] = linehl
  end

  vim.cmd [[sign define octo_comment_range numhl=OctoGreen]]
  vim.cmd [[sign define octo_clean_block_start text=┌ linehl=OctoEditable]]
  vim.cmd [[sign define octo_clean_block_end text=└ linehl=OctoEditable]]
  vim.cmd [[sign define octo_dirty_block_start text=┌ texthl=OctoDirty linehl=OctoEditable]]
  vim.cmd [[sign define octo_dirty_block_end text=└ texthl=OctoDirty linehl=OctoEditable]]
  vim.cmd [[sign define octo_dirty_block_middle text=│ texthl=OctoDirty linehl=OctoEditable]]
  vim.cmd [[sign define octo_clean_block_middle text=│ linehl=OctoEditable]]
  vim.cmd [[sign define octo_clean_line text=[ linehl=OctoEditable]]
  vim.cmd [[sign define octo_dirty_line text=[ texthl=OctoDirty linehl=OctoEditable]]
end

---@param name string
---@param bufnr integer
---@param line integer
function M.place(name, bufnr, line)
  -- 0-index based wrapper
  if not line then
    return
  end
  -- sign column
  if config.values.ui.use_signcolumn then
    pcall(vim.fn.sign_place, 0, "octo_ns", name, bufnr, { lnum = line + 1 })
  end
  -- The status column cannot paint a line, so tint via extmark in either mode.
  local linehl = thread_line_hl[name]
  if linehl then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, constants.OCTO_THREAD_TINT_NS, line, 0, {
      line_hl_group = linehl,
    })
  end
end

---@param bufnr? integer
function M.unplace(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, constants.OCTO_THREAD_TINT_NS, 0, -1)
  -- sign column
  if config.values.ui.use_signcolumn then
    pcall(vim.fn.sign_unplace, "octo_ns", { buffer = bufnr })
  end
  -- status column
  if config.values.ui.use_statuscolumn then
    require("octo.ui.statuscolumn").reset(bufnr)
  end
end

---@param bufnr integer
---@param start_line integer
---@param end_line integer
---@param is_dirty boolean
function M.place_signs(bufnr, start_line, end_line, is_dirty)
  if not start_line or not end_line then
    return
  end
  -- sign column
  if config.values.ui.use_signcolumn then
    local dirty_mod = is_dirty and "dirty" or "clean"

    if start_line == end_line or end_line < start_line then
      M.place(string.format("octo_%s_line", dirty_mod), bufnr, start_line)
    else
      M.place(string.format("octo_%s_block_start", dirty_mod), bufnr, start_line)
      M.place(string.format("octo_%s_block_end", dirty_mod), bufnr, end_line)
    end
    if start_line + 1 < end_line then
      for j = start_line + 1, end_line - 1, 1 do
        M.place(string.format("octo_%s_block_middle", dirty_mod), bufnr, j)
      end
    end
  end
  -- status column
  if config.values.ui.use_statuscolumn then
    return require("octo.ui.statuscolumn").add(bufnr, start_line, end_line, is_dirty)
  end
end

return M
