# Devboxes: running Bluejay, and agents, in the cloud

This directory is `bj`, a thin CLI over EC2 that gives an engineer a personal
Linux box running the full Bluejay stack. It exists for two reasons: the stack
peaks around 9 GiB at rest and 13 GiB while building, which OOMs a 16 GiB laptop,
and agents that need to run the product benefit from somewhere that is not the
machine the human is typing on.

**This is optional.** Nothing here changes normal `bluejay-local` usage on a Mac.
If the laptop copes, use the laptop. Reach for a box when the stack will not fit,
when you want an agent working without competing for local resources, or when you
want several of those running at once.

## Day to day

```
bj up                         # starts your box and the whole stack, prints live URLs
bj up frontend middleware     # same, but only those services
```

`bj up` on its own boots everything. A box exists to run the stack, so naming
services is the narrow case, not the default.

It prints a URL only once that port actually answers, so a link it gives you is
a link that works. If a service never comes up it says so and points at the log
instead of handing you a dead address.

Then `bj ssh`, or point Remote-SSH at it. Walk away when you are done and it
shuts itself off.

**First `bj up` on a fresh box takes 15 to 25 minutes** and looks idle for most
of it, because `just start` builds the lambda container images before anything
listens. It prints the current log line every minute so you can see it moving.
Every later `bj up` is about a minute, since the images and volumes persist.

That is the whole daily loop. Everything below is for whoever maintains this.

## Before anything

```
aws sts get-caller-identity     # must return an identity
ssh-add -l                      # must list a key GitHub knows
```

The second one matters more than it looks. Repos clone over ssh with the
engineer's forwarded agent, deliberately, so no GitHub token ever lands on a box
that later gets snapshotted into an AMI. With no key loaded the clone is skipped
and the box comes up empty.

## Lifecycle

```
bj up                     # create or start, clone the workspace, print the host
bj up frontend middleware # same, then boot those services in tmux
bj status                 # id, state, type, hostname
bj ssh                    # log in, agent forwarded
bj url                    # frontend and middleware addresses
bj down                   # stop now rather than waiting for the idle timer
bj reap                   # dry run: boxes stopped longer than 3 days
bj bake                   # rebuild the base AMI after editing cloud-init.yaml
```

`bj up` is idempotent. It looks for the instance tagged with your owner name and
starts it, and only creates one when you have none. **Always `bj status` before
assuming you need a new box.**

First boot is about 80 seconds, because the tools are baked into an AMI. If the
clone is reported as deferred, provisioning is still going: run `bj up` again
when it finishes. Watch progress with `bj ssh 'tail -f /var/log/bj-provision.log'`.

A stopped box keeps its disk, so clones, venvs, `node_modules` and Docker layers
all survive. Starting a box you already have takes under a minute. That is the
normal case, and creating a second box when you meant to start an existing one is
the most common way to waste money here.

## Timings, measured

| Step | Time |
| --- | --- |
| Create a new box from the baked AMI | 81 s, measured |
| Create a new box with no AMI baked | ~10 min |
| `bj bake` a new AMI | ~12 min |
| Clone all seven repos | 8 s |
| `just setup` | 56 s, once per workspace |
| `just start` to middleware healthy | 46 s |
| Frontend ready once its process starts | 453 ms |
| Start an existing box | under 1 min |

First time on a fresh box is about 3.5 minutes end to end (81 s boot, 8 s clone,
56 s `just setup`, 46 s to middleware healthy). Every start after that
is under a minute, because the volume keeps the venvs, node_modules and Docker
layers.

Re-run `bj bake` after editing `cloud-init.yaml`, or new boxes keep launching the
old image. `bj up` takes the newest AMI tagged `bluejay:devbox-ami=1` and falls
back to stock Ubuntu when there is none.

`just start` never exits. It is honcho in the foreground running all five
services, so treat it as a long-lived process, not a command that completes. Put
it in tmux, which is what `bj up <services>` does.

## Running the stack on the box

```
bj ssh
cd ~/bluejay-local/local
just setup && just migrate && just seed
just start frontend middleware
```

`infisical login` is not in that list. The box authenticates with its EC2
instance role and the token is exported into your shell from tmpfs. If
`INFISICAL_TOKEN` is unset, `INFISICAL_MACHINE_IDENTITY_ID` has not been filled
into `cloud-init.yaml` yet and you are back to `infisical login` by hand; check
`journalctl -u bj-infisical`.

Never `./up`. It exits on line 13 with "macOS only" because it installs
everything through Homebrew. The just recipes are what it wraps, and they work.

`bj up <services>` does the `just start` part for you in a tmux session named
`bluejay`, so it survives your connection dropping. Attach with
`bj ssh -t tmux attach -t bluejay`, or read `~/bluejay-start.log`.

Start only the services the work touches. The full set is five processes plus
Supabase, ClickHouse, Redis and the ministack. `~/bluejay-local/CLAUDE.md` on the
box has the mapping from change type to services, and agents working on the box
read it automatically.

