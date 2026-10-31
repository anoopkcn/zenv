# zenv domain language

Terms the code and design discussions use, with the module that owns each.

**Project file**
A project's `zenv.json`, read and validated once (`validation.load`): its text and the
`config.Project` it builds. `.quiet` for callers that must keep working while it is missing
or mid-edit (the rebuild gate), `.loud` everywhere else.
_Avoid_: config file, manifest (a manifest is where packages are recorded).

**Env**
One top-level entry of the project file, and the directory setup builds for it.

**Dependency sources** (`sources.zig`)
The project files an env's packages come from: zenv.json `dependencies`/`dev_dependencies`,
the `dependency_file`, `--group` dependency groups, and `./pyproject.toml` for `--dev`.
Owns what setup installs, which of these files the rebuild gate watches, and where
`zenv add` records a package.

**Manifest**
A file `zenv add` records a package in: zenv.json, a requirements file, or a pyproject.toml.

**Build record** (`autosetup.zig`)
What an env was last built from: a hash of its tracked files and the setup flags to replay,
kept in `<env>/.zenv.stamp`. Only autosetup reads or writes it.

**Rebuild gate**
The check `run`, `activate`, `cd` and `jupyter create` make first: when the build record no
longer matches, setup runs again (as a subprocess, with the recorded flags).

**Change**
A command changing an env's tracked files itself (`add`, `rename`). An env that was up to date
when the change began is re-recorded at its end, so it does not rebuild.

**Launch** (`launch.zig`)
Starting a command inside an env: directly with `zenv-env.json` applied, through
`activate.sh`, or in the env's container image.

**Module cache**
The environment `module load` produced at setup, replayed instead of running Lmod again.
Whether it may be replayed is decided by `envspec.ModuleCache.defect`/`unfitFor`.
