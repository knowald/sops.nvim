-- Run from the repository root: nvim --headless -u NONE -l tests/roundtrip.lua
-- Needs sops and age-keygen. Uses a throwaway key in a temporary directory.
-- Headless nvim raises error-level notifications as Lua errors, so a refused
-- operation shows up as a failed pcall.

local directory = vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h")) .. "/sops-test"
vim.fn.delete(directory, "rf")
vim.fn.mkdir(directory, "p")
local file = directory .. "/test.sops.yml"
local key_file = directory .. "/key.txt"
local modeline = "# vim: set swapfile undofile:"

local function shell(command)
  local result = vim.system(command, { text = true, cwd = directory }):wait()
  assert(result.code == 0, table.concat(command, " ") .. ": " .. result.stderr)
  return result.stdout
end

local function ciphertext(key)
  for _, line in ipairs(vim.fn.readfile(file)) do
    if vim.startswith(line, key .. ":") then
      return line
    end
  end
  error("no line for " .. key)
end

local function buffer_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function decrypted()
  return shell({ "sops", "decrypt", file })
end

local function marked_rows()
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("sops"), 0, -1, {})) do
    table.insert(rows, mark[2])
  end
  return rows
end

local function refused(command, description)
  local on_disk = vim.fn.readfile(file)
  assert(not pcall(vim.cmd, command), description .. " reports an error")
  assert(vim.deep_equal(vim.fn.readfile(file), on_disk), description .. " leaves the file alone")
end

shell({ "age-keygen", "-o", key_file })
local recipient = shell({ "age-keygen", "-y", key_file }):gsub("%s+$", "")
vim.fn.writefile({
  "creation_rules:",
  "  - path_regex: .*\\.sops\\.yml$",
  "    age: " .. recipient,
  '    encrypted_regex: "^(.*password.*)$"',
}, directory .. "/.sops.yaml")
vim.fn.writefile({ "first_password: alpha", "second_password: beta", "plain: visible", modeline }, file)

vim.env.SOPS_AGE_KEY_FILE = key_file
vim.env.SOPS_AGE_SSH_PRIVATE_KEY_FILE = nil
shell({ "sops", "encrypt", "-i", file })

vim.cmd("filetype on")
vim.o.clipboard = "unnamedplus"
vim.cmd.source("plugin/sops.lua")

-- Read
vim.cmd.edit(file)
assert(vim.deep_equal(buffer_lines(), { "first_password: alpha", "second_password: beta", "plain: visible", modeline }), "decrypts on read")
assert(vim.bo.filetype == "yaml", "detects filetype, got " .. vim.bo.filetype)
assert(not vim.bo.modified, "unmodified after read")
assert(not vim.bo.swapfile and not vim.bo.undofile, "no swap or undo file, even with a modeline asking for them")
assert(vim.o.clipboard == "", "system clipboard is off in a decrypted buffer")
assert(vim.deep_equal(marked_rows(), { 0, 1 }), "marks the lines that are encrypted on disk")
assert(vim.wo.winbar ~= "" and vim.b.sops_winbar:find("SOPS decrypted", 1, true), "winbar shows the decrypted state")
vim.cmd("silent! undo")
assert(#buffer_lines() == 4, "undo does not empty the buffer")

-- Write
local first_before = ciphertext("first_password")
local second_before = ciphertext("second_password")
vim.api.nvim_buf_set_lines(0, 1, 2, false, { "second_password: changed" })
vim.cmd.write()
assert(not vim.bo.modified, "unmodified after write")
assert(ciphertext("first_password") == first_before, "unchanged value keeps its ciphertext")
assert(ciphertext("second_password") ~= second_before, "changed value is encrypted again")
assert(not ciphertext("second_password"):find("changed", 1, true), "no plaintext on disk")
assert(decrypted() == "first_password: alpha\nsecond_password: changed\nplain: visible\n" .. modeline .. "\n", "write round trips")

local on_disk = vim.fn.readfile(file)
vim.cmd.write()
assert(vim.deep_equal(vim.fn.readfile(file), on_disk), "writing without changes leaves the file alone")

-- sops drops the blank line; the buffer follows so the next write is a no-op.
vim.api.nvim_buf_set_lines(0, 1, 1, false, { "" })
vim.cmd.write()
assert(#buffer_lines() == 4, "buffer shows the normalized contents after write")
on_disk = vim.fn.readfile(file)
vim.cmd.write()
assert(vim.deep_equal(vim.fn.readfile(file), on_disk), "normalized buffer does not rewrite the file")

-- Refused writes
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "first_password: [" })
refused("write", "invalid syntax")
assert(vim.bo.modified, "stays modified after rejected write")

