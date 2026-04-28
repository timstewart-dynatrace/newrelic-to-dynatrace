# Core Rules

## Git Workflow

- Feature branches only — never commit directly to `main`
- Branch naming: `feature/`, `fix/`, `refactor/`, `chore/`, `docs/` — lowercase, hyphenated
- Commit format: Conventional Commits (`feat`, `fix`, `refactor`, `chore`, `docs`)
- Merge with `git merge --no-ff` to preserve branch history
- Delete branches after merging (remote and local)

## Documentation (required before merging)

- [ ] `README.md` — update if user-facing changes
- [ ] `CHANGELOG.md` — entry following Keep a Changelog format
- [ ] `DECISIONS.md` — log any architectural decisions made

## Versioning

Follows SemVer 2.0.0:
- **MAJOR** — Breaking changes to archive schema or script interface
- **MINOR** — New export types or capabilities (backwards-compatible)
- **PATCH** — Bug fixes

Version locations to update together:
1. `CHANGELOG.md`
2. `SCRIPT_VERSION` / `$ScriptVersion` constant at the top of both scripts
3. `settings.json` → `version`

## Changelog Format

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
### Changed
### Fixed
### Removed
```
