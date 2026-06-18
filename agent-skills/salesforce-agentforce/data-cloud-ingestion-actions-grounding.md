# Data Cloud — ingestion, segmentation, Data Actions, Data Graphs, grounding & model tools

Completes the Data Cloud picture beyond `data-cloud.md` (which is deep on DLO/DMO mapping, Identity Resolution, Calculated Insights, query, Web SDK). The items here are the **official mechanisms** for the capabilities this playbook's reference build didn't exercise — use them when the requirement calls for them; verify exact API versions against current docs.

## Ingestion — pick the connector by source, and the refresh mode by latency
Data Cloud ingests via **connectors**; know which fits:
- **Salesforce CRM** — the native connector (stream creation is UI-gated; see `data-cloud.md`).
- **Ingestion API** (server-to-server, your code pushes) — REST, **two patterns on the same stream**:
  - **Streaming** = JSON **micro-batches**, near-real-time (processed async ~every few min) — for event/change feeds. Define the stream from an **OpenAPI (OAS) `.yaml` schema** you upload to the Ingestion API connector.
  - **Bulk** = **CSV jobs** for periodic syncs/backfills. Same data stream accepts both.
- **Cloud storage** — Amazon S3 / Azure / GCS (scheduled file imports).
- **Marketing Cloud**, **another Salesforce org**, and **MuleSoft Data Cloud connector** (anything MuleSoft reaches).
- **Web/Mobile SDK** — behavioral/engagement events (covered in `data-cloud.md` / `predictive-and-engagement.md`).

**Refresh modes** (set per stream): **streaming/upsert** (continuous), **incremental** (only changed rows since last run — default for big CRM objects; safe under contention), **full** (re-pull everything — heavy, can fail on large Order/OrderItem streams). Don't manually full-refresh big streams from the UI; let incremental keep them current.

> Decision: server pushing events → **Ingestion API streaming**; periodic file dumps → **Ingestion API bulk** or **cloud storage**; another SF/MC org → its connector; browser behavior → **Web SDK**; anything else → **MuleSoft**.

## Segmentation (the audience layer)
A **Segment** is a saved population of unified individuals matching criteria over DMOs/CIs. Two refresh styles: **batch** (scheduled rebuild) and **real-time/streaming** (membership updates as data arrives — for time-sensitive triggers). Segment membership is what **Activation** publishes (to Marketing Cloud, ad platforms, etc. — consent-aware; see `consent-and-marketing-activation.md`) and what an agent can *nominate into* (the agent sets a signal → the individual enters a real-time segment → activation sends). Build segments in the Segment UI or via the Connect API; prefer **real-time** only when you need sub-batch latency (higher cost).

## Data Actions — event-driven "Data Cloud → automation"
The way Data Cloud **pushes** an event out when data changes (vs CIs/segments which you pull/activate). Driven by the **change data feed**; near-real-time. **Three target types:**
- **Salesforce Platform Event** → caught by a **Data-Cloud-Triggered Flow** or an Apex trigger / `@InvocableMethod` on the platform side (this is how a Data Cloud insight reaches CRM automation/an agent).
- **Webhook** → POST to an external endpoint (HMAC-style auth) for non-Salesforce systems.
- **Marketing Cloud** → drive a journey.

Setup: **Data Cloud → Data Action Targets → New** (name + API name), then **create a Data Action** bound to a source (a DMO / Calculated Insight / streaming insight) with **conditions** that fire it. Use a Data Action when you need *Data Cloud to initiate* (a churn-score crossing a threshold, an engagement spike) rather than a scheduled job polling. Pairs perfectly with the "agent decides → Data Cloud → automation" split.

## Data Graphs — denormalized, pre-computed views for fast retrieval & grounding
A **Data Graph** combines + transforms normalized DMOs into a **materialized, denormalized view** (a root object + related objects), pre-calculated and refreshed near-real-time. Why: one query returns the whole customer 360 sub-tree (fewer calls, low latency) instead of JOINing many DMOs per request.
- **Query** via the Data Graph REST API (`/ssot/data-graphs/...`) — returns the nested JSON for an individual.
- **Live query** option = up-to-the-moment data at higher latency + credit cost; the pre-calculated graph is the default fast path.
- **Primary uses:** (1) the fast read an agent/Prompt Builder needs for the unified profile, (2) **structured grounding** (below). This is the official answer to "the agent needs the 360 in one fast call" — the CRM cache pattern in `data-cloud.md` is the no-Data-Graph fallback.

## Grounding an agent in Data Cloud (RAG + structured)
Two complementary grounding paths for Agentforce/Prompt Builder:
1. **Structured grounding with Data Graphs** — bind a Data Graph (or DMO/CI) so the prompt/agent reads real customer 360 fields. Deterministic, exact values. (This build went further and used **typed Apex actions** for structured data — equally valid, more testable; Data Graph grounding is the lower-code option.)
2. **Unstructured grounding (RAG)** — bring free-form content (PDFs, chat transcripts, emails, articles) into Data Cloud, **chunk it → vector embeddings → a search (vector) index**; Agentforce/Prompt Builder run **vector search** to retrieve relevant chunks at answer time. The **Data Library** is the construct that holds the unstructured source + its index and exposes a **retriever** the agent grounds on.
- **When to use RAG vs typed actions:** RAG for "answer from a knowledge corpus / policy docs / past conversations"; typed actions for transactional facts, pricing, eligibility (don't RAG over data you can query exactly). Many real agents use both: actions for the record, a retriever for the knowledge.

## Choosing the predictive tool (clarification)
- **Einstein Prediction Builder** — clicks-based binary/numeric predictions on a **single Salesforce object** (no Data Cloud needed). Fast for "score this CRM object" use cases.
- **Einstein Studio / Model Builder (in Data Cloud)** — build/train on **Data Cloud DMOs**, or **BYOM** (bring a model from SageMaker / Vertex / Databricks / OpenAI via connection), or AutoML; deploy as a **predict job** that scores DMO rows. This is what `predictive-and-engagement.md` documents (Model Builder UI flow, predict jobs, score writeback, the storage trap). Use it when features live in Data Cloud or you have an external model.
- Decision: single-CRM-object, no Data Cloud → **Prediction Builder**; Data-Cloud features or external/custom model → **Einstein Studio / BYOM**.

## Data Spaces (one line)
A **Data Space** is a logical partition of Data Cloud (separate brand/region/BU data + access). Most REST calls take `?dataspace=default`; pass the real data space name in multi-space orgs. Segments/CIs/activations are scoped to a data space.

Sources (verify current API versions): Data Cloud Data Actions (`help.salesforce.com` c360_a_data_actions + `developer.salesforce.com` webhook data action targets); Data Graphs (Data 360 Query API data-graphs + "Grounding with Data Graphs"); Ground Agentforce in Your Data / RAG (`help.salesforce.com` ai.agent_parent_data, generative_ai_rag_example); Ingestion API streaming vs bulk (`developer.salesforce.com` data-cloud-int ingestion-api).
