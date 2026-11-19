# let zenv python install pass configure options

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

Every Python that `zenv python install` built on the Mac lacked the ssl module (3.12.0, 3.13.0, 3.14.0 and 3.15.0 all fail `import ssl` with `No module named '_ssl'`). macOS ships no OpenSSL headers, and CPython's configure only looks in `/usr/local/ssl`, `/usr/lib/ssl`, `/usr/ssl`, `/usr/pkg`, `/usr/local` and `/usr` or asks pkg-config, so it does not find Homebrew's OpenSSL. The build then leaves the module out without failing, and pip cannot reach PyPI. zenv ran a fixed configure command, so there was no way to pass `--with-openssl` or any other option.

## Findings (checked 2026-11-19)

- This Mac has Homebrew's `openssl@4` (OpenSSL 4.1.0), not `openssl@3`. `brew --prefix openssl@3` prints `/opt/homebrew/opt/openssl@3` even though the formula is not installed.
- CPython 3.13.0 configured with `--with-openssl=/opt/homebrew/opt/openssl` (OpenSSL 4.1.0) passes configure, but `make` fails in `Modules/_ssl.c` with `incomplete definition of type 'ASN1_OCTET_STRING'`, because OpenSSL 4 made the ASN1 string types opaque. Detecting OpenSSL 4 would therefore turn a build without ssl into a failed build.

## Resolution (2026-11-19)

- `zenv python install [version] [-- <configure options>]` passes everything after `--` to `./configure`. An option before `--`, or a second version, is refused with a usage message.
- `ZENV_PYTHON_CONFIGURE_OPTS` adds configure options too, split on whitespace (no quoting).
- The order is zenv's defaults, a detected OpenSSL, the env var, then the `--` options. Autoconf keeps the last of a repeated option, so user options override the defaults (`--disable-optimizations` was checked to do so).
- On macOS, zenv adds `--with-openssl=<prefix>` when `opt/openssl@3` has headers under `$HOMEBREW_PREFIX`, `/opt/homebrew` or `/usr/local`, unless the user passes `--with-openssl=`. It does not use `openssl@4` (see Findings).
- The configure command is printed before it runs. After the install, zenv runs `import ssl` with the new Python and warns, with the reinstall command, when that fails.
- `help.requested` stops at `--`, so a `-h` meant for configure does not open zenv's help.
- Code: `InstallArgs`, `homebrewOpenssl`, `configureArgv` and `checkSsl` in `src/python.zig` (with unit tests for the argument parsing and order), the `install` branch of `handlePython` in `src/commands.zig`, and the `python` entry and environment variable list in `src/help.zig`.

Tested with unit tests and by building 3.13.0 into a scratch `ZENV_DIR` with options from both the env var and `--`. Not tested: a build that links `openssl@3` (not installed here), Linux, and a cluster.
