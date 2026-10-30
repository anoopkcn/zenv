# uv reinstalls module-provided packages pulled in as transitive dependencies

- STATUS: CLOSED
- PRIORITY: 100
- TAGS:

With uv, setup skips a module-provided package only when it is a direct requirement
(`planInstall`, src/envbuild.zig). uv runs without PYTHONPATH and ignores packages outside the
venv, so a module package that a dependency pulls in is installed again into the venv. Example:
`maybe_jureca` on JURECA (modules PyTorch/2.9.1) lists `torch` (excluded) and
`sentence-transformers` (needs torch), and ends up with torch 2.14.1+cu130 in the venv:
12,660 inodes, and resolved against a torch the module's PYTHONPATH entry shadows at runtime.
`zenv add` has the same gap. pip is not affected: it keeps PYTHONPATH and sees module packages.

Checked locally (uv 0.13.6): `uv pip install` into a `--system-site-packages` venv also
reinstalls everything the base interpreter has, even an exact pin match. What works: resolve
with the provided packages pinned as constraints (`uv pip compile -c provided.txt`), drop them
from the result, install the rest with `--no-deps`. A conflicting requirement then fails
resolution with uv's explanation. This is also the mechanism the planned Apptainer support
needs (image-provided packages).

## Findings (checked 2026-10-30)

Pinning the module versions as plain constraints fails on real modules: EasyBuild packages carry
local versions that no index has (JURECA PyTorch/2.9.1 reports `torch 2.9.1+cu128`), so
`torch==2.9.1+cu128` is unsatisfiable. uv resolves them when it finds the pinned versions as stub
wheels (core metadata with Name and Version only) in a `--find-links` directory. The stubs carry no
Requires-Dist on purpose: a module package counts as complete as installed (as pip treats an
installed package), and uv adds nothing the module's metadata names but the module does not ship.

## Resolution (2026-10-30)

src/envbuild.zig: with uv and module packages on PYTHONPATH (and no --force), setup writes the
requirements, constraints (`pinnable`/`constraintLines`) and stub wheels (`stub_script`, written by
the venv's Python), runs `uv pip compile -c ... --find-links ...`, drops the module packages from
the result (`splitResolved`) and installs the rest with `uv pip install --no-deps`
(`installAgainstProvided`). A requirement needing another version of a module package fails setup
with uv's explanation and a pointer to --force. Without modules, with pip, or with --force the
install is unchanged.

`zenv add` (src/commands.zig `installPackage`) does the same through `envbuild.addWithModules`,
resolving the package together with the venv's record `<venv>/requirements.txt`, which `add` now
keeps current (`recordAdded`). It uses the direct-launch environment (`directEnv`, split out of
`execDirect`); when activate.sh is needed instead, add falls back to the plain `uv pip install`.

Checked:
- unit tests for pinnable/constraintLines, splitResolved, compileArgv, recordAdded (`zig build test`).
- fake Lmod module locally (idna 3.6+eb, packaging 24.0): `requests` no longer installs idna;
  a transitive `packaging>=25` fails with uv's report; `--force` installs everything; `zenv add build`
  reuses packaging and idna.
- JURECA, Stages/2026 + GCCcore/14.3.0 + PyTorch/2.9.1, dependency `sentence-transformers`:
  13 module packages reused (torch 2.9.1+cu128, numpy, scipy, ...), 17 installed, venv 5,406 inodes;
  zenv v0.30.0 on the same zenv.json installs torch into the venv, 29,749 inodes. The env imports
  sentence-transformers 6.2.0 with the module's torch.

README: paragraph after the uv/pip comparison in the installer section.
