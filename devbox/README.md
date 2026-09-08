# Bluejay cloud dev boxes (ENG-612)

One personal EC2 box per engineer. You start it when you sit down, ssh in, and it
shuts itself off when you stop using it. The frontend it runs is reachable at a
per-engineer HTTPS URL so reviewers can click a link instead of pulling a branch.

Plain EC2, on demand. No Coder, no managed platform.

## Day to day

```
bj up frontend middleware     # starts your box, boots those services
bj url                        # the link to open
```

Then `bj ssh`, or point Remote-SSH at it. Walk away when you are done and it
shuts itself off. First time on a box only, add
`just setup && just migrate && just seed` after your first `bj ssh`.

## Get a box

```
export PATH="$PATH:/path/to/this/dir"

bj up        # start my box, or create it the first time; prints the hostname
bj ssh       # log in (forwards your ssh agent, so git clone of private repos works)
bj status    # id, state, type, hostname
bj url       # my frontend's public URL, and whether the tunnel is up
bj down      # stop it now instead of waiting for the idle timer
bj bake      # rebuild the base AMI (ops, after editing cloud-init.yaml)
```

`bj up` is idempotent. It finds the instance tagged `bluejay:devbox-owner=<you>`
and starts it; it only creates one when you have none. A stopped box keeps its
disk, so your clones, venvs and `node_modules` survive.

The public hostname **changes every time the box stops and starts**, because
there is no Elastic IP (one would bill for every hour the box is off, which is
most of them). This is why `bj ssh` looks the address up each time instead of you
keeping it in `~/.ssh/config`, and why `bj url` looks it up too.

A new box comes up in about 80 seconds from the baked AMI, or about ten minutes
if nobody has run `bj bake` in this account. Watch it with
`bj ssh 'tail -f /var/log/bj-provision.log'`; `/var/lib/bj-provisioned` appears
when it is done.

`bj up` clones the workspace into `~/bluejay-local` for you, using your forwarded
ssh agent, and does nothing on later runs once it exists. Load your key first or
the clone is skipped:

```
ssh-add ~/.ssh/id_ed25519
```

On a brand new box the clone is deferred until provisioning finishes, so run
`bj up` once more when it does.

Everything is tunable by env var: `BJ_REGION`, `BJ_INSTANCE_TYPE`, `BJ_VOLUME_GB`,
`BJ_OWNER`, `BJ_KEY_NAME`, `BJ_KEY_FILE`, `BJ_LEGACY_KEY_FILE`, `BJ_SG_NAME`,
`BJ_INSTANCE_PROFILE`,
`BJ_BAKE_TYPE`, `BJ_BAKE_GB`.

## What is on the box

Ubuntu 24.04, `m7i-flex.2xlarge` (8 vCPU / 32 GiB), 150 GB encrypted gp3.

`cloud-init.yaml` has no cloud-config `packages:` list on purpose: it re-ran on
every boot and cost 81 seconds reinstalling what the AMI already had.
`bj-provision` installs everything instead, and only on a box that is not built
from a baked image. That is docker-ce with the compose v2 plugin, node 22,
python 3.11 (bluejay-local pins its venvs to it; 24.04 only ships 3.12), uv,
honcho, just, gh, the supabase CLI, dbmate, psql and a pinned infisical release.
All of that is baked into the AMI, so a new box only re-runs the cheap half. It
also raises
the inotify limits, which the stock kernel settings will not survive once
`next dev` and ~10 Supabase containers are both watching files.

Repos are deliberately **not** cloned at boot. They are private, and baking a
GitHub token into user-data would leave a long-lived credential on every box.
`bj ssh` forwards your agent instead and `bj-clone` uses your own key.

## Idle shutdown

This is the entire cost model, so it is worth understanding.

`bj-idle.timer` runs `/usr/local/bin/bj-idle-shutdown` every 5 minutes. The box
powers off after `IDLE_MINUTES` of continuous idle, where idle means *no ssh
session logged in* **and** CPU busy below `IDLE_CPU_PCT`. Both knobs are at the
top of `idle-shutdown`; defaults are 30 minutes and 10%.

Idle time accumulates from wall-clock deltas rather than a tick count, so you can
change the timer interval without retuning the thresholds. The first check is
held off until 20 minutes after boot so a fresh box is never killed mid-provision.

Running something detached that is slow but not CPU-hungry, like a long test run
waiting on the network? `touch /var/lib/bj-idle/hold` pins the box up, `rm` it to
release. Without that, a job with no ssh session and low CPU looks exactly like an
abandoned box.

`journalctl -t bj-idle` shows what it decided and why.

## Reaching the frontend

`bj url` prints the box's public address for each port in `BJ_PORTS`, default
3000 and 8000:

