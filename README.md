# Train Grade and Weight (Transport Fever 3 mod)

TODO: what the mod does.

- Mod ID: `pgrace_train_grade`
- Cosmetic: yes. It doesn't affect the simulation, so achievements stay enabled.

Agent and modding notes for all mods live in `../AGENTS.md`.

## Layout

```
mod/pgrace_train_grade/                        # the mod folder TF3 loads
├── mod.json, _metadata/              # modinfo.json, description.html, screenshots
├── tealdef/                          # Teal type definitions (canonical; build.py mirrors them into content/)
└── content/gui/pgrace_train_grade/
    ├── industry_plugin.res.lua       # registers the card in the industry window
    ├── pgrace_train_grade.script.tl           # UI
    └── util.tl                       # pure helpers (unit-tested)
tools/                                # type check, tests, install, release checks
tests/                                # unit tests for pure modules
```

## Dev loop

```bash
just check      # type-check against the game's API definitions
just test       # unit tests
just verify     # check + test + release-check
just install    # symlink into TF3's staging area (just install-copy to copy)
```

Restart TF3 after code changes. The log is
`~/.local/share/Steam/userdata/*/3493540/local/crash_dump/stdout.txt`; our lines start with `[pgrace_train_grade]`.

## Releasing

1. Screenshots in `mod/pgrace_train_grade/_metadata/`: `0.png` is the cover, `1.png`… the gallery (1920x1080, ≤8 MB).
2. For an update: `just bump` and commit.
3. `just release` (revision check + verify).
4. Upload from **Mod Hub > My Mods** in TF3.
5. Commit what the upload changed (the first one creates `_metadata/mod.io_fileid.txt`), then `just mark-uploaded`
   and push `main`.
