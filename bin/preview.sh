#!/usr/bin/env bash
# Per-ticket preview environments. One EC2 box per ticket that runs ONLY the repos the
# ticket changes; everything it does not change points at shared sandbox infrastructure.
#   preview.sh resolve <ticket>   repos this ticket changes, and the branch to deploy
#   preview.sh up      <ticket>   launch or refresh the box, print its https base url
#   preview.sh down    <ticket>   terminate it
#   preview.sh url     <ticket>
set -euo pipefail

ORG=${ORG:-bluejay-ai-dev}
REGION=${AWS_REGION:-us-east-1}
# The CI policy allows exactly this type, so changing it here means changing the policy too.
INSTANCE_TYPE=${PREVIEW_INSTANCE_TYPE:-m7i-flex.2xlarge}
PROFILE=${PREVIEW_INSTANCE_PROFILE:-bluejay-preview}
SG_NAME=${PREVIEW_SG_NAME:-bluejay-preview}
TTL_MIN=${PREVIEW_TTL_MIN:-480}
TAG=bluejay:preview-ticket
DOMAIN=${PREVIEW_DOMAIN:-preview.getbluejay.ai}
ZONE_ID=${PREVIEW_HOSTED_ZONE_ID:-}

# What a box can actually run, so the only repos worth resolving. evals, text_agent,
# livekit_dispatcher and emails-lambda are lambdas with no standalone process, and docs is
# not the app, so a ticket touching only those gets no box.
REPOS=${PREVIEW_REPOS:-"bluejay_middleware bluejay_frontend_v2 livekit_agent"}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_PAGER=""
aws() { command aws --region "$REGION" "$@"; }
die() { echo "$*" >&2; exit 1; }
inf() { echo "==> $*" >&2; }

# The ticket reaches a jq program, a dns name and a file the box sources as shell, so it is
# checked here and not only in the workflow that usually passes it.
need() { [[ "${1:-}" =~ ^ENG-[0-9]+$ ]] || die "not a ticket id: ${1:-}"; }

# --- resolution --------------------------------------------------------------

