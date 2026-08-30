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

`MANIFEST` is the list of record. It has six entries, not four:

| Source | Destination in each plugin | Mode |
| --- | --- | --- |
| `core.vim` | `autoload/<plugin>/core.vim` | verbatim |
| `install-common.sh` | `install-common.sh` | verbatim, skipped for `simpleclipboard` |
| `tests/vim_core.vim` | `tests/vim_core.vim` | `@PLUGIN@` substituted |
| `tests/defcompile.vim` | `tests/defcompile.vim` | verbatim |
| `tests/fake_daemon.py` | `tests/fake_daemon.py` | verbatim |
| `Makefile.footer` | the tail of `Makefile` | `@PLUGIN@` substituted, spliced |

`core.vim` is namespace-agnostic: the install path alone decides whether it is
reached as `simplegit#core#Ensure()` or `simpletree#core#Ensure()`, which is
why the file itself never varies.

`Makefile.footer` is the odd one. Its destination is a *fragment* — the tail of
a file each plugin also owns — so it cannot be a whole-file `sha256sum -c`
record. It is vendored in `footer` mode: vendor.sh replaces everything from the
`# simplecore:` banner down and leaves the plugin's own targets above it
untouched, and records the fragment as `footer <lines> <sha256>  <path>`, which
`core-verify` checks against that many trailing lines. Before that record
existed it was the one bundle member copied by hand and hashed by nothing.

The bundle is therefore *not* byte-identical in every plugin: `simpleclipboard`
is `SKIP`ped for `install-common.sh` and carries five members rather than six,
and the `Makefile` footer differs by the plugin name substituted into it.

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

Bumping the version and re-vendoring are one step, not two. The gap between
them is invisible to every plugin's gate: `make core-verify` compares a plugin
to the manifest sitting beside it, so ten carriers stuck on the previous
version all pass, all print `simplecore: bundle vN verified`, and nothing says
`N` is stale. It has already happened once — the bundle went to VERSION 5 and
all ten carriers stayed on 4 for the length of an audit, with every repository
green. Finish an edit with `./vendor.sh` and then `./vendor.sh --check`, and
only treat the round as closed when the check is silent.

Run the repository-level checks before vendoring a new bundle:

```sh
tests/test_bundle.sh          # shell/Python/Vim checks and drift/escape guards
tests/test_install_common.sh  # host-target build and atomic-install contract
```

The same checks run in CI. The installer deliberately overrides Cargo's target
and target directory so it can only install the named daemon built for the
current rustc host; a failed self-test leaves the existing daemon untouched.

## If this directory is lost again

It is reconstructible, but only from the list above — copy the wrong number of
files out and `vendor.sh` will regenerate every plugin's manifest without the
missing member, which silently *unpins* it everywhere. That is how
`Makefile.footer` came to be unhashed in the first place.

Recover it like this, from any plugin that carries the bundle:

1. `MANIFEST` first, from the table above, `SKIP` line included. It is the only
   file that says what the bundle is.
2. `autoload/<plugin>/core.vim` → `core.vim`,
   `tests/defcompile.vim` and `tests/fake_daemon.py` → `tests/`, verbatim.
3. `tests/vim_core.vim` → `tests/vim_core.vim`, re-templated: replace that
   plugin's name with `@PLUGIN@`.
4. `install-common.sh` from any plugin *except* `simpleclipboard`, which keeps
   its own.
5. The tail of that plugin's `Makefile`, from the `# ---` rule above the
   `# simplecore:` banner to the end of the file → `Makefile.footer`, with the
   plugin's name replaced by `@PLUGIN@`.
6. `./vendor.sh --check` — every plugin should report no drift. Any that does
   was the one that had drifted, or the copy you rebuilt from was.

The default branch is `master`, which is what `git clone` checks out. `main`
exists and is behind it; re-vendoring from a `main` checkout reintroduces the
macOS bash-3.2 and BSD-chmod regressions in `install-common.sh` across nine
plugins. Check `git log --oneline -1` before vendoring from a fresh clone.

## What `core-verify` does not prove

Each plugin's `make core-verify` compares that plugin's files to that plugin's
own `.simplecore.manifest`. That is internal consistency: a hand-edited copy
fails the build in the repository where it was edited, with no need for this
directory to be present. It is not freshness. A plugin that misses a re-vendor
keeps verifying its own stale copy and stays green for ever.

`./vendor.sh --check` is the only thing that compares a plugin against
upstream, and nothing in any plugin's `check` target runs it — `check` cannot
depend on it without making this repository a build dependency of every plugin,
which is the coupling the vendoring exists to avoid. `make core-fresh` in a
plugin runs it when this directory is checked out and says so when it is not;
running `./vendor.sh --check` here, over the whole suite, is the real answer.
