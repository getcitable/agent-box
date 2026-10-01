# agent-box

Generic infrastructure image for running a [Raft](https://raft.build) Computer with
[Claude Code](https://claude.com/claude-code) on a [Maritime](https://maritime.sh)
micro-VM.

**This repository contains no business content.** No skills, no instructions, no
brand data, no credentials — only the plumbing. Everything that matters lives on
the runtime volume at `/data` and is pushed separately. That separation is the
reason this can be public while the things worth protecting stay private.

## Why an image rather than installing by hand

Processes started with `maritime exec` are killed when the exec session ends —
even with `setsid nohup`. Only a process the **container itself** owns survives.
So anything that must run on a schedule has to be started by the entrypoint,
which means it has to be in an image Maritime can pull.

It also makes machine specs reversible: `--ram`, `--disk`, `--idle` and
`--always-on` are creation-time-only on Maritime, so the only way to change one
is to recreate the box. That is cheap if the box is reproducible and expensive
if it was built by hand.

## What's inside

| | |
|---|---|
| Node 22 (Debian bookworm) | base |
| `@anthropic-ai/claude-code` | the agent runtime |
| `raft-computer` | connects the box to a Raft workspace |
| unprivileged user, **uid 1000** | required — see below |
| `entrypoint.sh` | supervises the Computer, runs interval work |

## The one non-obvious requirement

Raft launches Claude Code with `--dangerously-skip-permissions`. Claude Code
**refuses that flag as root**:

```
--dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons
```

Most container images run as root, so every agent invocation exits 1 with no
useful error. Hence the `agent` user — and **uid 1000 specifically**, because the
user record lives on the ephemeral root filesystem while the files it owns live
on the persistent volume. A different uid cannot read its own state after a
redeploy.

## Configuration

Set per agent with `maritime env set <agent> KEY=value --reload`:

| var | default | meaning |
|---|---|---|
| `AGENT_HOME` | `/data/agent` | where state lives on the persistent volume |
| `RAFT_SERVER` | — | workspace slug, e.g. `/my-workspace` |
| `MONITOR_CMD` | — | optional command the supervisor runs on an interval |
| `MONITOR_EVERY_H` | `24` | hours between `MONITOR_CMD` runs |

Do **not** set `HOME` or `PATH` as Maritime env vars — doing so breaks
`maritime exec` with a `502` while `status` still reports the agent healthy. The
wrapper and entrypoint set them per process instead.

## Deploy

```bash
maritime create my-box --repo https://github.com/<owner>/agent-box --branch main \
  --ram 8192 --disk 20 --idle 3600 --json
maritime env set my-box RAFT_SERVER=/my-workspace --reload --json
```

Then, once, in the Maritime dashboard console:

```sh
su agent -s /bin/sh
export HOME=/data/agent
claude auth login                              # subscription; paste the code
raft-computer login                            # approve the device URL
raft-computer setup $RAFT_SERVER --name my-box -y
```

Both logins need an interactive paste-back, so they cannot be scripted. After
that the entrypoint keeps the Computer up on its own.

## Residency: do not reach for a keepalive cron

Raft queues messages through outages and delivers them on reconnect, but nothing
on Raft's side can wake a sleeping Maritime VM. The obvious fix is a one-minute
cron to hold the box awake:

```bash
maritime triggers create my-box --type cron --cron "* * * * *" --json   # ← expensive
```

**Don't.** Maritime meters and bills compute per awake-second, so this is the
most expensive configuration available, not the cheapest — it defeats auto-sleep
entirely. Measured 2026-10-01: a box under this cron ran at a 0.99
compute-to-wall ratio, i.e. billed continuously, and $482.72 of compute accrued
across two boxes in about a day and a half.

"No cap on compute minutes" means no *limit*, not no *charge*.

Two fields are easy to conflate: `tier` is the **billing** tier, while
`sleepPolicy` / `idleTtlSeconds` is the **behaviour**. A box can bill on
`always_on` and still fall asleep, so observing it sleep proves nothing about
what it costs.

Prefer the flat always-on add-on when a box genuinely must be reachable — a
fixed fee is both cheaper and more predictable than defeating sleep. Otherwise
accept the wake latency and let it sleep. There is no billing API (`/v1/usage`,
`/v1/billing/*` all 404), so get the per-core-hour rate from Maritime before
sizing anything.

```bash
maritime status my-box --json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['tier'],d['sleepPolicy'],d['totalComputeSeconds'])"
maritime triggers list my-box --json
```

## Notes from building this

- `raft-computer` survives Maritime's sleep/wake intact — the VM is snapshotted
  and processes resume with the same PIDs. Only `restart` and redeploy kill them.
- Stale `service.pid` / `service.sock` make `raft-computer status` report a dead
  process as `running` while the server shows `offline`, blocking every start.
  The entrypoint clears them.
- `.claude.json` lives at the **home root**, not inside `.claude/`. Moving only
  the directory leaves Claude Code unable to find its config.
- Never run overlapping `claude` invocations against one `HOME`: a race on
  credential refresh can write both tokens as empty strings, and there is no
  credential backup to restore from.

MIT.
