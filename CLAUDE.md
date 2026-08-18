# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

```bash
make build       # Build linux/amd64 by default
make structure   # Verify package, config, and image cleanup
make smoke       # Verify initialization and persistence
make smoke-all   # Build and smoke all release platforms
make build-all   # Build all platforms into Buildx cache
```

## Architecture Overview

The image packages Debian Etch's pinned MySQL 5.0.32 server/client packages.
`docker-entrypoint.sh` initializes empty datadirs through a socket-only temporary
server and leaves existing datadirs unchanged. Releases publish one manifest
for `linux/amd64`, `linux/386`, and `linux/arm/v5`.

## Conventions & Patterns

- Keep pinned APT installation before local `COPY` instructions.
- Keep shell compatible with Debian Etch's Bash 3 and validate with `bash -n`.
- Preserve Docker Official Image semantics where MySQL 5.0 supports them.
- Use non-interactive cleanup and never commit database dumps.
- Run `make structure` and `make smoke` after runtime changes.
