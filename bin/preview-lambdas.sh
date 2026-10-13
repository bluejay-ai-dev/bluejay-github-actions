#!/usr/bin/env bash
# A preview's own copy of every queue-fed lambda: main's image, sandbox's settings, the
# preview's database. Each preview has its own database branch, so a shared function would
# read the wrong data. Idle functions and queues cost nothing.
#
#   preview-lambdas.sh up <env> <db_url> <supabase_url> <service_key> <middleware_url>
#       prints KEY=VALUE lines for the preview's Railway services
#   preview-lambdas.sh down <env>
#
# PR_FUNCTIONS="evaluator:pr745_evaluator ..." runs a kind on that PR function's image instead.
set -euo pipefail
export AWS_REGION=us-west-1 AWS_DEFAULT_REGION=us-west-1

# kind:image from:settings from:variable that hands it to Railway
KINDS="evaluator:evaluator:sandbox_evaluator:SQS_EVAL_QUEUE_URL
dispatcher:livekit_dispatcher:sandbox_livekit_dispatcher:SQS_QUEUE_URL
rag:rag_ingestion_service:sandbox_rag_ingestion_service:RAG_INGESTION_SQS_QUEUE_URL
notification:notification_service:dev_notification_service:NOTIFICATION_SQS_QUEUE_URL
text_agent:text_agent:sandbox_text_agent:TEXT_AGENT_LAMBDA_FUNCTION_NAME"
# the queue each settings-source function reads, to copy its queue and mapping shape
src_queue() { case "$1" in
  evaluator) echo SandboxEvalQueue.fifo ;; dispatcher) echo SandboxSimulationQueue.fifo ;;
  rag) echo SandboxRagIngestionQueue.fifo ;; notification) echo DevNotificationQueue.fifo ;; esac; }

cmd=$1 env=$2
[[ "$env" =~ ^[a-z0-9-]+$ ]] || { echo "bad env name: $env" >&2; exit 2; }
acct=$(aws sts get-caller-identity --query Account --output text)

if [ "$cmd" = down ]; then
  while IFS=: read -r kind _ _ _; do
    fn="$env-$kind"
    for u in $(aws lambda list-event-source-mappings --function-name "$fn" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null); do
      aws lambda delete-event-source-mapping --uuid "$u" >/dev/null
    done
    aws lambda delete-function --function-name "$fn" >/dev/null 2>&1 && echo "deleted $fn" >&2 || true
    q=$(aws sqs get-queue-url --queue-name "$fn.fifo" --query QueueUrl --output text 2>/dev/null) \
      && aws sqs delete-queue --queue-url "$q" && echo "deleted $fn.fifo" >&2 || true
  done <<<"$KINDS"
  exit 0
fi

db=$3 supabase=$4 svckey=$5 mw=$6
notif_url="https://sqs.$AWS_REGION.amazonaws.com/$acct/$env-notification.fifo"

while IFS=: read -r kind image_from cfg_from var; do
  fn="$env-$kind"
  for pair in ${PR_FUNCTIONS:-}; do [ "${pair%%:*}" = "$kind" ] && image_from=${pair#*:}; done
  image=$(aws lambda get-function --function-name "$image_from" --query Code.ImageUri --output text)
  cfg=$(aws lambda get-function-configuration --function-name "$cfg_from")
  sm=$(jq -r '.Environment.Variables.SECRETS_MANAGER_SECRET_ID // empty' <<<"$cfg")
  extra='{}'
  [ -z "$sm" ] || extra=$(aws secretsmanager get-secret-value --secret-id "$sm" --query SecretString --output text)
  # Secrets Manager would override the preview's database at startup, so fold it in and drop the link
  jq -c --argjson x "$extra" --arg db "$db" --arg sb "$supabase" --arg sk "$svckey" --arg mw "$mw" \
        --arg n "$notif_url" --arg m "https://sqs.$AWS_REGION.amazonaws.com/$acct/SandboxUsageMeteringQueue" '
    {Variables: ((.Environment.Variables // {}) + $x | del(.SECRETS_MANAGER_SECRET_ID, .SECRETS_ROTATED_AT)
      | if .DATABASE_URL then .DATABASE_URL = ((.DATABASE_URL|split("://")[0]) + "://" + ($db|split("://")[1])) else . end
      | if .SUPABASE_URL then .SUPABASE_URL = $sb else . end
      | if .SUPABASE_SERVICE_KEY then .SUPABASE_SERVICE_KEY = $sk else . end
      | if .MIDDLEWARE_URL then .MIDDLEWARE_URL = $mw else . end
      | if .SQS_NOTIFICATION_QUEUE_URL then .SQS_NOTIFICATION_QUEUE_URL = $n else . end
      | if .METRONOME_SQS_QUEUE_URL then .METRONOME_SQS_QUEUE_URL = $m else . end)}' <<<"$cfg" > /tmp/env-$kind.json

  if aws lambda get-function --function-name "$fn" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$fn" --image-uri "$image" >/dev/null
    aws lambda wait function-updated-v2 --function-name "$fn"
    aws lambda update-function-configuration --function-name "$fn" --environment "file:///tmp/env-$kind.json" >/dev/null
  else
    aws lambda create-function --function-name "$fn" --package-type Image --code "ImageUri=$image" \
      --role "$(jq -r .Role <<<"$cfg")" --architectures "$(jq -r '.Architectures[0]' <<<"$cfg")" \
      --timeout "$(jq -r .Timeout <<<"$cfg")" --memory-size "$(jq -r .MemorySize <<<"$cfg")" \
      --environment "file:///tmp/env-$kind.json" --tags "bluejay:preview=$env" >/dev/null
  fi
  aws lambda wait function-updated-v2 --function-name "$fn"
  rm -f /tmp/env-$kind.json

  sq=$(src_queue "$kind")
  if [ -z "$sq" ]; then echo "$var=$fn"; continue; fi
  sattr=$(aws sqs get-queue-attributes --queue-url "$(aws sqs get-queue-url --queue-name "$sq" --query QueueUrl --output text)" \
            --attribute-names VisibilityTimeout ContentBasedDeduplication MessageRetentionPeriod --query Attributes)
  q=$(aws sqs create-queue --queue-name "$fn.fifo" --query QueueUrl --output text \
        --attributes "$(jq -c '. + {FifoQueue:"true"}' <<<"$sattr")")
  # SQS refuses a mapping whose visibility window is shorter than the function's timeout
  vt=$(jq -r .VisibilityTimeout <<<"$sattr"); ft=$(jq -r .Timeout <<<"$cfg")
  [ "$vt" -ge "$ft" ] || aws sqs set-queue-attributes --queue-url "$q" --attributes "VisibilityTimeout=$ft"
  arn="arn:aws:sqs:$AWS_REGION:$acct:$fn.fifo"
  if [ -z "$(aws lambda list-event-source-mappings --function-name "$fn" --event-source-arn "$arn" --query 'EventSourceMappings[0].UUID' --output text | grep -v None)" ]; then
    batch=$(aws lambda list-event-source-mappings --function-name "$cfg_from" --query 'EventSourceMappings[0].BatchSize' --output text)
    aws lambda create-event-source-mapping --function-name "$fn" --event-source-arn "$arn" \
      --batch-size "${batch/None/1}" >/dev/null
  fi
  echo "$var=$q"
done <<<"$KINDS"
echo "SQS_NOTIFICATION_QUEUE_URL=$notif_url"
