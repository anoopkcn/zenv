# Pick uv automatically, pip as fallback, --pip to force pip

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

Setup and `zenv add` used pip unless `--uv` was given. Make uv the default when it is on PATH, fall back to pip
otherwise, and let `--uv` / `--pip` force either.

## Resolution (2026-10-24)

- `src/utils/flags.zig`: new `--pip` flag (`use_pip`), `CommandFlags.installer()` -> `Installer{auto,uv,pip}`,
  and `conflict()`; `commands.checkFlags` refuses `--uv` with `--pip`. Both flags are in `SETUP_FLAGS`/`ADD_FLAGS`.
- `src/utils/envbuild.zig`: `resolveUv(c, installer)` is the one place the backend is chosen (zenv's own PATH,
  before modules load): `pip` -> null, `uv` -> path or error, `auto` -> path or null with an info line.
  `run` and `installEditable` now branch on `opts.uv != null` instead of `flags.use_uv`.
- `zenv add` (`src/commands.zig`): `addInstaller` = own flag, else an explicit `--uv`/`--pip` in the env's
  `.zenv.stamp`, else auto. `installPackage` takes the resolved uv path.
- `src/utils/autosetup.zig`: `flagTokens` records `--pip` too, and only explicit choices; an auto env re-detects
  on every rebuild.
- Help text (`src/main.zig`) and README (help copy, `zenv add` flags, rebuild flags, new installer paragraph in
  "Initialize and setup").
- Behavior change: envs built without `--uv` switch to uv on their next rebuild when uv is on PATH. uv builds with
  isolation and without the module `PYTHONPATH`, so module-provided build deps are not seen; `--pip` keeps pip.
- Verified: `zig build test`; end-to-end in a scratch ZENV_DIR: auto+uv, `--pip` (stamped, honoured by a bare
  `add`), auto without uv (pip fallback), `--uv` without uv (exit 1), `--uv --pip` (refused), `add --uv` override.
