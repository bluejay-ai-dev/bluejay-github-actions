# GitHub Actions

Gate your CI/CD pipeline with real agent performance tests

Run Bluejay simulations in GitHub Actions and fail CI if your agent doesn't meet quality standards. Just like unit tests, but for AI agents.

**Key capabilities:**

- 🚨 Fail CI if score drops below your threshold
- 🔍 Automatically test every PR and commit
- ⚡ Zero-install; runs on GitHub-hosted runners
- 🎯 Override prompts, knowledge bases, and digital humans per run

## Before Starting

You'll need:

1. **Bluejay API Key** – Get yours from the [Bluejay dashboard](https://app.getbluejay.ai/developers)
2. **Simulation ID** – Create a simulation in Bluejay first with your test scenarios and digital humans. The simulation defines what conversations your agent will be tested on.

## Quick Start

### Step 1: Add your API key and variables

Go to: `Settings → Secrets and variables → Actions`

**Add a Secret:**

- Click `New repository secret`
- Name: `BLUEJAY_API_KEY`
- Value: Your API key from the [developers page](https://app.getbluejay.ai/developers)

**Add Variables:**

- Click the `Variables` tab
- Click `New repository variable`
- Add the following:

| Variable Name | Value | Required |
|--------------|-------|----------|
| `BLUEJAY_SIMULATION_ID` | Your simulation ID (e.g., `sim_12345`) | ✅ Yes |
| `BLUEJAY_MIN_SCORE` | Minimum passing score (e.g., `80`) | No |
| `BLUEJAY_PROMPT_ID` | Prompt override ID | No |
| `BLUEJAY_KB_ID` | Knowledge base override ID | No |
| `BLUEJAY_DIGITAL_HUMAN_IDS` | Comma-separated Digital Human IDs | No |
| `BLUEJAY_PHONE_NUMBER` | Phone number override | No |
| `BLUEJAY_SIP_URI` | SIP URI override | No |

### Step 2: Create your workflow

Add `.github/workflows/bluejay-tests.yml` to your repo:

```yaml
name: Agent Tests

on:
  workflow_dispatch:
    inputs:
      simulation_id:
        description: 'Bluejay Simulation ID to run'
        required: false
        type: string
      prompt_id:
        description: 'Optional Prompt ID override'
        required: false
        type: string
      knowledge_base_id:
        description: 'Optional Knowledge Base ID override'
        required: false
        type: string
      digital_human_ids:
        description: 'Comma-separated Digital Human IDs (e.g. "dh_1,dh_2")'
        required: false
        type: string
      phone_number:
        description: 'Optional phone number to use for this run'
        required: false
        type: string
      sip_uri:
        description: 'Optional SIP URI to use for this run'
        required: false
        type: string
      min_score:
        description: 'Minimum required score (0–100)'
        required: false
        type: string
        default: '80'
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize]

jobs:
  run-bluejay-tests:
    runs-on: ubuntu-latest

    steps:
      - name: Run Bluejay Tests
        uses: bluejay-ai-dev/bluejay-github-actions@v1
        with:
          api_key: ${{ secrets.BLUEJAY_API_KEY }}
          # Required: simulation id (manual input OR repo variable)
          simulation_id: ${{ inputs.simulation_id || vars.BLUEJAY_SIMULATION_ID }}
          # Optional overrides (manual input OR repo variable)
          prompt_id: ${{ inputs.prompt_id || vars.BLUEJAY_PROMPT_ID }}
          knowledge_base_id: ${{ inputs.knowledge_base_id || vars.BLUEJAY_KB_ID }}
          digital_human_ids: ${{ inputs.digital_human_ids || vars.BLUEJAY_DIGITAL_HUMAN_IDS }}
          phone_number: ${{ inputs.phone_number || vars.BLUEJAY_PHONE_NUMBER }}
          sip_uri: ${{ inputs.sip_uri || vars.BLUEJAY_SIP_URI }}
          # Behavior controls
          wait_for_results: 'true'
          min_score: ${{ inputs.min_score || vars.BLUEJAY_MIN_SCORE || '80' }}
          poll_interval_seconds: '10'
          timeout_seconds: '1500'
```

### Step 3: Trigger a simulation

Make changes to your codebase and open a pull request. The GitHub Action will automatically run Bluejay tests on every PR.

### Step 4: Monitor your simulation

Click on the **Actions** tab in your GitHub repository to view the simulation run in real-time. You'll see the status and score once the simulation completes.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api_key` | ✅ Yes | — | Your Bluejay API key. |
| `simulation_id` | ✅ Yes | — | ID of the simulation to run. |
| `prompt_id` | No | — | Override prompt for this run. |
| `knowledge_base_id` | No | — | Override knowledge base for this run. |
| `digital_human_ids` | No | — | Comma-separated list of Digital Human IDs. |
| `phone_number` | No | — | Phone number override for the run. |
| `sip_uri` | No | — | SIP URI override for the run. |
| `wait_for_results` | No | `true` | Wait for simulation to finish. |
| `min_score` | No | `80` | Required overall score (0–100). |
| `poll_interval_seconds` | No | `10` | Polling frequency in seconds. |
| `timeout_seconds` | No | `1500` | Timeout (25 minutes). |

## Outputs

| Output | Description |
|--------|-------------|
| `simulation-run-id` | The ID of the queued simulation run. |
| `final-status` | Final simulation status: `completed`, `failed`, `cancelled`, etc. |
| `score` | Overall numeric score from the simulation. |
| `report-url` | Link to the Bluejay simulation report (if available). |

## Terraform

`.github/workflows/terraform.yml` gives every repo with an `infra/terraform` root the same checks. On every event it runs `terraform fmt -check`, `init -backend=false` and `validate`, and fails when `.terraform.lock.hcl` is missing. On a pull request from a branch of the same repo it plans each environment and keeps one comment per environment on the PR, updated in place. On a push to `main` or a manual run on `main` it applies the head of `main` to each environment in the listed order and stops at the first failure. A repo with several roots calls it once per root.

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `environments` | Yes | — | JSON array, in apply order, of `{name, var_file, backend_config, plan_role_arn, apply_role_arn}`. Any of the last four may be `""`; an empty role ARN skips AWS credentials. |
| `working_directory` | No | `infra/terraform` | The Terraform root. |
| `terraform_version` | No | `1.11.4` | Pinned Terraform version. |
| `aws_region` | No | `us-west-1` | Region for the AWS credentials. |

```yaml
name: terraform

on:
  pull_request:
    paths: [infra/terraform/**, .github/workflows/terraform.yml]
  push:
    branches: [main]
    paths: [infra/terraform/**, .github/workflows/terraform.yml]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read
  pull-requests: write

jobs:
  terraform:
    uses: bluejay-ai-dev/bluejay-github-actions/.github/workflows/terraform.yml@main
    with:
      environments: >-
        [{"name": "dev", "var_file": "dev.tfvars", "backend_config": "backend-dev.hcl",
          "plan_role_arn": "arn:aws:iam::123456789012:role/example-plan",
          "apply_role_arn": "arn:aws:iam::123456789012:role/example-apply"}]
```

Before a repo adopts it:

1. Commit `.terraform.lock.hcl` with `linux_amd64` hashes: `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64`.
2. Make the plan role read-only, trusting only `repo:<owner>/<repo>:pull_request`. PR code runs with it, and it cannot take the state lock, so plans run with `-lock=false`.
3. Make the apply role trust only `repo:<owner>/<repo>:ref:refs/heads/main`, and keep it from editing the CI roles themselves.
4. Match the `paths` filters to `working_directory`, or changes to the root will not trigger a run.
5. Run the first apply locally, since it creates the roles CI assumes.

`tests/terraform` and `terraform-selftest.yml` exercise this workflow on every PR that changes it.

## Infisical env

`infisical-env/action.yml` loads named secrets from an Infisical project into the rest of the job's environment. It logs in with the job's GitHub OIDC token, so the job needs `permissions: id-token: write` and an Infisical machine identity with OIDC auth that trusts the calling repo. Only the listed keys are loaded, and a listed key missing from Infisical fails the step. Every line of every value is masked.

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `project_id` | Yes | — | Infisical project id, not the slug. |
| `identity_id` | Yes | — | Infisical machine identity id. |
| `environment` | No | `local` | Infisical environment slug. |
| `keys` | Yes | — | Secret names, separated by spaces or newlines. |

```yaml
jobs:
  tests:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: bluejay-ai-dev/bluejay-github-actions/infisical-env@main
        with:
          project_id: 00000000-0000-0000-0000-000000000000
          identity_id: 00000000-0000-0000-0000-000000000000
          keys: |
            OPENAI_API_KEY
            RESEND_API_KEY
```

There is no option to load everything. Environments like `local` also hold AWS credentials, database URLs and `ENVIRONMENT`, which would override the job's own role and database.
