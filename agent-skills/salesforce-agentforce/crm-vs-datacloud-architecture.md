# CRM vs Data Cloud — where data lives, and what Agentforce reads vs writes

The single most consequential design decision in **any** Agentforce + Data Cloud build is **what belongs in CRM, what belongs in Data Cloud (Data 360), and what the agent reads vs writes.** Get it wrong and you pay in storage limits, brittle identity matching, and stale profiles. This is the decision framework, the rationale, and the rule for each side — applicable to any domain (commerce, financial services, healthcare, B2B, etc.).

## The mental model (the one rule everything follows)

- **CRM (Sales/Service Cloud) = the transactional system of record.** It runs day-to-day operational processes as *records you act on*: an Order you cancel, a Case you escalate, a Task you assign, a refund you issue. Row-based, governed, automatable (Flow/Apex/agent actions), but **row-storage-limited and not optimized for high-volume data or AI**.
- **Data Cloud / Data 360 = the analytical + unification layer that sits BESIDE CRM, not a replacement.** Lakehouse (Iceberg/object-store) built to connect, harmonize, identity-resolve, compute insights, and activate across channels. Read-optimized, massive scale — **but NOT transactional.** You cannot "cancel an order" or run a Flow *on* a Data Cloud row.

> One line: **CRM is where you DO things; Data Cloud is where you KNOW things.** Operational truth + actions → CRM. 360 context, big-volume events, cross-source unification, predictions → Data Cloud.

## When to put data in CRM

Use a CRM object when **all** of these are true:
- The data drives a **single operational process** and you need to **act** on the record (Flow, Apex, agent action, validation, approval, refund/cancel/case).
- A human or an agent **edits or transitions** it (status changes, ownership, lifecycle).
- The record already belongs to the org's process of record.

Examples: the **Account/Contact** you service, the **Case** you open, the **in-flight Order/Claim/Application** an agent is transitioning, a discount/credit the agent issues. These must be real CRM records.

## When to put data in Data Cloud

Use Data Cloud when **any** of these are true:
- You need a **unified profile** across multiple sources/identifiers (web, email, commerce, support).
- **High-scale / high-velocity events** (web clicks, telemetry, full order/line history) that would blow CRM row-storage and aren't individually acted on.
- **Calculated metrics / segments / predictions** (LTV, churn, affinity, propensity).
- **Activation** across channels (Marketing Cloud, ads, journeys).
- Large reference data you want queryable but **don't want eating CRM rows** (the canonical Salesforce example: millions of VIN/IoT rows — store in Data Cloud, expose to the agent via an Action).

Examples: **web/app engagement events**, **full transaction history for the 360**, **churn/propensity features and scores**, **product/category affinity**, **risk signals** — all Data Cloud.

## The anti-pattern to avoid (the costliest mistake)

**Mirroring an entire external system into CRM** (e.g. copying every order/line/customer from an e-commerce, ERP, or billing platform into Sales/Service Cloud objects) just so the agent can read it. It "works" and demos easily because Flows/agent actions run natively on CRM, but it reliably causes three failures:
- **Storage exhaustion** — CRM is row-storage-limited; Data Cloud is built for the volume. Mirroring a high-volume source is the classic cause of hitting the storage wall.
- **Brittle identity** — matching/dedup done in **Apex on a single key (e.g. email)** forks the customer when that key changes; **Identity Resolution in Data Cloud is purpose-built** to unify on multiple keys (external customer ID + email + device) across sources. Don't reimplement identity resolution in Apex.
- **Stale 360** — keeping a hand-maintained mirror fresh requires polling/triggers that are easy to leave half-wired (e.g. a profile-field change that never re-syncs).

**Rule: don't mirror a whole external system into CRM just to make it agent-readable.** Ingest it into Data Cloud and expose it to the agent; keep in CRM only the records you operate on.

## The target shape: Data-Cloud-forward, thin CRM

```
External systems (commerce/ERP/billing, web, email, support)
        │  streaming ingest (Ingestion API / SDK) — near real-time
        ▼
   Data Cloud:  DLO → DMO → Identity Resolution → Unified Profile → CIs / predictions
        │                                   │
        │ Data Cloud-Triggered Flow         │ Agent reads 360 (Profile API / Data Graph / Query)
        │ writes a THIN record / attrs      ▼
        ▼                          Agentforce agent
   CRM: Account + open Cases + in-flight Orders  ──► transactional WRITE to system of record
        (only what you operate on)                   (CRM record OR live external API, e.g. commerce/ERP)
```
- **Ingest** near-real-time (streaming Ingestion API / Web-Mobile SDK; the CRM connector also has near-real-time/CDC mode). Don't assume "scheduled batch only" — Data Cloud has real-time paths.
- **Unify** in Data Cloud via Identity Resolution (let it own matching).
- **Sync to CRM** with **Data Cloud-Triggered Flows** — react as data lands and upsert a *thin* Account/Contact/Case with minimal delay (no batch polling).
- **Agent READS** the 360 from the unified profile: **Data Graphs** for a known, latency-sensitive, single pre-built record fetch; ad-hoc **Data Cloud query / retrievers (RAG)** for open-ended grounding.
- **Agent WRITES** transactional actions to the **system of record** — a CRM record *or* a live call to the external API (e.g. an order cancel/refund in the commerce/ERP system). The external system stays the source of truth for its domain.

