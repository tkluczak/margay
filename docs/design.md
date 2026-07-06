# margay — design

**Status:** Implemented (2026). This document describes the shipped design.

## Motivation

Running a branch's code usually means stopping whatever the main checkout has running and reusing the same ports and the same development database — so two branches can't be alive at once, and one branch's migrations mutate the shared DB. margay's premise: **stand in any git worktree, run one command, and get that branch's services running in isolation** — free ports, a branch-keyed database, env inherited from the primary checkout — while the main checkout's stack keeps running.

margay grew out of a single-project internal tool and was generalized when a second project family needed it; everything project-specific lives in a per-repo config file, nothing in the engine.

**Name:** margay — a cat that is a very good tree climber (worktrees).

## Core decisions

| Question | Decision |
|---|---|
| Config model | **compose-style**: freely named services with uniform fields and explicit dependencies — no baked-in backend/frontend vocabulary |
| Config syntax | **shell DSL** (a sourced fragment), not YAML — zero dependencies beyond `jq`, multiline start recipes are natural, trivially testable |
| Config location | **local, not committed**: `.margay.conf` in each repo's **primary checkout** — worktrees inherit it automatically |
| Monorepos (several services in one tree) | `margay up` starts **all** declared services in dependency order; `margay up <service>` for one |
| DB per sandbox | per-service: `none` / `empty` (app self-migrates) / `seed` (copy of a source DB) |
| Processes | native processes, not containers — no image-build tax, hot reload keeps working |

## Config: `.margay.conf` (shell DSL, compose semantics)

One file per project repo. Example (a Rust API + Vite frontend monorepo — see `examples/` for more, including a seed-mode Gradle project and a cross-repo frontend/backend pair):

```bash
project="acme"
services="api web"
env_file=".env.dev"                        # sourced from the PRIMARY checkout before any start

postgres_psql() { docker exec -i acme-pg psql -U acme "$@"; }
postgres_url="postgres://acme:acme@localhost:5432/{db}"   # {db} substituted per sandbox

service_api_ports="8285-8294"
service_api_db="empty"                     # none (default) | empty | seed
service_api_start() {                      # cwd = worktree; PORT, DB_NAME, DB_URL exported
  export BIND_ADDR="127.0.0.1:$PORT" DATABASE_URL="$DB_URL"
  exec cargo run --release
}

service_web_ports="5283-5289"
service_web_needs="api"
service_web_start() {                      # API_PORT / API_URL injected via needs
  export VITE_API_PROXY_TARGET="$API_URL"
  # pnpm run does not forward --port through to vite — invoke vite directly.
  cd frontend && exec pnpm exec vite --port "$PORT" --strictPort
}
```

### DSL reference

Project-level:

- `project` (required) — name used in the registry, `status`, DB prefix (`<project>_sb_<branch-slug>`), log filenames.
- `services` (required, space-separated) — the freely named service list.
- `env_file` (optional) — file sourced (`set -a`) from the **primary checkout** before any service starts; the engine's variables and your `start()` exports are applied after and win.
- `postgres_psql()` (required iff any service has `db != none`) — how to reach an admin `psql` (e.g. `docker exec -i <container> psql -U <user>` or `docker compose exec -T <service> psql -U <user>`).
- `postgres_dump()` (required iff any service has `db: seed`) — matching `pg_dump` recipe.
- `postgres_url` (required iff any service has `db != none`) — `DB_URL` template; `{db}` is replaced with the sandbox DB name.
- `postgres_seed_from` (required iff `db: seed`) — source database name.

Per service `<name>`:

- `service_<name>_ports` (required) — allocation range `LO-HI`; first free port wins (registry + OS check).
- `service_<name>_start()` (required) — plain bash, run backgrounded with cwd = worktree; `PORT` always exported, plus `DB_NAME`/`DB_URL` when `db != none` and `<DEP>_PORT`/`<DEP>_URL` per dependency. `exec` the final process so the recorded PID is the real one.
- `service_<name>_db` (optional, default `none`) — `empty` creates a branch-keyed DB; `seed` additionally copies `postgres_seed_from` into it on first up (`--fresh` re-copies, `--empty` skips).
- `service_<name>_needs` (optional) — another declared service this one consumes.
- `service_<name>_uses_project` (optional) — `"<project>:<service>"`: like `needs`, but the dependency lives in a *different* project's repo (e.g. a frontend repo pointing at a backend repo's service). Resolution: last-started live instance of that project's service → this service's `main_port` → error.
- `service_<name>_main_port` (optional) — fallback port for `needs`/`uses_project` resolution when no live instance exists (e.g. the port your non-sandboxed main stack uses).

