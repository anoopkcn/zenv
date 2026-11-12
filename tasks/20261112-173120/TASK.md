# add `zenv python unpin` to remove the pinned Python

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

`zenv python pin <version>` had no inverse. The only way to remove the pin was to delete `$ZENV_DIR/default-python` by hand.

## Resolution (2026-11-12)

`zenv python unpin` deletes `$ZENV_DIR/default-python`. It prints `Unpinned Python <version>`, or `No Python is pinned` when there is no pin, and exits 0 in both cases. It does not uninstall the Python or touch environments already built with it.

- `src/python.zig` has the new `unpin` function, next to `pinnedPath`.
- `src/commands.zig` dispatches `unpin` in `handlePython` and lists it in the "Available subcommands" messages.
- `src/main.zig` and `README.md` list it in the command reference, and the README section on zenv-managed Pythons gets one paragraph on it.

It was checked by hand against a scratch `ZENV_DIR` with a fake install: unpin with no pin, pin, `python ls` showing `(pinned)`, unpin, and `python ls` without the mark. `zig build test` passes. No unit test was added, because `pin` has none either.

The undocumented `zenv python use <version>` alias for `pin` was removed in the same change, in `handlePython` in `src/commands.zig`. `zenv python use` now fails with "Unknown subcommand".
