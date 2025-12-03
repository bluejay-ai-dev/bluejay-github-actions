# Bluejay Simulation Action

A GitHub Action to queue and monitor [Bluejay](https://www.getbluejay.ai/) simulations directly from your CI/CD pipeline. This action allows you to gate deployments based on simulation scores, ensuring quality and performance.

## Usage

### Prerequisites

1.  **Get your Bluejay API Key**: Obtain your API key from the Bluejay dashboard.
2.  **Add to GitHub Secrets**: Go to your repository's **Settings** > **Secrets and variables** > **Actions** > **New repository secret**.
    *   Name: `BLUEJAY_API_KEY`
    *   Value: (Your API Key)

### Basic Workflow Example

Add the following step to your `.github/workflows/main.yml` (or similar) file:

```yaml
steps:
  - name: Run Bluejay Simulation
    uses: bluejay-ai-dev/bluejay-github-actions@v1.0.0
    with:
      api_key: ${{ secrets.BLUEJAY_API_KEY }}
      simulation_id: "your-simulation-id-here"
```

### Advanced Usage with Optional Parameters

You can customize the simulation run by providing additional parameters like prompt IDs, specific digital humans, or phone numbers.

```yaml
steps:
  - name: Run Custom Bluejay Simulation
    uses: bluejay-ai-dev/bluejay-github-actions@v1.0.0
    with:
      api_key: ${{ secrets.BLUEJAY_API_KEY }}
      simulation_id: "your-simulation-id"
      
      # Optional Overrides
      prompt_id: "uuid-of-prompt-version"
      digital_human_ids: "dh-id-1, dh-id-2"
      phone_number: "+15550123456"
      
      # Quality Gates
      min_score: "90"           # Fail if score is below 90% (default: 80)
      wait_for_results: "true"  # Set to 'false' to just queue without waiting
      timeout_seconds: "600"    # Wait up to 10 minutes
```

## Inputs

| Input | Description | Required | Default |
|---|---|---|---|
| `api_key` | Your Bluejay API Key. | **Yes** | N/A |
| `simulation_id` | The ID of the simulation to run. | **Yes** | N/A |
| `prompt_id` | UUID of a specific prompt version to use. | No | `null` |
| `knowledge_base_id` | UUID of a specific knowledge base to use. | No | `null` |
| `digital_human_ids` | Comma-separated list of Digital Human IDs. | No | `null` |
| `phone_number` | Override the agent's phone number. | No | `null` |
| `sip_uri` | Override the agent's SIP URI. | No | `null` |
| `wait_for_results` | If `true`, polls for completion. | No | `true` |
| `min_score` | Minimum score (0-100) to pass the step. | No | `80` |
| `timeout_seconds` | Max time to wait for results (seconds). | No | `1500` |

## Outputs

*   `simulation-run-id`: The ID of the queued run.
*   `final-status`: Final status (e.g., `completed`, `failed`).
*   `score`: The calculated score (0-100).
*   `report-url`: URL to the simulation report.

