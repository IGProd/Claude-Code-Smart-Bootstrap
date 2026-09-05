# Architecture

![Architecture overview](test-results/architecture.svg)

The bootstrap separates state so one mechanism does not have to solve every problem.

## Context Mode

Owns searchable session/history retrieval and virtualization of large outputs.

## Auto Memory

Holds small durable learnings that should survive session changes without loading a full transcript.

## claude-project-state

Stores compact, confirmed state outside the Git repository:

- solved issue → symptom / cause / verified fix;
- durable decision → decision / rationale;
- visual reference → content hash / compact spec / crops.

## Graft

Owns live structural code intelligence: symbols, relationships, callers, dependencies and blast radius.

## Graphify

Provides broader graph/knowledge support for code/docs/config when useful. It is not forced before every task.

## Visual-reference workflow

```text
stable local image path
        ↓
      SHA-256
        ↓
  ┌─────┼────────┐
exact  near      new
  ↓      ↓        ↓
reuse   hint    analyze once
spec/   only    + register
crops
```

## Model isolation

The main conversation stays Sonnet/medium. Screenshot-driven implementation can delegate to Sonnet/high. Opus/high is kept as a bounded escalation for a narrow hard QA problem rather than becoming the default parent model.
