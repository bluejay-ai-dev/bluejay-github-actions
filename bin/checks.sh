#!/usr/bin/env bash
# Deterministic PR checks, one subcommand per check.
# Every check is a no-op with a message when it does not apply, so a repo with
# no migrations and no prisma schema still runs the whole list and passes.
set -euo pipefail

BASE=${BASE:-main}
REF="origin/$BASE"
MIG=db/migrations
VIDEO='node-type="video"|loom\.com/share/'
DBMATE_VERSION=v2.33.0
DBMATE_SHA256=dfd4027141b6e4357158099bdfe6c02b286af70f8e49057937744cf80b38ea1c

skip() { echo "skip: $*"; exit 0; }
die()  { echo "FAIL: $*"; exit 1; }

added()     { git diff --name-only --diff-filter=A "$REF...HEAD" -- "$MIG/*.sql"; }
ticket_id() { grep -oiE '\bENG-[0-9]+\b' <<<"${TITLE:-}" | head -1 | tr a-z A-Z || true; }
versions()  { sed 's#.*/##' | cut -d_ -f1 | sort -n; }  # not xargs basename, GNU xargs runs it on empty input

linear() {  # linear <ENG-123> <fields> -> raw graphql response
  curl -sS https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" -H 'content-type: application/json' \
    -d "$(jq -nc --arg i "$1" --arg q "query(\$i:String!){issue(id:\$i){$2}}" '{query:$q,variables:{i:$i}}')"
}

need_base() { git rev-parse --verify -q "$REF" >/dev/null || die "$REF is not fetched, checkout needs fetch-depth: 0"; }

c_ticket_sane() {
  local n id st
  n=$(grep -oiE '\bENG-[0-9]+\b' <<<"${TITLE:-}" | sort -u | wc -l | tr -d ' ')
  [ "$n" = 1 ] || die "title carries $n ticket ids, want exactly 1: ${TITLE:-<empty title>}"
  id=$(ticket_id)
  echo "ok: title carries $id"
  [ -n "${LINEAR_API_KEY:-}" ] || skip "LINEAR_API_KEY not set, did not confirm $id in Linear"
  st=$(linear "$id" 'state{name}' | jq -r '.data.issue.state.name // "MISSING"')
  case "$st" in
    MISSING)       die "$id does not exist in Linear" ;;
    Done|Canceled) die "$id is $st" ;;
  esac
  echo "ok: $id is $st"
}

c_video() {
  local id repos="" d
  id=$(ticket_id)
  [ -n "$id" ] || skip "no ticket id in the title"
  [ "${ADDITIONS:-0}" -gt 100 ] || skip "${ADDITIONS:-0} additions, under 100, no video required"
  if [ -n "${GH_TOKEN:-}" ]; then
    repos=$(gh search prs --owner "${OWNER:-${GITHUB_REPOSITORY_OWNER:-}}" --match title "$id" --limit 50 \
              --json repository,title \
              -q ".[] | select(.title | test(\"\\\\b$id\\\\b\"; \"i\")) | .repository.name" 2>/dev/null | tr '\n' ' ' || true)
  else
    echo "no GH_TOKEN, the PR set is this repo only"
  fi
  repos="$repos ${GITHUB_REPOSITORY##*/}"
  case "$repos" in *frontend*) ;; *) skip "no frontend repo on $id (${repos# }), no video required" ;; esac
  if grep -qE "$VIDEO" <<<"${BODY:-}"; then echo "ok: video in the PR body"; return 0; fi
  [ -n "${LINEAR_API_KEY:-}" ] || skip "no video in the PR body and LINEAR_API_KEY not set, did not read $id"
  d=$(linear "$id" description | jq -r '.data.issue.description // ""')
  grep -qE "$VIDEO" <<<"$d" || die "frontend change with ${ADDITIONS} additions needs a video on $id or in the PR body"
  echo "ok: video on $id"
}

# dbmate keys on the version prefix and skips applied versions, so an edited
# migration never runs again anywhere it already ran.
c_migrations_immutable() {
  need_base
  local m
  m=$(git diff --name-only --diff-filter=M "$REF...HEAD" -- "$MIG/*.sql" || true)
  [ -z "$m" ] || die "already applied on $BASE and edited, dbmate will never re-run it: $m"
  echo "ok: no migration on $BASE was edited"
}

c_migrations_newest() {
  need_base
  local new top
  new=$(added | versions | head -1)
  [ -n "$new" ] || skip "no new migrations"
  top=$(git ls-tree --name-only "$REF" "$MIG/" 2>/dev/null | versions | tail -1)
  [ -n "$top" ] || skip "$BASE has no migrations, nothing to be newer than"
  [ "$new" -gt "$top" ] || die "version $new is not above $top on $BASE"
  echo "ok: oldest new version $new is above $top on $BASE"
}