vim.api.nvim_buf_set_lines(0, 0, 1, false, { first_before })
refused("write", "ciphertext in the buffer")
vim.cmd("edit!")

refused("1,2write! " .. file, "range write")
refused("write >> " .. file, "append write")
refused("write " .. directory .. "/plain.yml", "write to another name")
assert(not vim.uv.fs_stat(directory .. "/plain.yml"), "no plaintext copy is created")

-- File changed on disk after it was read
shell({ "sops", "set", file, '["plain"]', '"external"' })
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "first_password: mine" })
refused("write", "write over a newer file")
vim.cmd("write!")
assert(decrypted():find("first_password: mine", 1, true) and not decrypted():find("external", 1, true), ":w! overwrites the newer file")
on_disk = vim.fn.readfile(file)

-- Leaving the buffer
vim.cmd.enew()
assert(vim.wo.winbar == "", "winbar is removed when the window shows another buffer")
assert(vim.o.clipboard == "unnamedplus", "clipboard option is restored outside the buffer")
vim.cmd("bwipeout!")
vim.cmd.buffer(vim.fn.bufnr(file))

-- Reload while decryption fails, then again once it works
vim.env.SOPS_AGE_KEY_FILE = directory .. "/missing.txt"
assert(not pcall(vim.cmd, "edit!"), "failed decrypt reports an error")
assert(vim.deep_equal(buffer_lines(), on_disk), "shows ciphertext when decrypt fails")
assert(vim.bo.readonly and not vim.bo.modifiable, "ciphertext is read-only")
assert(vim.b.sops_winbar:find("decrypt failed", 1, true), "winbar shows the failed decrypt")
refused("write!", "write of an undecrypted buffer")
vim.env.SOPS_AGE_KEY_FILE = key_file
vim.cmd("edit!")
assert(buffer_lines()[1] == "first_password: mine" and vim.bo.modifiable and not vim.bo.readonly, "reload recovers once decrypt works")

-- Marks follow what is encrypted on disk after a write
vim.api.nvim_buf_set_lines(0, 3, 3, false, { "tls_key: unprotected", "third_password: gamma" })
vim.cmd.write()
assert(vim.deep_equal(marked_rows(), { 0, 1, 4 }), "new matching key is marked, new non-matching key is not")
on_disk = vim.fn.readfile(file)

-- Encrypted view
vim.cmd.SopsToggle()
assert(vim.deep_equal(buffer_lines(), on_disk), "toggle shows the stored file")
assert(vim.bo.readonly and not vim.bo.modifiable and not vim.bo.modified, "encrypted view is read-only")
assert(#marked_rows() == 0 and vim.b.sops_winbar:find("SOPS encrypted", 1, true), "encrypted view has its own winbar and no marks")
refused("write!", "write of the encrypted view")
vim.cmd.SopsToggle()
assert(buffer_lines()[1] == "first_password: mine" and vim.bo.modifiable, "toggle decrypts again")
assert(vim.deep_equal(marked_rows(), { 0, 1, 4 }), "marks return with the decrypted view")
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "first_password: unsaved" })
assert(not pcall(vim.cmd.SopsToggle), "toggle is refused with unsaved changes")
assert(buffer_lines()[1] == "first_password: unsaved", "refused toggle keeps the changes")
vim.cmd("edit!")

-- Other names
refused("saveas! " .. directory .. "/other.sops.yml", "saveas")
assert(not vim.uv.fs_stat(directory .. "/other.sops.yml"), "saveas creates no file")

assert(not pcall(vim.cmd.edit, directory .. "/new.sops.yml"), "missing file reports an error")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first_password: new" })
pcall(vim.cmd, "write!")
assert(not vim.uv.fs_stat(directory .. "/new.sops.yml"), "missing file is not created as plaintext")

vim.fn.delete(directory, "rf")
print("ok\n")
