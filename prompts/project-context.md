Project context for `InfusemediaTeam/inkhub-skeleton`. The reviewer cannot know these; they are specific to the watched repository. Keep it current.

- The `dev` environment is production. There is no separate production stack.
- A merge deploys nothing; deploys are dispatched by hand.
- PRs touching `deploy/terraform/**` or `deploy/ansible/**` must carry a "DevOps action required" section: working directory, exact commands, `AWS_PROFILE`, expected plan, verification, and the expected `sync-ecs-pointers.sh` verdict.
- `schema.sql` is applied at service boot. There is no migration runner. `CREATE INDEX IF NOT EXISTS` matches on the name only, so a changed index definition never reaches production.
- Incident shapes worth checking for by name:
  - DDL run at service boot that takes locks or outlives a client timeout;
  - untested wiring in a service `main.py` that crashes the service at boot;
  - a deterministic per-row failure that is picked up again forever;
  - a consumer that throttles on its own backlog;
  - a cost guard that does not see the spend it is meant to cap;
  - the web-api pool's 60 s client-side `command_timeout` firing before a raised server-side `statement_timeout`;
  - shared per-document state on a long-lived instance across `await` points.
- Operator routes behind dev.inkhub.com are basic-auth only; a route the team calls must not require an app role.
- The shell is Git Bash on Windows: no `jq` (use `node`), and usually no local Python.