## Zero-copy vs ingest vs copy-to-CRM (the data-placement ladder)

1. **Leave it in CRM** — only if it's operational and already a record you act on.
2. **Zero-Copy / Live Query** into Data Cloud — when the external lake is *well-governed, fresh, complete*, volume is large, and governance/residency matters. Avoids duplication.
3. **Physical ingestion** into Data Cloud — when you **can't guarantee freshness/completeness** at the source, need **sub-second high-frequency reads** (use Cached Acceleration), or need heavy transformation.
4. **Copy into CRM** — last resort, only for the subset you must *operate on* as records.

Rule of thumb: zero-copy is not a silver bullet — model **total cost of ownership** (two bills) and **access pattern** (frequent reads → ingest/cache; infrequent → live query).

## Agentforce-specific rules (from Salesforce's own guidance)

- **Profile quality is the #1 determinant of agent quality.** "Unify a mess → unified mess." **Clean source data and validate unified-profile quality BEFORE designing the agent.** Sequencing: data → profile → *then* agent.
- An agent **can** run on CRM alone (basic case deflection), but its ceiling is far lower; **personalization needs the Data Cloud unified profile.**
- **Ground with RAG + Data Graphs.** Use a **Data Graph** when you know in advance what the agent needs and latency matters (single pre-built record beats a chain of queries). Use retrievers/search for open-ended knowledge.
- **Start narrow on what you expose** to the agent's data library — over-exposure slows queries and risks surfacing sensitive data. Expand based on real conversation logs that show where the agent lacked info.
- **Read from Data Cloud, write to the system of record.** Agent actions that *change* something must target a transactional store (CRM object or external API), never "write to Data Cloud."

## Quick decision checklist

| Ask | If yes → |
|---|---|
| Does an agent/Flow/Apex need to **act on / transition** this record? | **CRM** |
| Is it **high-volume / high-velocity** and rarely acted on individually? | **Data Cloud** |
| Do I need to **unify identity across sources / handle changing emails**? | **Data Cloud** Identity Resolution (not Apex) |
| Is it a **score / segment / insight / prediction**? | **Data Cloud** (cache a copy on CRM only if an agent reads it hot) |
| Am I about to **mirror a whole external system into CRM** so the agent can read it? | Stop → ingest to Data Cloud, expose via Action/Graph |
| Does the agent need this **fresh, in one shot, every conversation**? | **Data Graph** (pre-built) over live cross-object queries |

## Worked example (e-commerce agent)

A concrete application of the rules above:
- **In CRM:** the Account/Contact being serviced, Cases, the in-flight Order an agent is cancelling/refunding, an issued discount/credit.
- **In Data Cloud:** web engagement events, full purchase history for the 360, churn features/scores, category affinity, return-risk.
- **The mistake to avoid:** mirroring *all* orders/lines/customers from the commerce platform into CRM → causes the storage wall and email-fork dedup problems. Correct shape = **streaming-ingest the commerce data into Data Cloud, identity-resolve there, Data-Cloud-Triggered-Flow a thin Account into CRM, agent reads the 360 from the unified profile and writes transactional actions live to the commerce API.**

(The same pattern maps to other domains: financial services → CRM holds the serviced Account + Cases, Data Cloud holds transactions/positions/risk; healthcare → CRM holds the patient record + care tasks, Data Cloud holds claims/EHR/device data.)

## Sources
- [Data 360 Architecture — Salesforce Architect](https://architect.salesforce.com/docs/architect/fundamentals/guide/data-360-architecture)
- [Data 360 Integration Patterns & Practices — Salesforce Architect](https://architect.salesforce.com/docs/architect/fundamentals/guide/data360_integration_patterns_and_practices)
- [Zero Copy: When (and When Not) to Use It — Salesforce Ben](https://www.salesforceben.com/salesforce-data-cloud-zero-copy-when-and-when-not-to-use-it/)
- [Connecting Agentforce to Data Cloud for Grounding with RAG — Salesforce Ben](https://www.salesforceben.com/connecting-agentforce-to-data-cloud-for-grounding-with-rag/)
- [How Data Cloud Powers Agentforce — Salesforce](https://www.salesforce.com/news/stories/how-data-cloud-powers-agentforce/)
- [Automate with Data Cloud-Triggered Flows and Invocable Actions — Salesforce Developers](https://developer.salesforce.com/blogs/2024/08/automate-your-workflow-with-data-cloud-triggered-flows-and-invocable-actions)
- [Understanding Data Cloud's Role in Agentforce — Trailhead](https://trailhead.salesforce.com/content/learn/modules/data-cloud-powered-agentforce/explore-data-cloud-and-agentforce)
