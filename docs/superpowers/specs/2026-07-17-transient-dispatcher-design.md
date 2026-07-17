# Transient Dispatcher for gptel-model-updater

## Goal

Add a Magit-style transient popup as the interactive front end for
`gptel-model-updater`. Users pick a model/provider for each target
variable, run updates, and toggle the tunable options from one menu.
Delivered as a new file, `gptel-model-updater-transient.el`, that is
purely additive: the existing `completing-read` commands stay as-is.

## Scope

Full dispatcher covering three concerns:

1. **Targets** — the default GPTel target (`gptel-backend` /
   `gptel-model`) plus every entry in
   `gptel-model-updater-external-targets`.
2. **Update** — `update-all`, `update-backend`, `select-all-targets`.
3. **Options** — infixes for the tunable defcustoms.

## New file

`gptel-model-updater-transient.el`

- `(require 'transient)`, `(require 'gptel-model-updater)`.
- The core file keeps no transient dependency; only this file needs it.

## Entry point

- `gptel-model-updater-transient` — autoloaded transient prefix.
- `gptel-model-updater-menu` — alias.

The Targets group is built dynamically each time the menu opens so newly
configured external targets appear without recompiling. Implemented with
a transient whose Targets group uses `:setup-children`, returning one
suffix per target.

## Layout

```
GPTel Model Updater

Targets                                Update             Options
 g GPTel   backend=OpenAI model=gpt-4o  u Update all       -s Sort models    (on/off)
 1 Fast    backend=... model=...        b Update backend   -m Max models     (200)
 2 Vision  backend=... model=...        a Select all       -o Overwrite meta (on/off)
                                        q Quit
```

### Targets group

- `g` selects the default GPTel target.
- `1`, `2`, ... select each external target in order.
- Each row description is produced by a function and shows the live
  `backend=NAME model=MODEL` for that variable, reusing
  `gptel-model-updater--format-default-target` and
  `gptel-model-updater--format-external-target`.
- Pressing a target key runs the existing interactive backend+model
  completion for that one target, then re-enters the transient so the
  row reflects the new selection.

### Update group

- `u` -> `gptel-model-updater-update-all`
- `b` -> `gptel-model-updater-update-backend`
- `a` -> `gptel-model-updater-select-all-targets` (non-interactive auto
  pick from configured model lists)

### Options group

Infixes read the current defcustom value and `setq` it globally when
changed (persists for the session, matches a settings popup):

- `-s` toggle `gptel-model-updater-sort-models`
- `-m` set `gptel-model-updater-max-models` (integer or nil)
- `-o` toggle `gptel-model-updater-metadata-overwrite-existing`

## Per-target selection mechanism

Add one internal command,
`gptel-model-updater--transient-select-target`, taking a target spec (or
the symbol `gptel` for the default). It dispatches to the existing
`gptel-model-updater-select-default-target` or
`gptel-model-updater--select-external-target` with `interactivep` set.
The dynamically generated suffixes close over each target.

## Reuse / no core changes

Core selection and update functions are reused unchanged. The transient
adds a new entry point only.

## Testing

Add tests to `gptel-model-updater-tests.el`:

1. The prefix `gptel-model-updater-transient` is defined
   (`transient--prefix` / command exists).
2. Target-row description formatting reflects variable values (bind
   `gptel-backend`/`gptel-model` and external target variables, assert
   the formatted strings).
3. Option infix setter functions set the corresponding defcustoms.

Transient key interaction is not unit-tested; helper functions are.

## Non-goals

- No change to existing interactive commands.
- No new persistence of option state beyond the existing defcustoms.
- No filter-regexp infixes (string regexps are awkward in a popup and
  rarely toggled mid-session).
