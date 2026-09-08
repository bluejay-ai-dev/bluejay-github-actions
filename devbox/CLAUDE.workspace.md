# Bluejay devbox

You are on a remote EC2 dev box, not a laptop. The whole stack runs here, and
`~/bluejay-local` holds every repo.

## Starting services

Do not run `./up`. It exits immediately with "macOS only".

`bj up` from the engineer's laptop already boots the full stack, so check what is
running before starting anything:

```
cd ~/bluejay-local/local && just ps
```

Start only what your change touches when you do start something by hand. Booting
everything costs several minutes and 9 GiB of memory for services you are not
using.

```
cd ~/bluejay-local/local
just start frontend middleware     # name only what you need
just ps                            # what is running
just doctor                        # diagnose a broken stack
```

| You are changing | Start |
| --- | --- |
| Frontend only | `frontend` |
| An API route or model | `middleware`, add `frontend` to click through it |
| Voice behaviour, outbound | `middleware agent` |
| Voice behaviour, inbound | `middleware agent_inbound` |
| Traces, metrics, ClickHouse | `middleware ch_bridge` |
| Evals or lambdas | `middleware`, then `just start` for the full set |

Supabase, ClickHouse, Redis and the ministack come up on their own whenever any
service starts. You do not start them yourself.

## First run in a fresh workspace

```
just setup               # .env.local, venvs, frontend deps
just migrate
just seed                # fixture data
```

`just reset` wipes the local database back to migrations plus seed.

No `infisical login`: the box authenticates with its EC2 instance role at boot
and `INFISICAL_TOKEN` is already in your shell. If it is empty, the machine
identity id has not been configured yet, so log in by hand and check
`journalctl -u bj-infisical`.

## Reaching it

Frontend 3000, middleware 8000. The engineer reaches both at `http://localhost:PORT`
on their own machine, forwarded over ssh by `bj up`.

Never hand out `http://<this-box>:3000`. The frontend's CSP carries
`upgrade-insecure-requests` for any non-localhost host, so every asset is
upgraded to https, fails against a plain-http port, and the page renders
unstyled. Only the localhost address renders, and only it gives the browser mic
a trustworthy origin.

## The box stops itself

After 30 minutes with no ssh session and CPU below 10 percent. If you start
something detached that is slow but not CPU hungry, a long test run waiting on
the network for example, `touch /var/lib/bj-idle/hold` first and `rm` it when the
job finishes. Otherwise the box powers off underneath your work.

`journalctl -t bj-idle` shows what the timer decided and why.

## Things that are true here and not on a Mac

- `./up`, and anything that shells out to `brew`, does not work.
- `python3.11` is the pinned interpreter. The system default is 3.12.
- The infisical CLI is pinned to a release build. Do not install it from the
  cloudsmith apt repo, which serves 0.38 and breaks every lambda build.
- Repos are cloned over ssh with the engineer's forwarded agent. There is no
  GitHub token on this box, so `gh` is installed but not authenticated. Use
  `git`, not `gh`, for anything that touches a remote.
- `uv` and `honcho` live in `~/.local/bin`. That is on `PATH` via
  `/etc/environment`, not `.bashrc`, because Ubuntu's `.bashrc` returns early for
  the non-interactive shells that `ssh host cmd` and `tmux new -d` use. If a tool
  reads as missing, check `PATH` before concluding it is not installed.
- Anything using `sed -i ''` is BSD syntax and silently misbehaves here.
- Without `infisical login` the evals lambda image cannot build, so evals will not
  work. The rest of the stack boots normally and says so.