## Running agents on the box

`claude` is installed. Authentication is a browser code you paste back, so
nothing is copied from the laptop.

```
bj ssh
cd ~/bluejay-local
claude
```

For a long unattended run, put it in tmux and pin the box up first, otherwise the
idle timer will power off a box that is busy but quiet:

```
bj ssh
touch /var/lib/bj-idle/hold
tmux new -d -s agent 'cd ~/bluejay-local && claude -p "..." 2>&1 | tee ~/agent.log'
```

**Remove the hold file when the run finishes.** A forgotten hold file turns a
$0.38/hr box into $276/month. `journalctl -t bj-idle` shows what the timer
decided and why.

## Reuse one box, run several stacks

**Default to one box per person.** A second box is a second $0.38/hr and a second
150 GB volume, and the reason you would want one, port collisions, is already
solved inside bluejay-local.

`just start` takes per-stack worktree overrides. Each stack gets its own port
block and its own compose project, sharing Supabase and ClickHouse:

```
just start --feat outbound --mw ~/wt/mw-outbound --fe ~/wt/fe-outbound
just start --feat traces   --mw ~/wt/mw-traces
bin/stacks                 # ports, honcho pid and container count per stack
```

That is how you point one box at different branches, and how two agents work in
parallel without the LiveKit 8081 collision that silently kills extra workers.

**You cannot have a second box.** The IAM policy binds the owner tag to
`${aws:username}` exactly, so `BJ_OWNER=anything-else bj up` is denied for any
engineer holding it. That is deliberate, not an oversight: the reason to want a
second box is solved above, and a second box is another $12/month volume nobody
deletes. A genuinely separate box (different instance size, throwaway
experiment) is an ops action by an unscoped operator.

## Reaping idle boxes

A stopped box costs nothing to run and $12/month in volume, forever, until
someone deletes it.

```
bj reap          # dry run: what is older than BJ_REAP_DAYS, default 3
bj reap --yes    # snapshot each root volume, then terminate
```

It only ever considers boxes that are already **stopped**, snapshots before
terminating so nothing uncommitted is truly lost, and skips anything tagged
`bluejay:keep`. `reap.yml` runs it weekday mornings in dry-run and needs a manual
dispatch with `apply` to act, which is the right default until the team trusts
it.

Tag a box you are coming back to:

```
aws ec2 create-tags --resources <id> --tags Key=bluejay:keep,Value=1
```

## Cost discipline

$0.38304/hr while running, plus $12/month per 150 GB volume that bills whether
the box runs or not. The idle timer is the entire cost model: 30 minutes with no
ssh session and CPU under 10 percent and the box powers off.

- `bj status` before creating.
- `bj down` when finished, or trust the timer.
- A terminated box loses its volume. Stopping is what you almost always want.
- Check for strays: `aws ec2 describe-instances --filters "Name=tag-key,Values=bluejay:devbox-owner"`

## Reaching it from a browser

`bj up` and `bj url` print `http://localhost:3000`. The box's ports are forwarded
to this machine over ssh, so nothing is exposed publicly and there is no
hostname to re-copy after a restart.

**Do not use the box's public hostname in a browser.** The frontend sends
`upgrade-insecure-requests` in its CSP for every host that is not localhost, so
over `http://<ec2-host>:3000` every stylesheet and script gets upgraded to https,
fails against a plain-http port, and the page renders as unstyled Times New
Roman. `proxy.ts` skips CSP for localhost, which is why the tunnel is the only
address the app actually renders on. It also gives `getUserMedia` a trustworthy
origin, so browser mic testing works.

The tunnel is a control-master ssh started by `bj up` and closed by `bj down`.
If ports 3000 and 8000 are already busy locally it retries at +10000 and tells
you which it used.

## Editing code

VS Code or Cursor Remote-SSH into the box and open `~/bluejay-local`. The
hostname changes between sessions, so the `~/.ssh/config` entry needs updating
after each restart.

Do not edit on the laptop and sync. Two copies drift, and the whole point is that
the box is where the stack runs.

## Known rough edges

