# Ship ReleaseSafe stripped binaries instead of ReleaseSmall

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

CI released ReleaseSmall builds (`zig build release-small`, assets `zenv-<arch>-<os>[-musl]-small.tar.gz`).
Question: is that the best mode to ship?

## Findings (checked 2026-10-30)

Built every mode on macOS (native and cross to x86_64-linux-musl), stripped them with llvm-strip, and timed
`zenv ls --all` with hyperfine (300 runs):

| Mode | Linux musl stripped | gz | macOS gz | `ls --all` |
|---|---|---|---|---|
| ReleaseSmall | 1.09 MB | 469 KB | 466 KB | 2.09 ms |
| ReleaseSafe | 2.07 MB | 847 KB | 789 KB | 2.26 ms |
| ReleaseFast | 2.38 MB | 909 KB | 819 KB | 2.32 ms |

All three run at the same speed: the time is process startup, and zenv is I/O and subprocess bound. ReleaseFast
gains nothing. ReleaseSmall turns off runtime safety checks (bounds, overflow, `unreachable`, union tags), so a bug
becomes undefined behavior in a tool that writes `registry.json`/`zenv.json` and deletes env directories.
ReleaseSafe stops on a panic instead, for ~380 KB more per download. Unstripped ReleaseSafe is ~12 MB on Linux
(debug info), so it has to be stripped.

## Resolution (2026-10-30)

- `build.zig`: one release mode. `releaseArchive` builds ReleaseSafe with `.strip = true`; the `release-small`
  and `release-<target>-small` steps and the ReleaseFast archives are gone. Steps are now `release` and
  `release-{linux-x64,linux-arm64,macos-x64,macos-arm64}`. Archive names lost the `-small` suffix:
  `zenv-<arch>-<os>[-musl].tar.gz`. The local `-Dsmall-release`/`-Drelease-safe` options are unchanged.
- `.github/workflows/release.yml` runs `zig build release`; the Homebrew `sed` lines use the new names.
- `.github/templates/zenv.rb`, `install.sh`, `README.md` (manual download) use the new names;
  `.github/workflows/tip.yml.disabled` runs `zig build release`.
- Built with `zig build release -Dforce-release=true`: archives 692-759 KB, binaries 1.5-1.8 MB (smaller than
  llvm-strip's result since `.strip` drops more at link time); ELF ones are reported stripped. The macOS arm64
  binary runs (`--version`, `ls --all`); `zig build test` passes. The Linux binaries were not run (no Docker
  daemon at the time).
- Install path note: `install.sh` on main looks up the new names in the latest release, so between pushing this
  commit and the tag's release job finishing, a fresh `install.sh` run cannot find its asset.
