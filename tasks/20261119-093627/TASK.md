# Rename setup --dev to --editable with -e shorthand

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

`zenv setup --dev` installed the project editable, while `zenv add --dev` and `zenv remove --dev` mean `--group dev`. One flag with two meanings was confusing, so the setup flag is renamed to `--editable` with the shorthand `-e`, matching `pip install --editable`/`-e`. Backward compatibility is not kept.

## Resolution (2026-11-19)

- `src/cli.zig`: new flag `--editable` (field `editable`), and `flagOf()` maps the alias `-e` to it for parsing, `unknownFlag` and `positional`. The `--dev` field is now `dev_group` and only `add` and `remove` accept it. The build record writes `--editable`. New test "-e is --editable, and --dev is not".
- `src/commands.zig`, `src/envbuild.zig`, `src/autosetup.zig`, `src/sources.zig`: renamed the setup uses and messages from `--dev` to `--editable`.
- `src/help.zig`: setup lists `-e, --editable`. The note on `add --dev` about the two meanings is gone.
- `zenv setup <name> --dev` now fails with "Unknown option '--dev' for 'zenv setup'". An env set up with `--dev` by an older zenv has `--dev` in its build record, so its next automatic rebuild fails the same way until it is set up again with `-e` (checked with a hand-edited stamp: `zenv run` exits 1 with that error).
- Tested: `zig build test` passes. In a scratch `ZENV_DIR`, `zenv setup eproj --init --uv -e` installed a hatchling project editable (`eproj.__file__` points into `src/`), the stamp recorded `["--editable", "--uv"]`, and `zenv setup eproj --uv --dev` was refused.
