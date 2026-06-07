# Salesforce Agentforce CI/CD Runbook

This repo uses GitHub Actions as the release gate for Salesforce Agentforce, WooCommerce integration metadata, Agentforce actions, and Data Cloud configuration.

## Branch model

- `main`: release branch that deploys automatically to production.
- `staging`: integration branch that deploys automatically to the staging Salesforce org.
- Feature branches: open pull requests into `staging`.
- Production deploys: automatic GitHub Actions workflow on push to `main`, after validation and smoke checks.

## Required GitHub secrets

Do not commit Salesforce auth URLs, JWT private keys, WooCommerce keys, Hostinger keys, or WordPress config snippets.

Current target Salesforce org for this project:

- Org name: `CPQDream`
- CLI alias: `AgentforceDev`
- Username: `alexkwitko.cec7e462f3fd@agentforce.com`
- Org ID: `00DXX0000000000RED`

Configure these secrets in GitHub:

- `SALESFORCE_VALIDATION_SFDX_AUTH_URL`: CPQDream / `AgentforceDev`.
- `SALESFORCE_STAGING_SFDX_AUTH_URL`: CPQDream / `AgentforceDev`.
- `SALESFORCE_PRODUCTION_SFDX_AUTH_URL`: CPQDream / `AgentforceDev`.

The workflows also verify the authenticated org ID before any validation or deployment runs. If a secret is accidentally pointed at another org, the job fails before deploy.

## Required checks

Every pull request must pass:

- formatting and LWC/Aura lint checks;
- secret scan;
- Salesforce metadata validation with local Apex tests;
- Agentforce smoke checks for runtime users and web messaging config;
- Data Cloud smoke checks for visible calculated insight entities and Account augmented fields.

Dependabot pull requests run the static controls only because GitHub does not expose normal Actions secrets to Dependabot-triggered pull-request workflows. Salesforce org validation still runs for human-authored pull requests.

## Promotion rules

1. Feature branch to `staging` through pull request only.
2. `staging` branch deploys to staging with tests and smoke checks.
3. After staging certification, merge to `main`.
4. GitHub Actions automatically validates and deploys `main` to production.
5. Confirm post-deploy smoke before continuing with live Wohoo/Embedded Messaging changes.

## Current known blockers the pipeline is designed to catch

- Web chat conversation creation stuck before agent start.
- Open `MessagingSession` records with no `EndTime`.
- Agentforce bots without runtime `BotUserId`.
- Data Cloud calculated insights not visible as agent-usable objects.
- Account augmented fields missing or not mapped.
- Accidental commit of JWT/private-key material.

## GitHub plan limitation

GitHub returned `403` when applying branch protection to this private repo because protected branches for private repositories require GitHub Pro, Team, Enterprise Cloud, or Enterprise Server. Until the account supports private-repo branch protection, the repo still has CI workflows, CODEOWNERS, PR template gates, Dependabot, and automatic staging/production deployment workflows, but GitHub cannot technically block direct pushes to `main` or `staging`.