c_migrations_have_down() {
  need_base
  local f n=0
  for f in $(added); do
    sed -n '/migrate:down/,$p' "$f" | tail -n +2 | grep -qE '[a-zA-Z]' || die "empty or missing migrate:down in $f"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || skip "no new migrations"
  echo "ok: $n new migrations all have a down"
}

c_migrations_round_trip() {
  need_base
  local n
  n=$(added | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] || skip "no new migrations"
  [ -n "${DATABASE_URL:-}" ] || skip "no DATABASE_URL, needs the pgvector/pgvector:pg15 service"

  if ! command -v dbmate >/dev/null; then
    sudo curl -fsSL -o /usr/local/bin/dbmate \
      "https://github.com/amacneil/dbmate/releases/download/$DBMATE_VERSION/dbmate-linux-amd64"
    echo "$DBMATE_SHA256  /usr/local/bin/dbmate" | sha256sum -c -
    sudo chmod +x /usr/local/bin/dbmate
  fi

  # Supabase-ish bootstrap, same as db-ci.yml. Migrations reference these roles,
  # schemas and extensions and fail on a bare postgres without them.
  psql "$DATABASE_URL" <<'EOSQL'
DO $$ BEGIN CREATE ROLE anon;          EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role;  EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (id uuid primary key default gen_random_uuid(), email text);
CREATE EXTENSION IF NOT EXISTS vector      WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto    WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
EOSQL

  # pg_dump 18 stamps a random nonce on the \restrict lines, so two dumps of the
  # same schema differ unless they are filtered out.
  dump() { pg_dump "$DATABASE_URL" --schema-only -O -x | grep -vE '^\\(un)?restrict '; }
  up()   { dbmate -d "$MIG" --no-dump-schema up || die "$1"; }
  down() { local i; for i in $(seq "$1"); do dbmate -d "$MIG" --no-dump-schema down || die "down failed on rollback $i of $1"; done; }

  # rm first: checkout of a path only overwrites, it would leave the PR's new
  # files behind and the base build would apply them too.
  rm -rf "$MIG"
  git checkout "$REF" -- "$MIG" 2>/dev/null || mkdir -p "$MIG"
  up "$BASE's own migrations do not apply"; dump > /tmp/base1.sql

  git checkout HEAD -- "$MIG"
  up "the new migrations do not apply on $BASE's schema"; dump > /tmp/head1.sql

  down "$n"; dump > /tmp/base2.sql
  up "up is not replayable after down"; dump > /tmp/head2.sql

  diff -u /tmp/base1.sql /tmp/base2.sql || die "down is not the inverse of up"
  diff -u /tmp/head1.sql /tmp/head2.sql || die "up is not replayable after down"
  echo "ok: $n migrations round trip up, down, up on $BASE's schema"
}

c_rls() {
  need_base
  local f t n=0
  for f in $(added); do
    for t in $(grep -oiE 'CREATE TABLE (IF NOT EXISTS )?public\.[a-z0-9_]+' "$f" | awk '{print $NF}'); do
      grep -qiE "ALTER TABLE .*${t##*.}.* ENABLE ROW LEVEL SECURITY" "$f" || die "$t has no ENABLE ROW LEVEL SECURITY in $f"
      n=$((n + 1))
    done
  done
  [ "$n" -gt 0 ] || skip "no new public tables"
  echo "ok: $n new public tables all enable RLS"
}

c_codegen() {
  local ran=0
  if [ -f prisma/schema.prisma ]; then npx --yes prisma generate >/dev/null; ran=1; fi
  if [ -f package.json ] && jq -e '.scripts.codegen' package.json >/dev/null 2>&1; then npm run codegen >/dev/null; ran=1; fi
  [ "$ran" = 1 ] || skip "no prisma schema and no codegen script"
  git diff --exit-code || die "codegen produced a diff, commit it"
  echo "ok: codegen leaves no diff"
}

