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
4. **Filters** — a sub-transient for global and per-backend filter rules.

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
 g GPTel   backend=OpenAI model=gpt-4o  u Update all       -o Overwrite meta (on/off)
 1 Fast    backend=... model=...        b Update backend
 2 Vision  backend=... model=...        a Select all       Filters
                                        q Quit               f Filters...
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

- `-o` toggle `gptel-model-updater-metadata-overwrite-existing`

### Filters sub-transient (`f`)

A dedicated sub-transient, `gptel-model-updater-transient-filters`,
reached with `f` from the main menu. It holds the global filter infixes
plus one row per managed backend.

Global infixes (read current value, empty input clears to nil, `setq`
the defcustom):

- `-s` toggle `gptel-model-updater-sort-models`
- `-i` set `gptel-model-updater-include-model-regexp` (regexp or nil)
- `-x` set `gptel-model-updater-exclude-model-regexp` (regexp or nil)
- `-m` set `gptel-model-updater-max-models` (integer or nil)

Per-backend rows: one row per backend in `gptel-model-updater-backends`,
keyed `1`, `2`, ..., each showing that backend's current effective
include/exclude/max. Selecting a row opens a nested per-backend
sub-transient.

### Per-backend filter sub-transient

`gptel-model-updater-transient-backend-filter`, generated for a chosen
backend name. Infixes write into that backend's plist inside the
`gptel-model-updater-backend-filters` alist (creating the entry if
missing, removing a key when cleared to nil):

- `-i` `:include` regexp
- `-x` `:exclude` regexp
- `-m` `:max` integer

A helper `gptel-model-updater--set-backend-filter (name key value)`
updates the alist and `setq`s `gptel-model-updater-backend-filters`.
Omitted/nil keys fall back to the global values, matching existing
semantics.

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
4. `gptel-model-updater--set-backend-filter` adds, updates, and removes
   keys in `gptel-model-updater-backend-filters` correctly.

Transient key interaction is not unit-tested; helper functions are.

## Non-goals

- No change to existing interactive commands.
- No new persistence of option state beyond the existing defcustoms.
- No timeout / hook infixes (rarely changed mid-session).
