if vim.g.loaded_sops then
  return
end
vim.g.loaded_sops = true

local patterns = { "*.sops.yml", "*.sops.yaml", "*.sops.json", "*.sops.env", "*.sops.ini" }

-- "sops edit" appends the path of its plaintext temp file to this command.
-- The stub replaces that file with the buffer contents arriving on stdin.
-- When sops rejects the contents it runs the editor again; stdin is empty by
-- then, so "test -s" fails and sops exits instead of retrying forever.
local editor_stub = [[sh -c 'cat > "$1" && test -s "$1"' sops-stdin]]

-- sops exits with this code when the edited contents equal the decrypted file.
local exit_code_unchanged = 200

local timeout_milliseconds = 30000

local ciphertext_marker = "ENC[AES256_GCM,"

-- The window option only points at a buffer variable, so a state change needs
-- no access to the windows showing the buffer.
local winbar = "%{%get(b:,'sops_winbar','')%}"

local group = vim.api.nvim_create_augroup("sops", { clear = true })
local namespace = vim.api.nvim_create_namespace("sops")

local function run_sops(arguments, file, options)
  if vim.fn.executable("sops") == 0 then
    return { code = 127, stdout = "", stderr = "sops is not on PATH" }
  end
  options = options or {}
  options.text = true
  -- sops looks for .sops.yaml (output formatting) upwards from the working directory.
  options.cwd = vim.fs.dirname(file)
  -- Without a controlling terminal sops fails instead of prompting for a
  -- passphrase behind the Neovim UI, and closing the terminal does not kill it
  -- while its plaintext temp file exists.
  options.detach = true
  local result = vim.system(vim.list_extend({ "sops" }, arguments), options):wait(timeout_milliseconds)
  -- wait() returns nothing when a child of sops outlives the kill after a timeout.
  if not result or result.signal ~= 0 then
    local message = ("sops was killed or did not finish within %d seconds"):format(timeout_milliseconds / 1000)
    return { code = 124, stdout = "", stderr = message }
  end
  return result
end

local function decrypt(file)
  local result = run_sops({ "decrypt", file }, file)
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr)
  end
  return vim.split(result.stdout:gsub("\n$", ""), "\n", { plain = true })
end

local function fingerprint(file)
  local stat = vim.uv.fs_stat(file)
  return stat and ("%d.%d.%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
end

local function set_lines_without_undo(buffer, lines)
  local undolevels = vim.bo[buffer].undolevels
  vim.bo[buffer].undolevels = -1
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].undolevels = undolevels
  vim.bo[buffer].modified = false
end

local function report_error(message)
  vim.notify("sops: " .. message, vim.log.levels.ERROR)
end

local function set_winbar(buffer, highlight, state, hint)
  vim.b[buffer].sops_winbar = ("%%#%s# SOPS %s %%* %s"):format(highlight, state, hint or "")
  vim.cmd.redrawstatus({ bang = true })
end

-- Annotates every buffer line whose value is encrypted in the stored
-- file. Expects the buffer to hold the decrypted file as sops prints it. The
-- two differ in line count (multi-line values, the sops metadata block), so
-- lines are paired in order by the text in front of the value.
local function mark_encrypted_lines(buffer, file)
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local row = 1
  for _, stored in ipairs(vim.fn.readfile(file)) do
    local position = stored:find(ciphertext_marker, 1, true)
    if position then
      local prefix = (stored:sub(1, position - 1):gsub('"$', ""))
      while row <= #lines and not vim.startswith(lines[row], prefix) do
        row = row + 1
      end
      if row > #lines then
        return
      end
      vim.api.nvim_buf_set_extmark(buffer, namespace, row - 1, 0, {
        virt_text = { { "encrypted on disk", "DiagnosticVirtualTextOk" } },
        virt_text_pos = "eol",
      })
      row = row + 1
    end
  end
end

local function show_encrypted(buffer, file, decrypt_failed)
  vim.bo[buffer].modifiable = true
  set_lines_without_undo(buffer, vim.fn.readfile(file))
  vim.bo[buffer].readonly = true
  vim.bo[buffer].modifiable = false
  vim.b[buffer].sops_decrypted = false
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  if decrypt_failed then
    set_winbar(buffer, "DiagnosticError", "decrypt failed [RO]", ":SopsToggle")
  else
    set_winbar(buffer, "DiagnosticOk", "encrypted [RO]", ":SopsToggle")
  end
end

-- Returns the sops error output when decryption fails, leaving the buffer as it was.
local function show_decrypted(buffer, file)
  local lines, failure = decrypt(file)
  if not lines then
    return failure
  end
  vim.bo[buffer].modifiable = true
  vim.bo[buffer].readonly = false
  set_lines_without_undo(buffer, lines)
  vim.b[buffer].sops_fingerprint = fingerprint(file)
  vim.b[buffer].sops_decrypted = true
  mark_encrypted_lines(buffer, file)
  set_winbar(buffer, "DiagnosticWarn", "decrypted", ":SopsToggle")
end

local function toggle(buffer)
  local file = vim.b[buffer].sops_file
  if not file then
    report_error("no encrypted file behind this buffer")
  elseif not vim.b[buffer].sops_decrypted then
    local failure = show_decrypted(buffer, file)
    if failure then
      show_encrypted(buffer, file, true)
      report_error("decrypt failed:\n" .. failure)
    end
  elseif vim.bo[buffer].modified then
    report_error("write or discard the changes before switching to the encrypted view")
  else
    show_encrypted(buffer, file)
  end
