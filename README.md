# simplecore

The daemon supervisor shared by the `simple*` Vim plugin suite, plus the test
harness that exercises it.

## Why it is copied, not shared

Each plugin is its own git repository and has to work when it is the only one
installed, so nothing may reference a sibling directory at runtime. The bundle
is therefore *vendored*: every plugin carries a copy under its own namespace.

Copies drift. Guarding against that is the whole point of the tooling here —
the previous arrangement had no guard at all, and this directory itself went
missing without a single build noticing.

## Layout

| Source | Destination in each plugin | Mode |
| --- | --- | --- |
| `core.vim` | `autoload/<plugin>/core.vim` | verbatim |
| `tests/vim_core.vim` | `tests/vim_core.vim` | `@PLUGIN@` substituted |
| `tests/defcompile.vim` | `tests/defcompile.vim` | verbatim |
| `tests/fake_daemon.py` | `tests/fake_daemon.py` | verbatim |

`core.vim` is namespace-agnostic: the install path alone decides whether it is
reached as `simplegit#core#Ensure()` or `simpletree#core#Ensure()`, which is
why the file itself never varies.

## Workflow

```sh
./vendor.sh              # push the bundle into every sibling simple* plugin
./vendor.sh simplegit    # ...or into named plugins only
./vendor.sh --check      # report drift, write nothing, exit 1 if any
```

`vendor.sh` looks for the plugins beside this directory — the usual layout is
this repository cloned as `.simplecore` inside the plugin directory:

```sh
git clone https://github.com/beamiter/simplecore ~/.vim/plugged/.simplecore
```

Cloned anywhere else, point it at the plugins instead:

```sh
SIMPLECORE_SUITE=~/.vim/plugged ./vendor.sh --check
```

With no plugin named, it only targets sibling `simple*` directories that are
git repositories *and* already carry a `.simplecore.manifest`. Onboarding a new
plugin means naming it explicitly the first time.

Bump `VERSION` in `MANIFEST` whenever a source file changes. `vendor.sh`
stamps the version and a sha256 per file into each plugin's
`.simplecore.manifest`, which that plugin's `make core-verify` checks — and
`check` depends on it, so a hand-edited copy fails the build in the repository
where it was edited, with no need for this directory to be present.

## If this directory is lost again

It is reconstructible: the bundle is byte-identical in all ten plugins, so
copy the four files out of any one of them, re-template `tests/vim_core.vim`
by replacing that plugin's name with `@PLUGIN@`, and re-run `./vendor.sh` —
every plugin should report *up to date*. Any that does not was the one that
had drifted.
