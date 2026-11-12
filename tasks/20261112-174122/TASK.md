# add per-command help: `zenv help <command>` and `zenv <command> --help`

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

The help was one string in `printUsage` in `src/main.zig`, so there was no way to see the help of one command. `zenv python --help` reported an unknown subcommand, and only `zenv init --help` had a text of its own.

## Resolution (2026-11-12)

The help text moved to the new `src/help.zig`, which holds one topic per command: its synopsis, its entry in the overview, and its options section if it has one. `zenv help` is built from the topics at compile time, so the overview and the per-command help share one source.

- `zenv help <command>`, `zenv <command> --help` and `zenv <command> -h` print the help of one command. `zenv -h` is now accepted for the overview.
- The bare word `help` works after `alias`, `jupyter` and `python` only. After the other commands that position is an environment name, so `zenv setup help` still means the env named "help".
- The help flag is honored anywhere in the arguments, except for `run`, where only the first argument is checked. `zenv run <env> pytest --help` still passes `--help` to pytest.
- `dispatch` in `src/main.zig` checks `help.requested` before calling a handler, so no handler parses help flags. The special case in `handleInit` and its `init_usage` text in `src/commands.zig` are gone.

The overview changed in two places only: the `init` entry gained the line on the default description (it was in `init_usage` before), and the `help` entry describes the new forms. This was checked with a diff of `zenv help` before and after. The help block in `README.md` matches the new output.

`src/help.zig` has two unit tests, registered in `src/test_root.zig`: one for `requested`, and one that every public command has a topic. `zig build test` passes with 194 tests.
