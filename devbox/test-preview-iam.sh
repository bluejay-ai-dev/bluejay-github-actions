#!/usr/bin/env bash
# Proves the CI preview role can manage preview boxes and cannot touch an engineer's.
# The second half is the one that matters: a role that can terminate anything tagged is
# one bad tag away from deleting someone's work.
set -euo pipefail
ACCT=${ACCT:-148660429236}
ROLE=${ROLE:-arn:aws:iam::$ACCT:role/bluejay-preview-ci}
ARN=arn:aws:ec2:us-east-1:$ACCT:instance/i-0123456789abcdef0
fail=0

sim() { # <label> <action> <expected> [context...]
  local label=$1 action=$2 want=$3; shift 3
  local got
  if [ "$#" -gt 0 ]; then
    got=$(aws iam simulate-principal-policy --policy-source-arn "$ROLE" --action-names "$action" \
          --resource-arns "$ARN" --context-entries "$@" \
          --query 'EvaluationResults[0].EvalDecision' --output text)
  else
    got=$(aws iam simulate-principal-policy --policy-source-arn "$ROLE" --action-names "$action" \
          --resource-arns "$ARN" --query 'EvaluationResults[0].EvalDecision' --output text)
  fi
  [ "$got" = "$want" ] && printf '  ok    %-40s %s\n' "$label" "$got" \
    || { printf '  FAIL  %-40s got %s want %s\n' "$label" "$got" "$want"; fail=1; }
}
pv() { echo "ContextKeyName=ec2:ResourceTag/bluejay:preview-ticket,ContextKeyValues=$1,ContextKeyType=string"; }
ow() { echo "ContextKeyName=ec2:ResourceTag/bluejay:devbox-owner,ContextKeyValues=$1,ContextKeyType=string"; }

echo "preview boxes:"
sim "terminate" ec2:TerminateInstances allowed "$(pv ENG-578)"
sim "stop"      ec2:StopInstances      allowed "$(pv ENG-578)"
sim "start"     ec2:StartInstances     allowed "$(pv ENG-578)"

echo "must not reach an engineer's box:"
sim "terminate a devbox"       ec2:TerminateInstances implicitDeny "$(ow lorenzo_taylor)"
sim "stop a devbox"            ec2:StopInstances      implicitDeny "$(ow lorenzo_taylor)"
sim "terminate an untagged box" ec2:TerminateInstances implicitDeny
sim "terminate a non-ENG tag"   ec2:TerminateInstances implicitDeny "$(pv whatever)"

[ "$fail" = 0 ] && echo "preview IAM ok" || { echo "preview IAM WRONG" >&2; exit 1; }
