# Architecture deepening: dependency sources, build record, project file, launch, module cache

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

An architecture review on 2026-10-31 found five places where knowledge was spread across
modules (the /improve-codebase-architecture report). The owner asked for all five to be done.

## Resolution (2026-10-31)

- **A. Dependency sources (`src/sources.zig`, new).** It takes over `handleSetup`'s dependency
  collection (`collect`), `addRecord`/`AddRecord`/`persistAddedPackage`/`groupsFile`/`isPyproject`
  (`recordTarget`, `Record`, `record`), and adds `readsProjectPyproject`. The rebuild gate now
  hashes `./pyproject.toml` when the build reads it without it being the `dependency_file`: for
  `--group` with a requirements file or no dependency_file, and for `--dev`.
  - This fixes a gap: an edit to such a group never triggered a rebuild before.
  - The extra file is folded only when it applies, so other envs keep their digest. The pinned
    hash test still passes.
- **B. Build record (`src/autosetup.zig`).** The stamp functions (`readStamp`, `writeStamp`,
  `stampPath`, `addReplayGroup`, `restamp`, `computeTrackedHash`) are now private. The public
  interface is:
  - `ensureUpToDate` and `isStale`;
  - `recordSetup`, used after setup;
  - `Change` (`begin`/`replayGroup`/`finish`/`abort`), used by `add`, `addByRebuild` and `rename`;
  - `builtWith`, the flags of the last build.

  `flagTokens` moved to `cli.Flags.buildTokens`. The hash takes the stamp's groups and `--dev`
  into account (`Build`, `buildOf`).
- **C. Project file (`validation.load`, `validation.ProjectFile`).** These replace
  `validateAndParse`, autosetup's `loadConfigQuiet`/`Loaded`, and commands' `readEnvJson`/`EnvEntry`.
  `.quiet` serves the gate and `pythonDisabled`; `.loud` serves setup, register, validate,
  `__build` and add.
  - Setup now reads zenv.json once: the stamp hashes the content it loaded.
  - `manifest.ZenvJson` stays as the text-preserving editor.
- **D. Launch (`src/launch.zig`, new).** `start`/`Mode`/`containerOf`/`environ` were
  `execInEnv`/`Launch`/`containerOf`/`directEnv` in commands.zig. The private helpers and the
  `buildRunArgv` tests moved with them.
- **E. Module cache.** `envspec.ModuleCache.defect`/`unfitFor` now hold the replay-validity rule.
  The setup reuse check, `Spec.usableModuleCache` and `directReason` all go through them.

**Behavior changes, both documented in the README:**
1. `zenv add` refuses before installing when zenv.json is missing, invalid, or lacks the env.
   Before, it installed the package and then failed to record it.
2. The gate watches `./pyproject.toml` in the cases above. An env that an older zenv built with
   `--group`/`--dev` from such a file rebuilds once (checked: an env without groups does not).

**Verification:**
- 184 → 191 unit tests, all passing; `zig fmt --check` is clean.
- A 72-step e2e transcript (scratch script; isolated ZENV_DIR/HOME; paths, ids and durations
  normalized) was diffed between the HEAD binary and the new one. It is identical except for the
  two behavior changes above (steps 37 and 48).
- An env set up by the HEAD binary does not rebuild under the new one.
- Not exercised end to end on macOS: the container `add` path (no apptainer) and module-cache
  replay (no Lmod). Those are covered by unit tests and compilation only.

**Lines:** commands.zig went from 2924 to 2413.

**Also added:** CONTEXT.md, with the domain terms these modules are named after.