```
bj url
http://ec2-3-84-12-9.compute-1.amazonaws.com:3000
http://ec2-3-84-12-9.compute-1.amazonaws.com:8000
```

`bj up` opens those ports to your current public IP, the same way it opens ssh,
and re-opens them on every `up` because laptops roam. Nothing is open to the
world.

To let a reviewer in, add their IP:

```
aws ec2 authorize-security-group-ingress --group-id <sg> \
  --ip-permissions "IpProtocol=tcp,FromPort=3000,ToPort=3000,IpRanges=[{CidrIp=<their-ip>/32,Description=reviewer}]"
```

Two things to know:

**The address changes every stop and start.** There is no Elastic IP, because AWS
bills $0.005/hr for a public IPv4 whether the box is running or not, and the boxes
are off most of the time. Run `bj url` again after a restart rather than saving
the hostname. If a stable address is worth $3.60/mo per box, allocate an EIP and
associate it in `cmd_up`.

**It is http, not https.** Browser APIs that need a secure context will not work
over a bare IP: `getUserMedia` in particular, so testing a voice agent through the
browser mic fails on this URL and works on `localhost`. Forward the port over ssh
when you need that:

```
ssh -i ~/.ssh/bluejay-devbox-$(aws sts get-caller-identity --query Arn --output text | sed 's|.*/||').pem \
  -L 3000:localhost:3000 ubuntu@$(bj status | awk '{print $5}')
```

That also gets you a private URL without touching the security group at all, which
is the better default for solo work. The open ports exist so someone else can look.

## One-time AWS setup

`bj` creates all of this on first use, so in practice nobody runs these by hand.
They are written out because someone will need to audit or re-create them.

**Key pair.** One per engineer. `bj` creates `bluejay-devbox-<aws-username>` on
first use and writes the private key to `~/.ssh/bluejay-devbox-<aws-username>.pem`
(mode 600). The name comes from `sts:GetCallerIdentity`, not from the laptop's unix
account, so IAM can bind it the same way it binds the owner tag.

There used to be a single shared `bluejay-devbox` pair, and it had only two possible
end states: whoever ran `bj up` first held the only `.pem` and nobody else could use
`bj` at all, or the `.pem` got passed around and every engineer could ssh into every
other engineer's box. Neither is acceptable, and there was no middle state.

Migrating a box that was launched on the shared pair: EC2 injects a key pair once,
at first boot, and will not swap it afterwards. So `bj up` installs your personal
public key over the shared one instead, the first time it finds `bluejay-devbox.pem`
in `~/.ssh` and the personal key not yet accepted. Same box, same disk, no rebuild.
Once every box has moved, delete `~/.ssh/bluejay-devbox.pem` and the shared pair in
AWS. `BJ_LEGACY_KEY_FILE` overrides where the old `.pem` is looked for.

Lost your `.pem`? AWS keeps no copy of the private half. `aws ec2 delete-key-pair
--key-name bluejay-devbox-<you>` and `bj up` makes a new one, but a box that is
already running keeps trusting the old key, so that box needs `bj down && bj up`.

**Security group.** `bluejay-devbox`, created empty, in the default VPC. `bj up`
adds TCP/22 plus each port in `BJ_PORTS` for whatever public IP you are on. It also
revokes your own rules that are no longer the current IP and port block first, so
the group does not grow without bound: the quota is 60 inbound rules, `bj` swallows
the error from `authorize` when it is hit, and past that point ssh simply starts
refusing with nothing to read. Rules are matched by their description, which is the
AWS username, so pruning never touches another engineer's access. Nothing is ever
open to `0.0.0.0/0`, and the LiveKit worker dials out so it needs nothing inbound.

`./test-sg-prune.sh` asserts the selection against a fixture: current rules kept,
your stale ones dropped, everyone else's left alone.

**IAM policy.** `bluejay-devbox-engineer` exists as a managed policy:

```
arn:aws:iam::148660429236:policy/bluejay-devbox-engineer
```

It is **attached to nobody**. One command per engineer:

```
aws iam attach-user-policy --user-name <iam-username> \
  --policy-arn arn:aws:iam::148660429236:policy/bluejay-devbox-engineer
```

It is deliberately not on `lorenzo_taylor`, which is the account that bootstraps
everything and needs to stay unscoped.

The owner tag binds to `${aws:username}` **exactly**. That is what stops engineer
two stopping engineer one's box. It also means one engineer gets exactly one box:
a `BJ_OWNER=side-project bj up` is denied for anyone holding this policy, because
the tag would not equal their username. That is the intended trade. `bj` and
`bluejay-local` already solve the reason you would want a second box (per-stack
worktrees and port blocks on one machine, see CLAUDE.md), and a second box is a
second $12/month volume that nobody remembers to delete. If someone genuinely
needs two, that is an ops action: an unscoped operator runs `BJ_OWNER=x bj up`.

