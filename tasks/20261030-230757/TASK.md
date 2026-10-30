# JSONC comments in zenv.json

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

`zenv.json` should accept `//` line and `/* */` block comments (JSONC). JSON itself has none, and the
`"_comment"` trick fails because zenv rejects unknown keys.

- Readers (validation, position map, auto-setup hash, `readEnvJson`) parse the file with comments blanked
  to spaces, so byte offsets, lines and columns stay as written.
- Writers that re-serialized the file (`zenv add --zenv`, `zenv init` into an existing file, `zenv rename`)
  must edit the text instead, or they would drop the comments.
- Comments only: no trailing commas or other JSON5 syntax.

## Resolution (2026-10-31)

- `src/jsonc.zig` (new): `strip` blanks comments to spaces (newlines kept, strings untouched, an unclosed
  `/*` left for the parser to report); `root`/`members`/`items` give value spans; `append` adds an entry
  keeping the container's layout (own line with the last entry's indent, after any comment on that line);
  `apply` writes an `Edit`. Unit tests for each.
- Readers strip first: `validation.loadConfig` and `buildPositionMap` (error positions and context lines are
  the file's own, comments included), `autosetup.foldEnvConfig` (a comment-only edit keeps the hash, so no
  rebuild), `commands.readEnvJson`.
- Writers are text edits now, via `manifest.ZenvJson`: `addToZenvJson` (replace the spec, append to the
  array, or add the key), `addEnvToZenvJson` (copies the env's text from the init template, re-indented to
  the file's indent unit), and rename's `updateLocalConfigs` (rewrites only the top-level key).
  `manifest.writeJson` is gone; untouched parts of the file stay byte for byte.
- Tests: comment cases in validation, autosetup and manifest. End to end on macOS: `init`, comments
  added, `validate`, `setup`, `add six`, a trailing comment (no rebuild), `rename`, `init` of a second
  env; all kept the comments. An unclosed `/*` is reported at its line.
- Docs: README (Features, Configuration Reference, help copy), `zenv help`.