# Same rule and the same query as `bj branches`: the open PR whose TITLE carries the ticket
# id decides the branch, and a head branch ending in --np has opted out. A repo with no such
# PR is not changed by this ticket, so it is not deployed and the preview borrows the shared
# one instead. Per repo rather than one search: gh search has no head-ref field.
resolve() { # <ticket> -> "repo<TAB>branch" per line
  local repo br
  for repo in $REPOS; do
    br=$(gh pr list -R "$ORG/$repo" --state open --limit 50 --json title,headRefName \
         -q "first(.[] | select((.title | test(\"(^|[^A-Za-z0-9])$1([^0-9]|\$)\";\"i\"))
                            and (.headRefName | endswith(\"--np\") | not))
                  | .headRefName) // \"\"" 2>/dev/null)
    [ -n "$br" ] && printf '%s\t%s\n' "$repo" "$br"
  done
  :
}

# --- box lifecycle -----------------------------------------------------------

instance() { # <ticket> [field]
  aws ec2 describe-instances \
    --filters "Name=tag:$TAG,Values=$1" "Name=instance-state-name,Values=pending,running" \
    --query "Reservations[].Instances[].${2:-InstanceId}" --output text \
  | tr '\t' '\n' | head -1 | sed 's/^None$//'
}

launch() { # <ticket> -> instance id
  local ami sg
  ami=$(aws ec2 describe-images --owners self \
        --filters "Name=tag:bluejay:devbox-ami,Values=1" "Name=state,Values=available" \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  [ -n "$ami" ] && [ "$ami" != None ] || die "no devbox AMI in this account; run 'bj bake'"
  sg=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" \
       --query 'SecurityGroups[0].GroupId' --output text)
  [ -n "$sg" ] && [ "$sg" != None ] || die "security group $SG_NAME does not exist"

  # No key pair on purpose: the only way in is EC2 Instance Connect, whose keys expire in
  # 60s, so nothing durable authorises access to a box CI created and nobody owns.
  # A preview that outlives its review is pure cost, so it kills itself.
  aws ec2 run-instances --image-id "$ami" --instance-type "$INSTANCE_TYPE" \
    --security-group-ids "$sg" --count 1 \
    --iam-instance-profile "Name=$PROFILE" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --instance-initiated-shutdown-behavior terminate \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=100,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}" \
    --user-data "$(printf '#!/bin/bash\nshutdown -h +%s\n' "$TTL_MIN")" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=bluejay-preview-$1},{Key=$TAG,Value=$1}]" \
      "ResourceType=volume,Tags=[{Key=$TAG,Value=$1}]" \
    --query 'Instances[0].InstanceId' --output text
}

# Instance Connect keys are valid for 60s, so one is pushed before every connection rather
# than once, and nothing durable authorises access to the box afterwards.
# ponytail: the host key is trusted blind, because a fresh box has no key we have seen and
# no known-hosts survives a run. Read it from ec2:GetConsoleOutput if the private source
# being shipped over that first connection is worth the extra IAM permission.
KEYDIR=""
sshx() { # <instance-id> <host> <cmd...>
  local id=$1 host=$2; shift 2
  [ -n "$KEYDIR" ] || { KEYDIR=$(mktemp -d); ssh-keygen -q -t ed25519 -N '' -f "$KEYDIR/k"; }
  aws ec2-instance-connect send-ssh-public-key --instance-id "$id" \
    --instance-os-user ubuntu --ssh-public-key "file://$KEYDIR/k.pub" >/dev/null
  ssh -i "$KEYDIR/k" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
      "ubuntu@$host" "$@"
}

wait_ssh() { # <instance-id> <host>
  local i
  for i in $(seq 1 40); do sshx "$1" "$2" true </dev/null 2>/dev/null && return 0; sleep 10; done
  die "ssh never came up on $2"
}

# A zone we own, not a wildcard DNS service. Preview hostnames end up in a CORS allowlist
# and in an OAuth redirect, and anyone can point an xip-style name at their own server, so
# the names have to be ones only we can create.
hostnames() { # <ticket> -> "base api"
  local t; t=$(echo "$1" | tr 'A-Z' 'a-z')
  echo "$t.$DOMAIN api-$t.$DOMAIN"
}

dns() { # <upsert|delete> <ip> <name...>
  local act ip=$2; act=$(echo "$1" | tr 'a-z' 'A-Z'); shift 2
  local changes name
  for name in "$@"; do
    changes+="${changes:+,}{\"Action\":\"$act\",\"ResourceRecordSet\":{\"Name\":\"$name\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$ip\"}]}}"
  done
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --change-batch "{\"Changes\":[$changes]}" --query 'ChangeInfo.Status' --output text
}

# A box that hit its own shutdown timer terminated without running `down`, so its A record
# outlives it and eventually points at whatever gets that public IP next. Sweeping on every
# `up` fixes that with no scheduled job: any A record with no running preview behind it goes.
# The zone must hold nothing but previews for this to be safe.
reap_dns() {
  local live; live=$(aws ec2 describe-instances \
    --filters "Name=tag-key,Values=$TAG" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].PublicIpAddress' --output text | tr '\t' '\n')
  aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Type=='A'].[Name,ResourceRecords[0].Value]" --output text \
  | while read -r name ip; do
      # An alias record has no value to compare or to delete with. Leave it alone.
      case "$ip" in ""|None) continue ;; esac
      grep -qxF "$ip" <<<"$live" && continue
      inf "dns reap ${name%.} ($ip has no preview)"
      dns delete "$ip" "${name%.}" >/dev/null || true
    done
}