end

-- With clipboard=unnamedplus every yank, change and delete would copy secrets
-- to the system clipboard, so the option is cleared while a sops buffer is current.
local clipboard_before_suspend
local function suspend_clipboard()
  if clipboard_before_suspend == nil then
    clipboard_before_suspend = vim.o.clipboard
    vim.o.clipboard = ""
  end
end
local function restore_clipboard()
  if clipboard_before_suspend ~= nil then
    vim.o.clipboard = clipboard_before_suspend
    clipboard_before_suspend = nil
  end
end

local function write(event)
  local buffer = event.buf
  local file = vim.b[buffer].sops_file

  if not vim.b[buffer].sops_decrypted then
    report_error("buffer does not hold decrypted contents, not writing")
    return
  end
  if vim.uv.fs_realpath(event.match) ~= file then
    report_error("a decrypted buffer can only be written back to " .. file)
    return
  end
  if vim.v.cmdbang == 0 and fingerprint(file) ~= vim.b[buffer].sops_fingerprint then
    report_error("file changed on disk, reload with :e or overwrite with :w!")
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  for number, line in ipairs(lines) do
    if line:find(ciphertext_marker, 1, true) then
      report_error(("line %d holds ciphertext, which would be encrypted as a literal value"):format(number))
      return
    end
  end

  local result = run_sops({ "edit", file }, file, {
    stdin = table.concat(lines, "\n") .. "\n",
    -- sops older than 3.10 only reads EDITOR.
    env = { SOPS_EDITOR = editor_stub, EDITOR = editor_stub },
  })

  local name = vim.fn.fnamemodify(file, ":~:.")
  if result.code == exit_code_unchanged then
    vim.bo[buffer].modified = false
    vim.notify(('"%s" has no changes to encrypt'):format(name))
  elseif result.code == 0 then
    -- sops normalizes what it parses (blank lines, quoting, indentation).
    -- Showing its version keeps the next write from seeing phantom changes.
    local normalized = decrypt(file)
    if normalized and not vim.deep_equal(normalized, lines) then
      local view = vim.api.nvim_get_current_buf() == buffer and vim.fn.winsaveview()
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, normalized)
      if view then
        vim.fn.winrestview(view)
      end
    end
    vim.bo[buffer].modified = false
    vim.b[buffer].sops_fingerprint = fingerprint(file)
    if normalized then
      mark_encrypted_lines(buffer, file)
    end
    vim.notify(('"%s" encrypted and written'):format(name))
  else
    report_error("file not written, encrypt failed:\n" .. vim.trim(result.stderr))
  end
end

local function refuse_partial_write()
  report_error("partial and append writes of a decrypted buffer are not supported")
end

-- Buffer-local handlers catch every write of the buffer whatever the target
-- name, so plaintext never goes through Neovim's own file writing. "acwrite"
-- also keeps git integrations from attaching and staging plaintext.
local function protect(buffer)
  vim.bo[buffer].buftype = "acwrite"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].undofile = false
  vim.bo[buffer].modeline = false

  vim.api.nvim_clear_autocmds({ group = group, buffer = buffer })
  vim.api.nvim_create_autocmd("BufWriteCmd", { group = group, buffer = buffer, callback = write })
  vim.api.nvim_create_autocmd(
    { "FileWriteCmd", "FileAppendCmd" },
    { group = group, buffer = buffer, callback = refuse_partial_write }
  )
  vim.api.nvim_create_autocmd("BufEnter", { group = group, buffer = buffer, callback = suspend_clipboard })
  vim.api.nvim_create_autocmd("BufLeave", { group = group, buffer = buffer, callback = restore_clipboard })
  vim.api.nvim_buf_create_user_command(buffer, "SopsToggle", function()
    toggle(buffer)
  end, { desc = "Switch between the decrypted and the stored, encrypted contents" })
  if vim.api.nvim_get_current_buf() == buffer then
    suspend_clipboard()
  end
end

local function read(event)
  local buffer = event.buf
  local file = event.match

  vim.b[buffer].sops_decrypted = false
  vim.bo[buffer].modifiable = true
  vim.bo[buffer].readonly = false
  protect(buffer)

  if not vim.uv.fs_stat(file) then
    set_winbar(buffer, "DiagnosticError", "file does not exist")
    report_error(file .. " does not exist, create it with sops first")
    return
  end
  vim.b[buffer].sops_file = vim.uv.fs_realpath(file)

  local failure = show_decrypted(buffer, file)
  if failure then
    show_encrypted(buffer, file, true)
    report_error("showing encrypted contents, decrypt failed:\n" .. failure)
  end

  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buffer })
end

vim.api.nvim_create_autocmd("BufReadCmd", { group = group, pattern = patterns, callback = read })

-- Window options stay with the window when it shows another buffer, so the
-- winbar is also taken away again here.
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = group,
  callback = function(event)
    local window = vim.api.nvim_get_current_win()
    if vim.b[event.buf].sops_winbar then
      vim.wo[window][0].winbar = winbar
    elseif vim.wo[window].winbar == winbar then
      vim.wo[window][0].winbar = ""
    end
  end,
})
