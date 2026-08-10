local Layout = require("octo.reviews.layout").Layout
local Rev = require("octo.reviews.rev").Rev
local config = require "octo.config"
local gh = require "octo.gh"
local queries = require "octo.gh.queries"
local graphql = require "octo.gh.graphql"
local thread_panel = require "octo.reviews.thread-panel"
local window = require "octo.ui.window"
local utils = require "octo.utils"
local ReviewThread = require("octo.reviews.thread").ReviewThread

---@alias ReviewLevel "COMMIT" | "PR"

---@class Review
---@field repo string
---@field number integer
---@field id string|-1
---@field threads octo.ReviewThread[]
---@field files FileEntry[]
---@field layout Layout
---@field pull_request PullRequest
local Review = {}
Review.__index = Review

local default_id = -1

---Review constructor.
---@param pull_request PullRequest
---@return Review
function Review:new(pull_request)
  local this = {
    pull_request = pull_request,
    id = default_id,
    threads = {},
    files = {},
  }
  setmetatable(this, self)
  return this
end

---Creates a new review
---@param callback fun(obj: octo.mutations.StartReview): nil
function Review:create(callback)
  local query = graphql("start_review_mutation", self.pull_request.id)
  gh.api.graphql {
    f = { query = query },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local resp = vim.json.decode(output)
          callback(resp)
        end,
      },
    },
  }
end

---Get review threads without start a review.
---@param callback fun(obj: octo.queries.ReviewThreads): nil
function Review:populate_threads(callback)
  gh.api.graphql {
    query = queries.review_threads,
    F = { owner = self.pull_request.owner, name = self.pull_request.name, number = self.pull_request.number },
    opts = {
      cb = function(output, stderr)
        if stderr and not utils.is_blank(stderr) then
          utils.error(stderr)
        elseif output then
          local resp = vim.json.decode(output)
          callback(resp)
        end
      end,
    },
  }
end

function Review:browse()
  self:populate_threads(function(resp)
    local threads = resp.data.repository.pullRequest.reviewThreads.nodes
    self:update_threads(threads)
    self:initiate()
  end)
end

-- Starts a new review
function Review:start()
  self:create(function(resp)
    self.id = resp.data.addPullRequestReview.pullRequestReview.id
    local threads = resp.data.addPullRequestReview.pullRequestReview.pullRequest.reviewThreads.nodes
    self:update_threads(threads)
    self:initiate()
  end)
end

---Retrieves existing review
---@param callback fun(obj: octo.queries.PendingReviewThreads): nil
function Review:retrieve(callback)
  gh.api.graphql {
    query = queries.pending_review_threads,
    F = { owner = self.pull_request.owner, name = self.pull_request.name, number = self.pull_request.number },
    opts = {
      cb = gh.create_callback {
        success = function(output)
          local resp = vim.json.decode(output)
          callback(resp)
        end,
      },
    },
  }
end

-- Resumes an existing review
function Review:resume()
  self:retrieve(function(resp)
    -- There can only be one pending review for a given user, stop at the first one
    for _, review in ipairs(resp.data.repository.pullRequest.reviews.nodes) do
      if review.viewerDidAuthor then
        self.id = review.id
        break
      end
    end

    if self.id == default_id then
      utils.error "No pending reviews found for viewer"
      return
    end

    local threads = resp.data.repository.pullRequest.reviewThreads.nodes
    self:update_threads(threads)
    self:initiate()
  end)
end

-- Resumes an existing review if there is any, else start one
function Review:start_or_resume()
  self:retrieve(function(resp)
    -- There can only be one pending review for a given user
    for _, review in ipairs(resp.data.repository.pullRequest.reviews.nodes) do
      if review.viewerDidAuthor then
        self.id = review.id
        break
      end
    end

    if self.id == default_id then
      utils.info "No pending review, starting one"
      self:start()
      return
    end

    utils.info "Resuming review"
    local threads = resp.data.repository.pullRequest.reviewThreads.nodes
    self:update_threads(threads)
    self:initiate()
  end)
end

---Register freshly fetched files as this review's files
---Selects and fetches the first unread files
---Defaults to the first file if all files are VIEWED
---@param files FileEntry[]
function Review:set_files_and_select_first(files)
  local selected_file_idx ---@type integer?
  for idx, file in ipairs(files) do
    if file.viewed_state ~= "VIEWED" then
      selected_file_idx = idx
      break
    end
  end

  if not selected_file_idx and #files > 0 then
    selected_file_idx = 1
  end

  self.layout.files = files
  if selected_file_idx then
    files[selected_file_idx]:fetch(true)
    self.layout.selected_file_idx = selected_file_idx
  end
  for _, file in ipairs(files) do
    file:fetch(false)
  end
  self.layout:update_files()