The alternative, allowing `${aws:username}-*` as well, was rejected: it buys
fleets that the tool does not want and it silently breaks isolation the moment
two IAM usernames share a prefix.

Because the tag must equal the AWS username, `bj` derives `BJ_OWNER` from
`sts:GetCallerIdentity` rather than from the laptop's `id -un`. Those differ more
often than you would guess (`lorenzotaylor` vs `lorenzo_taylor` here).

Two statements are worth arguing about before you attach it:

- `ec2:AuthorizeSecurityGroupIngress` on the `bluejay:managed-by=bj` group. `bj
  up` needs it every time, because laptops roam and the current IP has to be
  re-authorised. EC2 has no condition key for the CIDR in a rule, so this is
  all-or-nothing: an engineer holding it *can* open their own box to
  `0.0.0.0/0`. Accepted because the box holds only dev secrets and the tool does
  not work without it. Drop the statement and pre-authorise a VPN range instead
  if that trade is wrong for you.
- `ec2:TerminateInstances`, so an engineer can rebuild a box they have wrecked.
  Drop it if you would rather that be an ops action.

There is no `CreateSecurityGroup`, so whoever bootstraps the SG needs broader
rights once. `CreateKeyPair` and `DeleteKeyPair` are scoped to
`key-pair/bluejay-devbox-${aws:username}` exactly, which is what lets `bj` make an
engineer their own pair without letting them touch anyone else's, or delete the
shared one while boxes still boot on it. The statements are in
`iam/devbox-engineer-keypair-delta.json`; they are additions to the existing
managed policy, not a replacement for it, and until they are applied
`./test-iam-policy.sh` fails on exactly those checks.

`./test-iam-policy.sh` asserts all of the above against the live policy with
`iam:simulate-custom-policy`: engineer two is denied, oversized instance types
are denied, `PassRole` reaches only the devbox role. Run it after any edit.

**Instance profile.** `bluejay-devbox`, a role trusted by `ec2.amazonaws.com`
with an instance profile of the same name, attached by `bj up` at RunInstances
and associated after the fact on a box that predates it.

**It has no policies attached, on purpose.** Infisical's `aws-iam` auth works by
having the box sign an `sts:GetCallerIdentity` call with its instance role and
handing the signed request to Infisical, which verifies the caller ARN. Signing
that call needs no IAM permission at all. The role is valuable precisely because
it is *assumable and empty*: it identifies the box and grants it nothing. Adding
permissions to it makes every devbox a bigger blast radius for no gain.

## Infisical without a human step

`infisical login` used to be a per-box interactive step. The CLI supports
`--method=aws-iam --machine-identity-id=<id>` (confirmed against the current
docs), so a box authenticates with its instance role and no secret is ever
copied to a box, baked into an AMI or rotated.

Wiring on the box is already in `cloud-init.yaml`:

- `/etc/bj.env` holds `INFISICAL_MACHINE_IDENTITY_ID=`, **empty**.
- `bj-infisical.service` runs at every boot, and does nothing while it is empty,
  so today the human step still exists.
- With it filled in, the unit writes the token to `/run/bj/infisical-token`.
  `/run` is tmpfs: the token never touches the disk, so it cannot end up in a
  snapshot or an AMI, and it dies with the box.
- `~/.bashrc` exports `INFISICAL_TOKEN` from that file, on its first line,
  because Ubuntu's stock bashrc returns early for the non-interactive shells
  `ssh host cmd` and tmux use.

### The CI role, done

`bluejay-preview-ci` exists in account 148660429236 and is attached to the policy of
the same name. GitHub assumes it over the OIDC provider that was already there.

The trust condition is `job_workflow_ref`, not `sub`: only the preview workflow in
`bluejay-github-actions` can assume it, whichever repo called it. Conditioning on `sub`
would have let any workflow in any org repo assume it.

The policy is the engineer policy keyed on `bluejay:preview-ticket` matching `ENG-*`
instead of `bluejay:devbox-owner`. `test-preview-iam.sh` simulates it and asserts both
halves, the second being the one that matters:

```
preview boxes:                    terminate/stop/start   allowed
must not reach an engineer's box: terminate a devbox     implicitDeny
                                  stop a devbox          implicitDeny
                                  terminate untagged     implicitDeny
                                  terminate non-ENG tag  implicitDeny
```

Definitions are in `iam/preview-ci-trust.json` and `iam/preview-ci-policy.json`.

### What a human with Infisical admin must do

1. Infisical → Organization Settings → **Access Control** → **Identities** →
   create a machine identity, name it `bluejay-devbox`.
