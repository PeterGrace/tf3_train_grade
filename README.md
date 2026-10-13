# Vehicle Grade and Weight (Transport Fever 3 mod)

Adds two readouts next to the speed under the camera view in a land vehicle's window (train, tram, bus or truck):
the vehicle's total weight (hover for empty and cargo weight) and the average grade under it, + when climbing.

- Mod ID: `pgrace_train_grade` (the repo and modId keep the original "train grade" name; the display name changed)
- Cosmetic: yes. It doesn't affect the simulation, so achievements stay enabled.
- Design and plan: `docs/superpowers/specs/2026-10-12-train-grade-design.md`, `docs/superpowers/plans/2026-10-12-train-grade.md`

Agent and modding notes for all mods live in `../AGENTS.md` (see "Adding to a base widget by replacing it" and the
vehicle facts under "Game data facts").

## Layout

```
mod/pgrace_train_grade/                    # the mod folder TF3 loads
├── mod.json, _metadata/                   # modinfo.json, description.html, screenshots
├── tealdef/                               # Teal type definitions (canonical; build.py mirrors them into content/)
└── content/gui/pgrace_train_grade/
    ├── speed_strip_replacement.res.lua    # replaces the base SpeedIndicator recipe with ours
    ├── speed_strip.script.tl              # UI: weight and grade pills, wrapping the original speed readout
    ├── speed_strip.css.lua                # pill styles (copied from the base speed readout)
    ├── vehicle_data.tl                    # all api.* reads: vehicle, weights, path and track heights
    ├── grade.tl                           # pure: average grade over a path span, text, icon (unit-tested)
    └── weight.tl                          # pure: weight sums (unit-tested)
tools/                                     # type check, tests, install, release checks
tests/                                     # unit tests for pure modules
```

## Dev loop

```bash
just check      # type-check against the game's API definitions
just test       # unit tests
just verify     # check + test + release-check
just install    # symlink into TF3's staging area (just install-copy to copy)
```

Restart TF3 after code changes. The log is
`~/.local/share/Steam/userdata/*/3493540/local/crash_dump/stdout.txt`; our lines start with `[train_grade]`.

## Releasing

1. Screenshots in `mod/pgrace_train_grade/_metadata/`: `0.png` is the cover, `1.png`… the gallery (1920x1080, ≤8 MB).
2. For an update: `just bump` and commit.
3. `just release` (revision check + verify).
4. Upload from **Mod Hub > My Mods** in TF3.
5. Commit what the upload changed (the first one creates `_metadata/mod.io_fileid.txt`), then `just mark-uploaded`
   and push `main`.