### Config resolution order

1. `.margay.conf` in the **current worktree** — only exists if a project commits one; then a branch can carry its own recipe.
2. `.margay.conf` in the **primary checkout** (`git worktree list --porcelain`, first entry) — the normal, local-only case; every worktree inherits it automatically (untracked files do NOT propagate to worktrees, so reading from the primary is what makes local-only work).
3. Neither → `margay: no .margay.conf for this repo` + exit 1.

**Hygiene:** `.margay.conf` belongs in your global gitignore so it never shows as untracked noise and can never be committed by accident (`install.sh` sets this up).

**Trust note:** the conf is sourced into the engine process (functions are needed). It is your own local file, same trust level as `.zshrc`; validation is for mistakes, not malice.

### Validation (on load)

- `project` and `services` non-empty; every listed service has `ports` and a `start` function.
- Every `needs` target is a declared service; the `needs` graph is acyclic; `uses_project` values match `<project>:<service>`.
- `db` values in {none, empty, seed}; `postgres_psql`/`postgres_url` present if any `db != none`; `postgres_dump` + `postgres_seed_from` present if any `db == seed`.
- Port ranges within one project must not overlap (cross-project overlaps are tolerated — the OS free-check resolves them — but keep ranges disjoint).

## CLI surface

```
usage: margay up [worktree] [service ...] [--use NAME=PORT|URL] [--fresh|--empty] | down [worktree|--all] | status | worktrees
```

- `up` with no service → all declared services in dependency (`needs`) order.
- `up <worktree>` / `down <worktree>` — target another worktree of the repo from wherever you stand; `<worktree>` matches the directory basename or branch name, exactly or as a unique substring (see `docs/worktrees-listing-and-targeting.md`).
- `--use NAME=…` overrides dependency resolution (`needs` or `uses_project`) for the named service (e.g. `margay up web --use api=8290`).
- `--fresh` / `--empty` apply to each started service that declares a DB (mutually exclusive).
- `down` stops the current worktree's services; `--all` stops every margay-managed process. If a stopped launcher orphaned the real listener, `down` reaps it by port.
- `status` lists live sandboxes across all projects; `worktrees` lists the current repo's worktrees with live-sandbox annotations.

## Engine internals

- **Registry** `~/.margay/registry.json` (state dir `~/.margay/`, logs `~/.margay/logs/<project>-<branch-slug>-<service>.log`). Record schema: `{project, service, branch, worktreePath, port, dbName, uses, pid, startedAt}`. Dead PIDs are pruned lazily on every read.
- **Dependency resolution order:** live instance of the named service in the *same worktree* → last-started live instance in the *same project* → `service_<name>_main_port` if set → error with a hint. Injected as `<NAME>_PORT` / `<NAME>_URL` (service name uppercased, non-alnum → `_`).
- **DB lifecycle:** branch-keyed names `<project>_sb_<slug>` (63-char Postgres identifier cap); exists/create/drop/seed built on the conf's `postgres_psql`/`postgres_dump` hooks. Created once, reused on later `up`s of the same branch. A failed preparation (unreachable Postgres, failed seed) aborts the `up` — a half-seeded DB is dropped rather than left behind.
- **Launch mechanics:** per-service backgrounded subshell — env layering is `env_file` (from the primary) → engine vars (`PORT`, `DB_*`, dep vars) → `service_<name>_start()`; stdout+stderr to the per-service logfile; the subshell PID (which `start()` should `exec` into) is what `down`/`status` track.
- **Backing services stay out of scope:** margay does not start Postgres or other infrastructure; if `postgres_psql` fails it reports and exits.

## Known limitations

- `db: seed` requires the branch's migration history to be compatible with the seed source (a branch that rewrites already-applied migrations should use `--empty`).
- One shared Postgres per project; per-branch isolation is DB-level only.
- Native processes, not production parity — intentional (fast iteration; container-parity testing belongs to CI).
- Cross-project dependencies are pairwise (`uses_project`), not a general graph across arbitrary projects.
- If a frontend dev server hardcodes its API proxy target, it needs a one-line env-var override before margay can point it at a sandboxed backend.

## Testing

- Pure-function unit suite (`test/margay_test.sh`): slugify/db naming, registry lifecycle, port allocation, conf loading/validation fixtures, dependency-resolution matrix, worktree parsing/resolution.
- Integration suite (`test/integration_test.sh`): drives the real CLI against throwaway git repos with sleep-based fake services — full `up`/`status`/`worktrees`/`down` lifecycle, worktree targeting, and failure-path regressions (DB-prep failure must not report success).
