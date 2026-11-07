# Agent directives

This repo is a **staging copy** of the exporter. The official repos are:

- `Dynatrace-Customer-Success/newrelic-to-dynatrace`: the export scripts
- `Dynatrace-Customer-Success/dma-newrelic-app`: embeds the scripts and consumes the archive

The machine that does the staging work can't reach them. Each staging fix that needs to go official gets a directive here: a self-contained brief that an agent with access to the official repos follows to apply the change.

Each directive gives:

- what changed and why
- the staging tag and commit SHAs to fetch from this repo
- the same patches embedded as a fallback
- the verification steps
- the report the agent must return

The agent must not commit, push or tag in the official repos without Tim's approval.

Apply them **in order**. Each directive is cut against the state the previous one leaves behind.

| # | Directive | Staging tag | Staging commits | Summary |
|---|---|---|---|---|
| 1 | [2026-11-05-v1.3.7-alert-terms.md](2026-11-05-v1.3.7-alert-terms.md) | `v1.3.7` | `20e8b34`, `9352989` | Export alert condition `terms`, `signal` and `type`; fix the `.ps1` parse error |
| 2 | [2026-11-07-v1.3.8-variables-workloads.md](2026-11-07-v1.3.8-variables-workloads.md) | `v1.3.8` | `2b6909f` | Export dashboard `variables` and workload definitions |

## For the agent watching this folder

This repo is read-only for you, so track progress in the official repos, not here.

1. `git fetch` this repo, then read this table.
2. A directive is **done** when the official repo's CHANGELOG already covers its change. Directives don't map one-to-one to official version numbers, so match on the change itself, not the number. Every row after the last one done is **pending**.
3. Take pending directives strictly in table order. Start the next one only after Tim has approved the previous one's commits.
4. For each directive, follow its own hard rules and send its report to Tim. Never commit, push or tag without approval. Never write to this repo.
5. If a directive no longer matches the official code (it was fixed differently, or the code moved), report the mismatch and wait. Don't force the directive through.

## Adding a directive

1. Push the staging tag first. The agent fetches it from this repo.
2. Name the file `YYYY-MM-DD-vX.Y.Z-short-topic.md`, and add a row to the table above.
3. Embed the patches as a fallback, and check they apply to a clean checkout of the previous tag.
4. Keep credentials, local paths and customer details out of the file.
