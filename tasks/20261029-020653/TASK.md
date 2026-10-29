# Install and record PEP 735 dependency groups with --group

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

pyproject.toml can define `[dependency-groups]` (PEP 735), e.g. `dev = ["pytest>=9"]`, `demo = ["openai>=1.50",
"ipykernel>=6"]`. pip installs one with `--group <name>`; zenv had no way to. Setup read only
`[project].dependencies`, so `zenv add <env> pkg --dev` recorded `pkg` in `[dependency-groups].dev` and the next
rebuild dropped it.

Decisions (with the user): `setup --dev` keeps meaning editable install; `--group <name>` is a new flag on `setup`
and `add`, and on `add` `--dev` is shorthand for `--group dev`. The chosen groups live in the build stamp (replayed
by automatic rebuilds), not in zenv.json.

## Resolution (2026-10-29)

- `src/utils/flags.zig`: `--group` takes a value (`--group dev` or `--group=dev`, repeatable). `groups()` returns
  the names, `badGroup()` the first missing/invalid one (PEP 508 name rules), `validGroupName()`. `positional` and
  `unknownFlag` skip the value; `=value` on any other flag is refused.
- `src/utils/parse_deps.zig`: `parseDependencyGroups()` appends the named groups, follows
  `{include-group = "..."}`, compares names PEP 503-normalized (`sameName()`, factored out of `samePackage`), and
  errors on a missing group (listing the defined ones), a non-array group, a bad entry or an include cycle.
- `src/commands.zig` setup: groups come from the pyproject.toml `dependency_file`, else `./pyproject.toml`
  (`groupsFile()`); refused for `"python": false`; recorded in the stamp via `flagTokens(f, groups)`.
- `src/commands.zig` add: `addGroup()` (one group; `--dev` = `dev`; no `.` in the name, since it would be a dotted
  TOML key) and `addRecord()` pick the manifest before installing, so an impossible target installs nothing.
  A non-dev group needs a pyproject.toml and is refused with `--zenv`; `--dev` keeps its old targets.
  `autosetup.addReplayGroup()` adds the group to the stamp, so rebuilds keep the package (fixes the `--dev` loss).
- `src/utils/manifest.zig`: `addToPyproject(..., group: ?[]const u8)` instead of `dev: bool`.
- `src/utils/errors.zig`: `DependencyGroupNotFound`, `InvalidDependencyGroup` are reported where raised.
- Help text (`src/main.zig`) and README (add table, new "Dependency groups" paragraph, rebuild flags) updated.
- Tests: flags (both spellings, repeats, bad names, positional), groups parsing (include, normalization,
  errors), `addReplayGroup`, `flagTokens`. `zig build test` passes. End-to-end in a scratch project:
  `setup --uv --group demo` (demo includes dev) installed both groups; `add --group docs` and `add --dev` wrote
  pyproject.toml and extended the stamp; an auto-rebuild after editing pyproject.toml kept those packages.
- Not done: a manual `zenv setup` without `--group` drops the groups (by design); `add` into a dotted group name.
