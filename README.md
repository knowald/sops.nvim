# sops.nvim

Edit SOPS-encrypted files in Neovim. Opening a `*.sops.yml`, `*.sops.yaml`,
`*.sops.json`, `*.sops.env` or `*.sops.ini` file shows the decrypted contents,
and `:w` encrypts them back to disk.

Writes go through `sops edit`, so values that did not change keep their
ciphertext. A diff shows the values you touched plus the `lastmodified` and
`mac` fields. Recipients and `encrypted_regex` come from the metadata stored in
the file, the same as with `sops edit` on the command line.

## Requirements

- Neovim 0.10 or newer
- `sops` 3.10 or newer on `PATH`, able to decrypt the file without prompting

## Installation

With lazy.nvim:

```lua
return {
  "knowald/sops.nvim",
  lazy = false,
}
```

There is nothing to configure.

## Behavior

- The winbar shows whether the window holds decrypted or encrypted contents.
- `:SopsToggle` switches the buffer between the decrypted contents and the
  file as it is stored. The encrypted view is read-only. The switch is refused
  while the buffer has unsaved changes.
- Lines whose value is encrypted in the stored file carry an
  `encrypted on disk` annotation at the end of the line. It is virtual text,
  not part of the buffer. A line without it is stored as you see it: comments,
  keys that do not match `encrypted_regex`, and lines added since the last
  write. The annotations are matched to lines by the text in front of the
  value, so they are a guide, not a guarantee.
- A decrypted buffer can only be written back to the file it was read from.
  Range writes, `:w >>`, `:w other-name` and `:saveas` are refused, so the
  plaintext does not reach disk through Neovim.
- If the file changed on disk after it was read, `:w` is refused. Reload with
  `:e`, or overwrite with `:w!`.
- If SOPS rejects a write (invalid syntax, for example), the file on disk is
  left alone and the buffer stays modified.
- After a write the buffer shows the contents as SOPS normalized them (blank
  lines removed, for example).
- If decryption fails, the buffer shows the encrypted file read-only.
- New encrypted files are not created from Neovim. Create them with
  `sops encrypt` or `sops edit` first.
- Decrypted buffers have no swap file and no persistent undo file, and ignore
  modelines.
- The `clipboard` option is cleared while a decrypted buffer is current, so
  yanks and deletes stay out of the system clipboard. Use the `"+` register to
  copy on purpose.
- The buffer has `buftype=acwrite`. Git signs and language servers do not
  attach to it, and format-on-save does not run.

## What is not covered

- Yanked text, search patterns and command-line history from a decrypted
  buffer are stored in ShaDa like any other.
- Completion sources that read open buffers can offer words from a decrypted
  buffer elsewhere.
- `:w !command` and filters send the plaintext to that command.
- During a write SOPS keeps the plaintext in a temporary file readable only by
  you. It removes the file when it exits, but not when it is killed.
- SOPS replaces the encrypted file in place, not atomically. A full disk during
  that step can truncate it.
- Keys that do not match the file's `encrypted_regex`, and all comments, are
  stored unencrypted. That is how SOPS partial encryption works.

## Tests

```sh
nvim --headless -u NONE -l tests/roundtrip.lua
```

Needs `sops` and `age-keygen`. The test uses a throwaway key in a temporary
directory.
