# Antithesis Triage Action

> **Status: v0.1 prototype.** Interfaces may change.

A GitHub Action that triages your [Antithesis](https://antithesis.com) test
runs with a headless [Claude Code](https://code.claude.com) agent. It runs in
the repository whose code Antithesis tests, so the agent can read the source at
the commit each run tested.

On each run the agent:

- picks the Antithesis runs you described,
- groups comparable runs and marks each failure **new** or **ongoing**,
- investigates failures with the
  [`antithesis-triage`](https://github.com/antithesishq/antithesis-skills)
  skill and [`snouty`](https://github.com/antithesishq/snouty), cross-referencing
  your source code,
- suggests fixes (as text and `.patch` files) and recommends debugging
  sessions you can start yourself.

The result is a report in the workflow's job summary, plus a downloadable
artifact with the report, machine-readable findings, every `snouty` command
the agent ran, and (optionally) the full agent transcript.

## Quick start

1. Add repository secrets `ANTITHESIS_API_KEY` and `ANTHROPIC_API_KEY`, and a
   repository variable `ANTITHESIS_TENANT`.
2. Copy [`examples/triage.yml`](examples/triage.yml) to
   `.github/workflows/antithesis-triage.yml`.
3. Run it from the Actions tab (or wait for the schedule).

Runs launched with
[`antithesis-trigger-action`](https://github.com/antithesishq/antithesis-trigger-action)
or with `snouty launch` from a git checkout record the commit they tested
(`vcs.version_id`), which the agent uses to read the matching source. Check out
with `fetch-depth: 0` so those commits are available.

## Inputs

Selection, grouping and known-issue inputs are plain language (or `key=value`
lines) passed to the agent, which applies them with `snouty`.

| Input | Default | Description |
|---|---|---|
| `runs` | last 7 days, this repo | Which runs to triage, in plain language. |
| `since` | | Hint, e.g. `7d`. |
| `limit` | | Hint: only the last N matching runs. |
| `run-ids` | | Explicit run IDs; overrides the other selection inputs. |
| `run-params` | | `key=value` lines matched against run parameters, e.g. `antithesis.source=main`. |
| `grouping` | | Which runs are comparable. If empty, the agent picks a grouping and reports it. |
| `known-issues` | | One per line: property name or description, optional note/link. Checked lightly; flagged if it changes or stops occurring. |
| `ignore` | | One per line: failures to skip entirely. Counted only. |
| `instructions` | | Extra guidance for the agent. |
| `model` | `claude-opus-5-5` | Claude model. |
| `max-turns` / `max-budget-usd` / `timeout-minutes` | `200` / `10` / `60` | Hard caps on the agent session. |
| `upload-transcript` | `auto` | `auto`: only on private repositories. |
| `retention-days` | `14` | Artifact retention. |

Model credentials: `ANTHROPIC_API_KEY`, or Amazon Bedrock / Google Vertex AI
via the standard Claude Code environment variables
(`CLAUDE_CODE_USE_BEDROCK=1` / `CLAUDE_CODE_USE_VERTEX=1` plus cloud
credentials, e.g. from an OIDC step).

## Safety

- **Read-only.** The workflow needs only `contents: read`. The agent never
  pushes, opens PRs, launches Antithesis runs, or starts debugging sessions.
  A `snouty` wrapper blocks `launch`, `debug`, `runs exec`, `runs cancel` and
  similar commands, and logs every command the agent runs.
- **Triggers.** Only `schedule` and `workflow_dispatch` are allowed. Pull
  request and comment events are refused.
- **Untrusted input.** Logs and run metadata are treated as data, not
  instructions. The wrapper is defense in depth, not a hard boundary: the
  Antithesis API key is in the agent's environment.
- **Redaction.** Secret values, signed `?auth=` URL tokens and common token
  formats are scrubbed from every uploaded file. Report links still work for
  anyone with access to your tenant (they prompt for login).
- **Transcripts** contain log excerpts from your runs. By default they are only
  uploaded for private repositories.

## Outputs

| Output | Description |
|---|---|
| `status` | `complete`, `partial` or `failed`. |
| `report-path` / `findings-path` | Paths on the runner. |
| `artifact-url` | URL of the uploaded artifact. |

Artifact contents:

```
report.md            full report (the job summary may be truncated)
findings.json        machine-readable findings (schema/findings.schema.json)
commands.log         every snouty command the agent ran
patches/             suggested fixes
transcript/          claude-session.jsonl (resume with Claude Code),
                     transcript.jsonl (provider-neutral chat messages)
```

## Continuing an investigation

Each report lists the `snouty` commands the agent ran, so you can reproduce its
evidence locally. To pick up where the agent stopped, resume the raw session
with Claude Code (see the report's "Resume this session" section), or feed
`transcript.jsonl` to another model.

## Development

```
test/run.sh
```