cmd_up() { # <ticket>
  local ticket=$1 plan fresh id ip host base api work repo branch
  plan=$(mktemp); resolve "$ticket" > "$plan"
  fresh=$(cut -f1 "$plan" | tr '\n' ' ')
  [ -n "${fresh// /}" ] || { echo "no open PR on $ticket changes a repo a box can run"; return 0; }
  inf "fresh: $fresh"
  [ -n "${PREVIEW_SHARED_API_URL:-}" ] || die "PREVIEW_SHARED_API_URL is unset"
  [ -n "$ZONE_ID" ] || die "PREVIEW_HOSTED_ZONE_ID is unset"
  reap_dns

  id=$(instance "$ticket")
  if [ -z "$id" ]; then id=$(launch "$ticket"); inf "launched $id"; else inf "reusing $id"; fi
  aws ec2 wait instance-running --instance-ids "$id"
  ip=$(instance "$ticket" PublicIpAddress); host=$(instance "$ticket" PublicDnsName)
  read -r base api <<<"$(hostnames "$ticket")"
  # Before the box is told its names: Caddy asks for a certificate as soon as it is
  # configured, and a name that does not resolve yet burns a Let's Encrypt failure.
  inf "dns $base, $api -> $ip"
  dns upsert "$ip" "$base" "$api" >/dev/null
  wait_ssh "$id" "$host"

  # CI clones, the box never does. That keeps the GitHub token on the ephemeral runner, and
  # dropping .git means it cannot reach the box through a remote url either. gh reads the
  # token from the environment, so it never lands in argv or in .git/config.
  work=$(mktemp -d)
  while IFS=$'\t' read -r repo branch; do
    inf "cloning $repo@$branch"
    gh repo clone "$ORG/$repo" "$work/$repo" -- --quiet --depth 1 --branch "$branch"
    rm -rf "$work/$repo/.git"
  done < "$plan"

  inf "shipping to $host"
  tar czf - -C "$work" . | sshx "$id" "$host" \
    'sudo mkdir -p /opt/preview && sudo chown ubuntu:ubuntu /opt/preview && tar xzf - -C /opt/preview'
  rm -rf "$work" "$plan"

  # Nothing written here is a secret. Real credentials reach the box only through Infisical,
  # whose preview environment is the only scope a preview identity may read.
  sshx "$id" "$host" 'cat > /tmp/preview.env' <<EOF
TICKET=$ticket
FRESH="$fresh"
BASE_HOST=$base
API_HOST=$api
SHARED_API_URL=$PREVIEW_SHARED_API_URL
INFISICAL_PROJECT_ID=${PREVIEW_INFISICAL_PROJECT_ID:-}
INFISICAL_MACHINE_IDENTITY_ID=${PREVIEW_INFISICAL_IDENTITY_ID:-}
EOF
  sshx "$id" "$host" 'cat > /tmp/preview-boot.sh && chmod +x /tmp/preview-boot.sh' < "$HERE/preview-boot.sh"
  sshx "$id" "$host" 'sudo /tmp/preview-boot.sh' </dev/null

  echo "https://$base"
}

cmd_down() { # <ticket>
  local id ip base api; id=$(instance "$1")
  [ -n "$id" ] || { echo "no box for $1"; return 0; }
  ip=$(instance "$1" PublicIpAddress)
  read -r base api <<<"$(hostnames "$1")"
  # Records first. A name still pointing at a released public IP is someone else's box.
  [ -n "$ip" ] && [ -n "$ZONE_ID" ] && dns delete "$ip" "$base" "$api" >/dev/null || true
  aws ec2 terminate-instances --instance-ids "$id" \
    --query 'TerminatingInstances[0].CurrentState.Name' --output text
}

cmd_url() { # <ticket>
  [ -n "$(instance "$1")" ] || { echo "no box for $1" >&2; return 1; }
  hostnames "$1" | cut -d' ' -f1 | sed 's|^|https://|'
}

case "${1:-}" in
  resolve) shift; need "${1:-}"; resolve "$1" ;;
  up)      shift; need "${1:-}"; cmd_up "$1" ;;
  down)    shift; need "${1:-}"; cmd_down "$1" ;;
  url)     shift; need "${1:-}"; cmd_url "$1" ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac
