local M = {}

-- Keep a burst readable in both floating notifiers and Neovim's message area.
local MAX_SESSIONS = 3
local MAX_SUMMARY_CHARS = 120
local MAX_DETAIL_CHARS = 160
local MAX_PROVIDER_CHARS = 24
local SESSION_ID_CHARS = 8

local provider_names = {
  ["claude-code"] = "Claude Code",
  claude = "Claude Code",
  codex = "Codex",
}

local waiting_reasons = {
  permission = "Permission required",
  question = "Question needs an answer",
  plan = "Plan approval required",
}

local function clean_text(value)
  if type(value) ~= "string" then
    return nil
  end
  -- Session text may contain newlines or terminal control characters.
  value = vim.trim(value:gsub("%c", " "):gsub("%s+", " "))
  if value == "" or value == "—" then
    return nil
  end
  return value
end

local function shorten(value, limit)
  if vim.fn.strchars(value) <= limit then
    return value
  end
  return vim.fn.strcharpart(value, 0, limit - 1) .. "…"
end

local function session_summary(session)
  local provider = clean_text(session.provider) or "Agent"
  provider = shorten(provider_names[provider] or provider, MAX_PROVIDER_CHARS)
  local id = clean_text(session.session_id) or "?"
  -- Provider-qualified IDs (e.g. codex:<uuid>) should not all display "codex:".
  id = vim.fn.strcharpart(id:match("([^:]+)$") or id, 0, SESSION_ID_CHARS)
  local agent = ("%s [%s]"):format(provider, id)

  local project = clean_text(session.project)
  local cwd = clean_text(session.cwd)
  if not project and cwd then
    project = cwd:match("([^/]+)/?$") or cwd
  end
  local label = clean_text(session.label)
  if label and project and label ~= project then
    project = ("%s (%s)"):format(label, project)
  else
    project = label or project
  end

  if project then
    -- Truncate the project text before the identity, preserving the agent ID.
    local room = MAX_SUMMARY_CHARS - vim.fn.strchars("•  · " .. agent)
    return "• " .. shorten(project, room) .. " · " .. agent
  end
  return "• " .. agent
end

local function session_detail(session)
  local reason = waiting_reasons[clean_text(session.waiting_kind)] or "Waiting for input"
  local detail = clean_text(session.waiting_detail) or clean_text(session.last_action)
  return shorten("  " .. reason .. (detail and (": " .. detail) or ""), MAX_DETAIL_CHARS)
end

function M.format(count, sessions)
  local headline = count == 1 and "An agent session is waiting for you"
    or ("%d agent sessions are waiting for you"):format(count)
  local lines = { headline }
  for i = 1, math.min(#(sessions or {}), MAX_SESSIONS) do
    lines[#lines + 1] = session_summary(sessions[i])
    lines[#lines + 1] = session_detail(sessions[i])
  end
  if sessions and #sessions > MAX_SESSIONS then
    lines[#lines + 1] = ("… and %d more"):format(#sessions - MAX_SESSIONS)
  end
  return table.concat(lines, "\n")
end

return M