2. On that identity, add authentication method **AWS Auth**:
   - Allowed Principal ARNs: `arn:aws:iam::148660429236:role/bluejay-devbox`
   - Allowed Account IDs: `148660429236`
3. Give it project access, and **scope it**:
   - Project `f3c164be-b60e-4346-9867-4e394ffbf445`
   - Environment: **dev only**
   - Role: **read only** (Viewer). No write, no other environment.
4. Copy the identity ID into `INFISICAL_MACHINE_IDENTITY_ID=` in
   `cloud-init.yaml`, then re-run `bj bake` so new boxes carry it.

> **Scope it to dev, read only. Nothing else.**
> A devbox is a machine an engineer ssh-es into, that runs agents unattended,
> that is reachable from whatever coffee-shop IP was current at `bj up`. If that
> identity can read prod secrets, every one of those boxes is a prod credential
> store, which is a strictly worse outcome than the laptop OOM this project
> started from. Staging and prod environments must not be in its scope, and the
> role must not be able to write. Check this before, not after.

The identity ID is not a secret (it is a UUID naming an identity that only an
approved role ARN can assume), which is why it can live in a file in the repo.
The credential is the instance role, and that never leaves AWS.

## Baked AMI

A first boot from stock Ubuntu spends about ten minutes installing apt packages,
docker, node, python3.11, uv, honcho, just, gh, the supabase CLI, dbmate, psql
and the pinned infisical build. All of that is identical on every box, so bake
it once:

```
bj bake      # ~12 min, prints an AMI id
```

Measured, `m7i-flex.2xlarge` / 150 GB from `ami-05bac3059d9d77bd3`, the current
image: **74 s to ssh, 81 s to `/var/lib/bj-provisioned`**, against ~10 minutes
from stock Ubuntu. The 74 s is EC2 and the kernel; only the last 7 s is ours.

It launches one builder from the SSM Ubuntu parameter, runs the same
`cloud-init.yaml` every box runs, waits for `/var/lib/bj-baked`, strips
per-instance state (host keys, `authorized_keys`, `cloud-init clean`), stops it,
images it tagged `bluejay:devbox-ami=1`, and terminates the builder.

`bj up` then prefers the newest AMI carrying that tag and falls back to the SSM
Ubuntu parameter when there is none, so the tool still works in an account where
nobody has baked yet.

**Repos and secrets are not baked.** The image has tools only. `bj-clone` still
pulls repos over your forwarded ssh agent on first `bj up`, and the Infisical
token is fetched at boot onto tmpfs. That is what makes the image safe to reuse
across engineers, and it is why the whole design refuses to keep a credential on
a box.

The builder runs on a 30 GB root volume rather than 150 GB: the AMI snapshot is
then small, and `bj up` still launches at `BJ_VOLUME_GB` because cloud-init
grows the partition. `BJ_BAKE_TYPE` and `BJ_BAKE_GB` override.

Re-bake when `cloud-init.yaml` changes. Old images keep working; `resolve_ami`
just takes the newest. Delete the stale ones (`aws ec2 deregister-image`, then
delete the snapshot) or they bill for their snapshot forever.

## Cost

`m7i-flex.2xlarge` on demand in us-east-1 is $0.38304/hr (confirmed against the
AWS pricing API, not quoted from memory), plus 150 GB gp3 at $0.08/GB-month =
$12/mo per box of storage that you pay whether the box is on or off.

At 6 h/day, 21 working days, 10 engineers:

| Line | Rate | Monthly |
|---|---|---|
| Compute, 10 × 126 h | $0.38304/hr | $483 |
| Storage, 10 × 150 GB | $0.08/GB-mo | $120 |
| Data out, allow ~50 GB | $0.09/GB | $5 |
| **Total** | | **~$608** |

The $636/mo budget holds, with about $28/mo of slack for the idle timer not
catching everything and the occasional box left running through a lunch.

The whole model rests on boxes actually being off. Ten boxes left running around
the clock is $2,796/mo of compute, nearly six times the plan. If the idle
timer is ever disabled or broken, that is the cost, so treat
`journalctl -t bj-idle` as the thing to check when the bill moves.

Storage is the floor you cannot idle away: $120/mo whether anyone works or not.
The profiling run used 24 GB of 145 GB for a complete setup, so 100 GB volumes
would fit comfortably and save $40/mo. Left at 150 GB because running a dev box
out of disk costs more in engineer time than $40 buys.

## Profiling: is 32 GiB right?

Yes. Measured on a real box: 9.15 GiB for the whole stack at rest, 13.32 GiB with
a `next build` running alongside it. 16 GiB would leave under 3 GiB of headroom
for an editor and language servers, so it is not enough. No leak found.

The run also turned up two bugs that block a clean install, one of which stops
middleware from starting at all. Both are written up in `profile-results.md`,
along with the full per-service table and what could not be measured.