| Symptom | Cause |
| --- | --- |
| `./up` exits immediately | It is macOS only. Use the just recipes. |
| Workspace has only `local/` | `setup-workspace.sh` prefers `gh repo clone` and `gh` is unauthenticated here. `bj-clone` works around it by cloning over ssh. |
| `lambdas: cloud secrets missing` | infisical CLI older than 0.41. The cloudsmith apt repo serves 0.38, which demands `infisical init` even with `--projectId`. cloud-init pins a release build. |
| ffmpeg fails at runtime inside evals | The Dockerfile hardcodes an arm64 tarball and nothing sets `--platform`. The image **builds fine** on x86_64, because copying a binary never checks its architecture, and then ffmpeg dies on exec. Worse than a build error: it passes CI and fails during an eval. |
| `process memory usage is high` from a livekit agent | LiveKit's `job_memory_warn_mb` defaults to 500 and our idle baseline is 509 MB, so it fires before the worker does any work. Noise, and it will bury a real warning. |
| `error initializing inference runner` on both agents | Logged twice each at startup, non-fatal, agents keep running. Unchased. Start here if voice behaves oddly on a box. |
| A health check on the frontend "fails" | `localhost:3000` returns **307** redirecting to login. That is correct. Accept 3xx. |
| Page loads but has no styling, Times New Roman | You are on the box's public hostname. CSP upgrades every asset to https and the port is plain http. Use `bj url`, which forwards to localhost. |
| `bj up` says a port is answering but the link is dead | Was true when the check tested the TCP listen. `next dev` binds before it can serve, and a wedged orphan holds the port answering nothing, so the check makes a real HTTP request now. |
| `EADDRINUSE :::3000` in the start log | An orphan from a previous run. `bj up` stops the stack and reaps port holders inside the workspace before starting, with SIGKILL, since the wedged ones spin and ignore SIGTERM. |
| Bluejay AI is off | `cloudflared` missing, so `bin/tunnel` returns nothing and there is no public MCP URL. Installed by cloud-init and by `bj up`. The chat also needs `ANTHROPIC_API_KEY` and `DOCS_MCP_SERVER_URL`, which come from Infisical. |
| Box died mid-task | Idle timer. Use the hold file. |
| Clone skipped on `bj up` | No key in the ssh agent. `ssh-add`, then `bj up` again. |
| `MISS uv` / `MISS honcho`, then `macOS only` | Both live in `~/.local/bin`, which only login shells get, and `bj up` starts `just start` under `tmux new -d`, which is not one. Fixed by putting the directory in `/etc/environment`; `bj up` also installs either if missing. |
| `lambdas: evals FAILED to deploy` | No `infisical login` on the box, so the evals image cannot fetch the model it copies from S3. Everything else still boots. |

The first four are `bluejay-local` assuming a Mac, not devbox bugs. They want
fixing upstream, in ways that are no-ops on macOS:

- `setup-workspace.sh` should fall back to git when `gh auth status` fails, not
  only when `gh` is missing. No change for a Mac with gh logged in, and it also
  unbreaks a new hire who has not run `gh auth login`.
- `./up` should grow a Linux branch, or say "use the just recipes" instead of
  exiting. macOS keeps its exact path either way.
- The evals Dockerfile should pick its ffmpeg tarball off `TARGETARCH`. Identical
  result on Apple Silicon.
- `bin/start` appends `~/.local/bin` to `.bashrc`, which lands *after* Ubuntu's
  early return for non-interactive shells, so it never applies to the case that
  needs it. `/etc/environment` reaches every session because sshd runs pam_env.
- `bin/bootstrap` exits with "macOS only", so preflight tells a Linux box to run
  `brew install` and then gives up. It should install the same tools with apt and
  the upstream installers.
- `deploy_lambdas.py` let one unbuildable image kill the whole stack. One lambda
  that will not build should be loud, not fatal, which is what `bin/start`
  already does for a missing Infisical login.
- `just supabase-init` and `set_kv` in `bin/start` use `sed -i ''`, which is BSD
  syntax. GNU sed reads the `''` as the script and the expression as a filename.

If any of them cannot be made a no-op on macOS, it stays a workaround in here and
bluejay-local is left alone. Nothing in this directory runs unless someone types
`bj`.

## Where this lives

`bluejay-local`, at `devbox/` in the repo root. That repo already owns
`setup-workspace.sh`, `up`, the justfile and `bin/`, and `bj`'s whole job is
producing a bluejay-local workspace, so anywhere else and the two drift the first
time the repo list changes.

Not `bluejay-github-actions`, which is CI. Not its own repo, which would have to
track `setup-workspace.sh` forever.

## Built, and what is still human

Everything below is wired but needs one action from a person before it does
anything:

- **Infisical machine identity.** `cloud-init.yaml` logs in with
  `--method=aws-iam` against the `bluejay-devbox` instance role, guarded on
  `INFISICAL_MACHINE_IDENTITY_ID`, which is empty. Someone with Infisical admin
  creates the identity, trusts the role ARN, **scopes it read-only to dev**, and
  fills the value in. Until then `infisical login` is still a human step. See
  README.md for the exact steps and why the scoping is not optional.
- **The engineer IAM policy.** `bluejay-devbox-engineer` exists in the account
  and is attached to nobody. One `aws iam attach-user-policy` per engineer.
- **The box that predates all this.** `i-09d4d39ca9ecd32c7` still has no
  instance profile, so it cannot use Infisical aws-iam auth. Its owner tag is
  already `lorenzo_taylor`, so `bj up` finds it and will attach the profile on
  the next run. That is one `bj up` on a box that is currently in use, so it was
  left for its owner rather than done behind their back. Attaching a profile
  needs no stop and no reboot.
