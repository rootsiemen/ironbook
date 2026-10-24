# Scripts

Automation for building, releasing, installing and developing Project Iron
Book. Everything is driven through a single entry point:

```sh
scripts/ironbook.sh <command>
```

## Commands

| Command | Description |
| --- | --- |
| `help` | Show available commands |
| `setup` | Run the first-time developer setup |
| `build` | Build the project artifacts |
| `release` | Cut and sign a release |
| `check-update` | Check an update manifest for a newer release (check only — no download/install yet) |
| `update-version` | Bump version numbers |
| `get-tree` | Print the repository tree |
| `get-codebase` | Dump the codebase (useful for reviews and AI context) |

Run `scripts/ironbook.sh help` for the full, up-to-date list.

## Layout

| Directory | Purpose |
| --- | --- |
| `build/` | Build, packaging and changelog-generation logic |
| `install/` | Installer scripts (used by the curl-based install in the root README) |
| `lib/` | Shared shell helpers (`vars.sh`, `utility.sh`, `help.sh`) sourced by the entry point |
| `release/` | Release automation: versioning, signing, publishing |
| `setup/` | First-time environment setup |
| `tools/` | Developer utilities (`get_tree`, `get_codebase`) |