c_env_vars() {
  need_base
  local added_vars v have fail=0 checked=0
  added_vars=$(git diff "$REF...HEAD" | grep '^+' \
    | grep -oE "(os\.environ\[|os\.getenv\(|process\.env\.)['\"]?[A-Z][A-Z0-9_]{3,}" \
    | grep -oE '[A-Z][A-Z0-9_]{3,}$' | sort -u || true)
  [ -n "$added_vars" ] || skip "no newly referenced env vars"
  echo "newly referenced: $(tr '\n' ' ' <<<"$added_vars")"

  if [ -n "${INFISICAL_TOKEN:-}" ] && command -v infisical >/dev/null; then
    have=$(infisical secrets --env local --silent 2>/dev/null | awk '{print $2}')
    for v in $added_vars; do grep -qx "$v" <<<"$have" || { echo "FAIL: $v missing in infisical local"; fail=1; }; done
    checked=1
  elif [ -n "${INFISICAL_TOKEN:-}" ]; then
    # Token present, CLI absent. Skipping here is the worst outcome: the check reports
    # green having verified nothing, which is how a missing env var reaches production.
    die "INFISICAL_TOKEN is set but the infisical CLI is not installed; this check would pass without verifying anything"
  else
    echo "skip: no INFISICAL_TOKEN, did not check infisical local"
  fi

  if [ -n "${RAILWAY_TOKEN:-}" ] && [ -n "${RAILWAY_PROD_SERVICE:-}" ]; then
    have=$(curl -sS https://backboard.railway.com/graphql/v2 \
      -H "Authorization: Bearer $RAILWAY_TOKEN" -H 'content-type: application/json' \
      -d "$(jq -nc --arg s "$RAILWAY_PROD_SERVICE" '{query:"query($s:String!){variables(serviceId:$s)}",variables:{s:$s}}')" \
      | jq -r '.data.variables // {} | keys[]' 2>/dev/null || true)
    for v in $added_vars; do grep -qx "$v" <<<"$have" || { echo "FAIL: $v missing on the prod railway service"; fail=1; }; done
    checked=1
  else
    echo "skip: no RAILWAY_TOKEN or RAILWAY_PROD_SERVICE, did not check prod railway"
  fi
  [ "$checked" = 1 ] || skip "no token for either source, nothing was verified"
  [ "$fail" = 0 ] || exit 1
  echo "ok: every new env var is defined"
}

# NOT WIRED INTO pr-checks.yml, deliberately. This exists as the classifier the phase
# runner will call at DEPLOY time, where it can just order the migration correctly
# instead of making a person declare a phase and failing their PR for forgetting.
# Keeping it runnable so the rule stays tested; see "Rollback and merge order".
#
# The rule it encodes would have caught 2026-09-02. All four other migration checks pass on a
# well-formed DROP COLUMN, because the migration was not malformed, it was applied at the
# wrong moment: db-migrate runs on the push while Railway takes minutes to roll, so the
# old code reads a column that is already gone. Nothing that reads a diff can see timing,
# so the diff has to carry the intent instead.
c_migrations_expand_only() {
  need_base
  local f up bad=0 files
  files=$(added)
  [ -n "$files" ] || skip "no new migrations"
  for f in $files; do
    [ -f "$f" ] || continue
    # Only the up matters. A down is allowed to be destructive, that is its job.
    up=$(sed -n '/^-- *migrate:up/,/^-- *migrate:down/p' "$f")
    # Comments stripped first, or a sentence mentioning a dropped column trips this.
    up=$(sed 's/--.*$//' <<<"$up")
    local hits
    hits=$(grep -oniE 'DROP[[:space:]]+(COLUMN|TABLE|TYPE|VIEW|MATERIALIZED[[:space:]]+VIEW|FUNCTION)|SET[[:space:]]+NOT[[:space:]]+NULL|ALTER[[:space:]+COLUMN[^,;]*[[:space:]]TYPE[[:space:]]|RENAME[[:space:]]+(COLUMN|TO)' <<<"$up" || true)
    [ -n "$hits" ] || continue
    # Declared contract means the runner holds it until every service in `after:` is
    # fully rolled, so shipping it with its code is fine. Undeclared means it races.
    if grep -qiE '^[[:space:]]*--[[:space:]]*bluejay:phase[[:space:]]+contract' "$f"; then
      echo "ok: $(basename "$f") is declared contract, it will run after the deploy"
      continue
    fi
    echo "FAIL: $(basename "$f") changes the schema in a way old code cannot survive:"
    sed 's/^/        /' <<<"$hits"
    bad=1
  done
  [ "$bad" = 0 ] || {
    cat >&2 <<'EOF'

  db-migrate applies this seconds after merge; Railway takes minutes to roll. Until it
  finishes, the running code still reads what this removes. That took prod sign-in down
  on 2026-09-02.

  Either split it, ship the code that stops using the column first and drop it in a
  later PR, or declare the phase so it runs after the deploy instead of racing it:

      -- migrate:up
      -- bluejay:phase contract
      ALTER TABLE ... DROP COLUMN ...
EOF
    exit 1
  }
  echo "ok: every new migration is safe for code that has not rolled yet"
}

c_deps_bounded() {
  need_base
  local bad
  bad=$(git diff "$REF...HEAD" -- requirements.txt | grep '^+[^+]' | grep -E '>=' | grep -v '<' || true)
  [ -z "$bad" ] || { echo "FAIL: unbounded, a major bump breaks a clean install:"; echo "$bad"; exit 1; }
  echo "ok: no unbounded requirement added"
}

cmd=${1:-}
case "$cmd" in
  ticket-sane|video|migrations-immutable|migrations-newest|migrations-have-down|\
  migrations-round-trip|migrations-expand-only|rls|codegen|env-vars|deps-bounded) "c_${cmd//-/_}" ;;
  *) echo "usage: checks.sh <ticket-sane|video|migrations-immutable|migrations-newest|migrations-have-down|migrations-round-trip|migrations-expand-only|rls|codegen|env-vars|deps-bounded>"; exit 2 ;;
esac
