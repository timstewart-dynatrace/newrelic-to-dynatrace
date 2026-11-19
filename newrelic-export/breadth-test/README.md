# Export-breadth test build (proposed v1.4.0)

A test build of the exporter, built on the **official v1.3.10** script, not on this repo's v1.3.8. It exists so the export-breadth change can be run and reviewed before it goes official. The directive [`agent-directives/2026-11-18-v1.4.0-export-breadth.md`](../../agent-directives/2026-11-18-v1.4.0-export-breadth.md) describes it.

| File | What it is |
|---|---|
| `dma-newrelic-export.v1.3.10.sh` | Official v1.3.10, as supplied on 2026-11-18. Indentation was lost in transit; the code is otherwise unchanged. |
| `dma-newrelic-export.sh` | v1.3.10 plus the export-breadth change. `diff -u` between the two files is the patch. |

The test build adds non-NRQL and compound alert conditions, legacy REST alert channels (redacted), step and script content, private locations, secure credential names, monitor downtimes, and five supplemental types: log data-partition rules, log obfuscation, pipeline cloud rules, key transactions and browser applications.

Run it like the main exporter, from a scratch directory:

```bash
bash /path/to/breadth-test/dma-newrelic-export.sh --accounts <id> --all
```

It reads only. It adds no New Relic ingest and changes nothing in the account.
