#!/usr/bin/env bash
# Asserts bluejay-devbox-engineer really does isolate engineers from each other.
# Run after any edit to the policy. Needs iam:SimulateCustomPolicy.
set -euo pipefail
ARN="${BJ_POLICY_ARN:-arn:aws:iam::148660429236:policy/bluejay-devbox-engineer}"
CALLER="${BJ_TEST_CALLER:-arn:aws:iam::148660429236:user/lorenzo_taylor}"
ME=${CALLER##*/}
INST=arn:aws:ec2:us-east-1:148660429236:instance/i-0123456789abcdef0
SG=arn:aws:ec2:us-east-1:148660429236:security-group/sg-0b4ca15bb66a0e8cc

# simulate-custom-policy caps each document at 2000 chars, so the live policy is
# split in half rather than trimmed. aws:username is passed explicitly: the
# simulator does not derive it from --caller-arn.
DOCS="$(aws iam get-policy-version --policy-arn "$ARN" \
  --version-id "$(aws iam get-policy --policy-arn "$ARN" --query Policy.DefaultVersionId --output text)" \
  --query 'PolicyVersion.Document' --output json | python3 -c '
import json,sys
s=json.load(sys.stdin)["Statement"]; h=len(s)//2
for half in (s[:h], s[h:]):
    print(json.dumps({"Version":"2012-10-17","Statement":half},separators=(",",":")))')"
D1="$(sed -n 1p <<<"$DOCS")"; D2="$(sed -n 2p <<<"$DOCS")"

fail=0
check() { # want action resource [context...]
  local want=$1 action=$2 res=$3; shift 3
  local got
  got="$(aws iam simulate-custom-policy --policy-input-list "$D1" "$D2" --caller-arn "$CALLER" \
    --action-names "$action" ${res:+--resource-arns "$res"} \
    --context-entries "ContextKeyName=aws:username,ContextKeyValues=$ME,ContextKeyType=string" "$@" \
    --query 'EvaluationResults[0].EvalDecision' --output text)"
  [ "$got" = "$want" ] && printf 'ok    %-40s %s\n' "$action" "$got" \
    || { printf 'FAIL  %-40s got %s want %s\n' "$action" "$got" "$want"; fail=1; }
}
owner() { echo "ContextKeyName=ec2:ResourceTag/bluejay:devbox-owner,ContextKeyValues=$1,ContextKeyType=string"; }
reqowner() { echo "ContextKeyName=aws:RequestTag/bluejay:devbox-owner,ContextKeyValues=$1,ContextKeyType=string"; }
itype() { echo "ContextKeyName=ec2:InstanceType,ContextKeyValues=$1,ContextKeyType=string"; }

check allowed      ec2:DescribeInstances ""
check allowed      ec2:StopInstances     "$INST" "$(owner "$ME")"
check allowed      ec2:TerminateInstances "$INST" "$(owner "$ME")"
check implicitDeny ec2:StopInstances     "$INST" "$(owner alice)"
# strict binding: no fleets. "$ME-2" is someone else's box as far as IAM cares.
check implicitDeny ec2:StopInstances     "$INST" "$(owner "$ME-2")"
check allowed      ec2:RunInstances      "$INST" "$(reqowner "$ME")" "$(itype m7i-flex.2xlarge)"
check implicitDeny ec2:RunInstances      "$INST" "$(reqowner alice)"  "$(itype m7i-flex.2xlarge)"
check implicitDeny ec2:RunInstances      "$INST" "$(reqowner "$ME")" "$(itype m7i-flex.24xlarge)"
check allowed      ec2:AssociateIamInstanceProfile "$INST" "$(owner "$ME")"
check implicitDeny ec2:AssociateIamInstanceProfile "$INST" "$(owner alice)"
check allowed      iam:PassRole arn:aws:iam::148660429236:role/bluejay-devbox \
  'ContextKeyName=iam:PassedToService,ContextKeyValues=ec2.amazonaws.com,ContextKeyType=string'
check implicitDeny iam:PassRole arn:aws:iam::148660429236:role/AdminRole \
  'ContextKeyName=iam:PassedToService,ContextKeyValues=ec2.amazonaws.com,ContextKeyType=string'
check allowed      ec2:AuthorizeSecurityGroupIngress "$SG" 'ContextKeyName=ec2:ResourceTag/bluejay:managed-by,ContextKeyValues=bj,ContextKeyType=string'
check implicitDeny ec2:AuthorizeSecurityGroupIngress arn:aws:ec2:us-east-1:148660429236:security-group/sg-0aaaaaaaaaaaaaaaa
check implicitDeny ec2:CreateSecurityGroup "$SG"
# Per-engineer key pairs. Needs iam/devbox-engineer-keypair-delta.json applied to the
# live policy; until then these three fail, which is the point.
KP=arn:aws:ec2:us-east-1:148660429236:key-pair
check allowed      ec2:CreateKeyPair "$KP/bluejay-devbox-$ME"
check implicitDeny ec2:CreateKeyPair "$KP/bluejay-devbox-alice"
# the shared pair must not be deletable by an engineer while other boxes still boot on it
check implicitDeny ec2:DeleteKeyPair "$KP/bluejay-devbox"
check allowed      ec2:DescribeSecurityGroupRules ""
check implicitDeny iam:AttachUserPolicy   "arn:aws:iam::148660429236:user/$ME"

exit $fail