end

---Updates layout to focus on a single commit
---@param right string
---@param left string
function Review:focus_commit(right, left)
  local pr = self.pull_request
  self.layout:close()
  self.layout = Layout:new {
    right = Rev:new(right),
    left = Rev:new(left),
    files = {},
  }
  self.layout:open(self)
  local function cb(files)
    self:set_files_and_select_first(files)
  end
  if right == self.pull_request.right.commit and left == self.pull_request.left.commit then
    pr:get_changed_files(cb)
  else
    pr:get_commit_changed_files(self.layout.right, cb)
  end
end

---Initiates (starts/resumes) a review
---@param opts? { left?: Rev, right?: Rev }
function Review:initiate(opts)
  opts = opts or {}
  local pr = self.pull_request
  local conf = config.values
  if conf.use_local_fs and not utils.in_pr_branch(pr) then
    local choice = vim.fn.confirm("Currently not in PR branch, would you like to checkout?", "&Yes\n&No", 2)
    if choice == 1 then
      utils.checkout_pr_sync { repo = pr.repo, pr_number = pr.number }
    end
  end

  -- create the layout
  self.layout = Layout:new {
    left = opts.left or pr.left,
    right = opts.right or pr.right,
    files = {},
  }
  self.layout:open(self)

  pr:get_changed_files(function(files)
    self:set_files_and_select_first(files)
  end)
end

---Counts pending comments with non-empty bodies in review threads
---@see octo.PullRequestReviewState for explanation of why we check pullRequestReview.state
---@param threads octo.ReviewThread[]
---@return integer count The number of pending comments with content
local function count_pending_comments(threads)
  local count = 0
  for _, thread in ipairs(threads) do
    for _, comment in ipairs(thread.comments.nodes) do
      if comment.pullRequestReview.state == "PENDING" and not utils.is_blank(utils.trim(comment.body)) then
        count = count + 1
      end
    end
  end
  return count
end

---Discard the current review
---@param opts? { skip_confirm?: boolean } Options for discarding the review
function Review:discard(opts)
  opts = opts or {}
  local skip_confirm = opts.skip_confirm or false

  gh.api.graphql {
    query = queries.pending_review_threads,
    F = { owner = self.pull_request.owner, name = self.pull_request.name, number = self.pull_request.number },
    opts = {
      cb = function(output, stderr)
        if stderr and not utils.is_blank(stderr) then
          utils.error(stderr)
        elseif output then
          ---@type octo.queries.PendingReviewThreads
          local resp = vim.json.decode(output)
          if #resp.data.repository.pullRequest.reviews.nodes == 0 then
            utils.error "No pending reviews found"
            return
          end
          self.id = resp.data.repository.pullRequest.reviews.nodes[1].id

          local pending_count = count_pending_comments(resp.data.repository.pullRequest.reviewThreads.nodes)
          local choice = 1
          if pending_count > 0 and not skip_confirm then
            local message = string.format(
              "%d pending comment%s will be deleted, are you sure?",
              pending_count,
              pending_count == 1 and "" or "s"
            )
            choice = vim.fn.confirm(message, "&Yes\n&No\n&Cancel", 2)
          end

          if choice == 1 then
            local delete_query = graphql("delete_pull_request_review_mutation", self.id --[[@as string]])
            gh.api.graphql {
              f = { query = delete_query },
              opts = {
                cb = gh.create_callback {
                  success = function()
                    self.id = default_id
                    self.threads = {}
                    self.files = {}
                    utils.info "Pending review discarded"
                    vim.cmd [[tabclose]]
                  end,
                },
              },
            }
          end
        end
      end,
    },
  }
end

---@param threads octo.ReviewThread[]
function Review:update_threads(threads)
  self.threads = {}
  for _, thread in ipairs(threads) do
    if thread.line == vim.NIL then
      thread.line = thread.originalLine
    end
    if thread.startLine == vim.NIL then
      thread.startLine = thread.line
      thread.startDiffSide = thread.diffSide
      thread.originalStartLine = thread.originalLine
    end
    if not thread.isOutdated then
      self.threads[thread.id] = thread
    end
  end
  if self.layout then
    self.layout.file_panel:render()
    self.layout.file_panel:redraw()
    local file = self.layout:get_current_file()
    if file then
      file:place_signs()
    end
  end
end

function Review:collect_submit_info()
  if self.id == default_id then
    utils.error "No review in progress"
    return
  end

  local conf = config.values
  local winid, bufnr = window.create_centered_float {
    header = string.format(
      "Press %s to approve, %s to comment or %s to request changes",
      conf.mappings.submit_win.approve_review.lhs,
      conf.mappings.submit_win.comment_review.lhs,
      conf.mappings.submit_win.request_changes.lhs
    ),
  }
  vim.api.nvim_set_current_win(winid)
  vim.bo[bufnr].syntax = "octo"
  utils.apply_mappings("submit_win", bufnr)
  vim.cmd [[normal G]]
end

---@param event "APPROVE" | "COMMENT" | "REQUEST_CHANGES"
function Review:submit(event)
  local review_id = self.id
  if review_id == -1 then
    utils.error "No review in progress"
    return
  end
  review_id = review_id --[[@as string]]
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, default_id, false)
  local body = utils.escape_char(utils.trim(table.concat(lines, "\n")))
  local query = graphql("submit_pull_request_review_mutation", review_id, event, body, { escape = false })
  gh.api.graphql {
    f = { query = query },
    opts = {
      cb = gh.create_callback {
        success = function()
          utils.info "Review was submitted successfully!"
          pcall(vim.api.nvim_win_close, winid, 0)
          self.layout:close()
        end,
      },
    },
  }
end

function Review:show_pending_comments()
  local pending_threads = {}
  for _, thread in
    ipairs(vim.tbl_values(self.threads) --[[@as octo.ReviewThread[] ]])
  do
    for _, comment in ipairs(thread.comments.nodes) do
      if comment.pullRequestReview.state == "PENDING" and not utils.is_blank(utils.trim(comment.body)) then
        table.insert(pending_threads, thread)
      end
    end
  end
  if #pending_threads == 0 then
    utils.error "No pending comments found"
    return
  else
    require("octo.picker").pending_threads(pending_threads)
  end
end

---@param isSuggestion boolean
function Review:add_comment(isSuggestion)
  -- check if we are on the diff layout and return early if not
  local bufnr = vim.api.nvim_get_current_buf()
  local is_unified = self.layout:is_unified()

  -- Selected range in buffer rows; in unified mode these differ from the file lines.
  local buf_line1, buf_line2 = utils.get_lines_from_context "visual"
  if OctoLastCmdOpts ~= nil then
    buf_line1 = OctoLastCmdOpts.line1
    buf_line2 = OctoLastCmdOpts.line2
  end

  local split, path, line1, line2
  if is_unified then
    local ok, props = pcall(vim.api.nvim_buf_get_var, bufnr, "octo_diff_props")
    local line_ok, line_map = pcall(vim.api.nvim_buf_get_var, bufnr, "octo_unified_line_map")
    if not ok or not props or props.split ~= "UNIFIED" or not line_ok or not line_map then
      return
    end
    path = props.path

    local entry1 = line_map[buf_line1]
    if not entry1 or entry1.side == "HEADER" then
      utils.error "Cannot place comments on hunk headers"
      return
    end
    split = entry1.side
    line1 = entry1.line

    local entry2 = line_map[buf_line2]
    line2 = (entry2 and entry2.side ~= "HEADER") and entry2.line or line1
  else
    split, path = utils.get_split_and_path(bufnr)
    if not split or not path then
      return
    end
    line1, line2 = buf_line1, buf_line2
  end

  local file = self.layout:get_current_file()
  if not file then
    return
  end

  ---@type [integer, integer][], integer
  local comment_ranges, current_bufnr
  if split == "RIGHT" then
    comment_ranges = file.right_comment_ranges
    current_bufnr = is_unified and file.unified_bufid or file.right_bufid
  elseif split == "LEFT" then
    comment_ranges = file.left_comment_ranges
    current_bufnr = is_unified and file.unified_bufid or file.left_bufid
  else
    return
  end
  if not current_bufnr or not comment_ranges then
    utils.error "Failed to create comment"
    return
  end

  local diff_hunk ---@type string
  for i, range in ipairs(comment_ranges) do
    if range[1] <= line1 and range[2] >= line2 then
      diff_hunk = file.diffhunks[i]
      break
    end
  end
  if not diff_hunk then
    utils.error "Cannot place comments outside diff hunks"
    return
  end
  if not vim.startswith(diff_hunk, "@@") then
    diff_hunk = "@@ " .. diff_hunk
  end

  self.layout:ensure_layout()

  local pr = file.pull_request

  ---@type string, string
  local commit, commit_abbrev
  if split == "LEFT" then
    commit = self.layout.left.commit
    commit_abbrev = self.layout.left:abbrev()
  elseif split == "RIGHT" then
    commit = self.layout.right.commit
    commit_abbrev = self.layout.right:abbrev()
  end
  local threads = {
    ReviewThread:stub {
      line1 = line1,
      line2 = line2,
      file_path = file.path,
      split = split,
      diff_hunk = diff_hunk,
      commit = commit,
      commit_abbrev = commit_abbrev,
      review_id = self.id,
    },
  }

  -- Pick the window the thread buffer goes in, and how "q" gets back to the diff.
  local thread_win, on_close
  if is_unified then
    thread_win = self.layout.thread_winid
    if not thread_win or not vim.api.nvim_win_is_valid(thread_win) then
      vim.cmd "botright split"
      thread_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_height(thread_win, 12)
      self.layout.thread_winid = thread_win
    end
    on_close = function()
      thread_panel.hide_thread_buffer_unified(self)
      if vim.api.nvim_win_is_valid(self.layout.unified_winid) then
        vim.api.nvim_set_current_win(self.layout.unified_winid)
      end
    end
  else
    thread_win = file:get_alternative_win(split)
    if not vim.api.nvim_win_is_valid(thread_win) then
      utils.error("Cannot find diff window " .. thread_win)
      return
    end
    on_close = function()
      thread_panel.hide_thread_buffer(split, file)
      local file_win = file:get_win(split)
      if vim.api.nvim_win_is_valid(file_win) then
        vim.api.nvim_set_current_win(file_win)
      end
    end
  end

  -- Make sure review thread panel is visible if not already
  thread_panel.show_review_threads(false)
  local thread_buffer = thread_panel.create_thread_buffer(threads, pr.repo, pr.number, split, file.path)
  if not thread_buffer then
    return
  end
  table.insert(file.associated_bufs, thread_buffer.bufnr)
  vim.api.nvim_win_set_buf(thread_win, thread_buffer.bufnr)
  vim.api.nvim_set_current_win(thread_win)

  if isSuggestion then
    local lines = vim.api.nvim_buf_get_lines(current_bufnr, buf_line1 - 1, buf_line2 --[[@as integer]], false)
    if is_unified then
      -- Unified rows carry a leading "+", "-" or space that is not part of the file.
      for i, l in ipairs(lines) do
        lines[i] = l:sub(2)
      end
    end
    local suggestion = { "```suggestion" }
    vim.list_extend(suggestion, lines)
    table.insert(suggestion, "```")
    vim.api.nvim_buf_set_lines(thread_buffer.bufnr, -3, -2, false, suggestion)
    vim.bo[thread_buffer.bufnr].modified = false
  end

  thread_buffer:configure()
  vim.cmd [[diffoff!]]
  vim.cmd [[normal! vvGk]]
  vim.cmd [[startinsert]]

  vim.keymap.set("n", "q", on_close, { buffer = thread_buffer.bufnr })
end

---Get the review level, aka whether the review is at commit or PR level
---@return ReviewLevel
function Review:get_level()
  if
    self.layout.left.commit == self.pull_request.left.commit
    and self.layout.right.commit == self.pull_request.right.commit
  then
    return "PR"
  end
  return "COMMIT"
end

local M = {}

---@type table<string, Review>
M.reviews = {}

M.Review = Review

---@param isSuggestion boolean
function M.add_review_comment(isSuggestion)
  local review = M.get_current_review()

  if not review then
    error "Could not find review"
  end

  -- we maybe in browse mode, where no review has been started.
  if review.id == -1 then
    utils.error "Please start or resume a review first"
    return
  end

  review:add_comment(isSuggestion)
end

---@param thread ReviewThread
function M.jump_to_pending_review_thread(thread)
  local current_review = M.get_current_review()
  if not current_review then
    return
  end
  for _, file in ipairs(current_review.layout.files) do
    if thread.path == file.path then
      current_review.layout:ensure_layout()
      current_review.layout:set_current_file(file)

      if current_review.layout:is_unified() then
        -- In unified mode, find the display line that corresponds to the thread
        local win = current_review.layout.unified_winid
        if vim.api.nvim_win_is_valid(win) then
          local bufnr = vim.api.nvim_win_get_buf(win)
          local ok, line_map = pcall(vim.api.nvim_buf_get_var, bufnr, "octo_unified_line_map")
          if ok and line_map then
            local review_level = current_review:get_level()
            local target_line = review_level == "COMMIT" and thread.originalStartLine or thread.startLine
            local target_side = thread.diffSide
            for display_line, entry in ipairs(line_map) do
              if entry.side == target_side and entry.line == target_line then
                vim.api.nvim_set_current_win(win)
                vim.api.nvim_win_set_cursor(win, { display_line, 0 })
                return
              end
            end
          end
          -- Fallback: just focus the window
          vim.api.nvim_set_current_win(win)
        else
          utils.error "Cannot find diff window"
        end
      else
        local win = file:get_win(thread.diffSide)
        if vim.api.nvim_win_is_valid(win) then
          local review_level = current_review:get_level()
          local line = review_level == "COMMIT" and thread.originalStartLine or thread.startLine
          vim.api.nvim_set_current_win(win)
          vim.api.nvim_win_set_cursor(win, { line, 0 })
        else
          utils.error "Cannot find diff window"
        end
      end
      break
    end
  end
end

--- Get the current review according to the tab page
--- @return Review | nil
function M.get_current_review()
  local current_tabpage = vim.api.nvim_get_current_tabpage()
  return M.reviews[tostring(current_tabpage)]
end

--- Get the diff Layout of the review if any
--- @return Layout | nil
function M.get_current_layout()
  local current_review = M.get_current_review()
  if current_review then
    return M.get_current_review().layout
  end
end

function M.on_tab_enter()
  local current_review = M.get_current_review()
  if current_review and current_review.layout then
    current_review.layout:on_enter()
  end
end

function M.on_tab_leave()
  local current_review = M.get_current_review()
  if current_review and current_review.layout then
    current_review.layout:on_leave()
  end
end

function M.on_win_leave()
  local current_review = M.get_current_review()
  if current_review and current_review.layout then
    current_review.layout:on_win_leave()
  end
end

function M.close(tabpage)
  if tabpage then
    local review = M.reviews[tostring(tabpage)]
    if review and review.layout then
      review.layout:close()
    end
    M.reviews[tostring(tabpage)] = nil
  end
end

--- Get the pull request associated with current buffer.
--- Fall back to pull request associated with the current branch if not in an Octo buffer.
--- @param cb fun(pull_request: PullRequest?): nil
local function get_pr_from_buffer_or_current_branch(cb)
  local buffer = utils.get_current_buffer()

  if not buffer then
    -- We are not in an octo buffer, try and fallback to the current branch's pr
    utils.get_pull_request_for_current_branch(cb)
    return
  end

  if buffer:isPullRequest() then
    buffer:get_pr(cb)
  else
    utils.get_pull_request_for_current_branch(cb)
  end
end

function M.browse_review()
  local current_review = M.get_current_review()

  if current_review and current_review.id ~= -1 then
    utils.error "Cannot browse when a review has been started"
    return
  end

  get_pr_from_buffer_or_current_branch(function(pull_request)
    current_review = Review:new(pull_request)
    current_review:browse()
  end)
end

function M.start_review()
  -- its possible we are already browsing a review with 'Octo review browse'
  local current_review = M.get_current_review()
  if current_review then
    current_review:start()
    return
  end

  get_pr_from_buffer_or_current_branch(function(pull_request)
    current_review = Review:new(pull_request)
    current_review:start()
  end)
end

function M.resume_review()
  get_pr_from_buffer_or_current_branch(function(pull_request)
    local current_review = Review:new(pull_request)
    current_review:resume()
  end)
end

function M.start_or_resume_review()
  get_pr_from_buffer_or_current_branch(function(pull_request)
    local current_review = Review:new(pull_request)
    current_review:start_or_resume()
  end)
end

function M.discard_review()
  local current_review = M.get_current_review()
  if current_review and current_review.id ~= -1 then
    current_review:discard()
  else
    utils.error "Please start or resume a review first"
  end
end

function M.submit_review()
  local current_review = M.get_current_review()
  if current_review and current_review.id ~= -1 then
    current_review:collect_submit_info()
  else
    utils.error "Please start or resume a review first"
  end
end

return M
