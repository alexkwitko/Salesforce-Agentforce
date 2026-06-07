# Salesforce Agentforce CI/CD Runbook

This repo uses GitHub Actions as the release gate for Salesforce Agentforce, WooCommerce integration metadata, Agentforce actions, and Data Cloud configuration.

## Branch model

- `main`: protected release branch.
- `staging`: protected integration branch that deploys to the staging Salesforce org.
- Feature branches: open pull requests into `staging`.
- Production deploys: manual GitHub Actions workflow from `main` with the `production` environment approval gate.

## Required GitHub secrets

Do not commit Salesforce auth URLs, JWT private keys, WooCommerce keys, Hostinger keys, or WordPress config snippets.

Configure these secrets in GitHub:

- `SALESFORCE_VALIDATION_SFDX_AUTH_URL`: low-risk validation org.
- `SALESFORCE_STAGING_SFDX_AUTH_URL`: staging org.
- `SALESFORCE_PRODUCTION_SFDX_AUTH_URL`: production org.

Use GitHub environments for `staging` and `production`. Production should require manual approval.

## Required checks

Every pull request must pass:

- formatting and LWC/Aura lint checks;
- secret scan;
- Salesforce metadata validation with local Apex tests;
- Agentforce smoke checks for runtime users and web messaging config;
- Data Cloud smoke checks for visible calculated insight entities and Account augmented fields.

## Promotion rules

1. Feature branch to `staging` through pull request only.
2. `staging` branch deploys to staging with tests and smoke checks.
3. After staging certification, merge to `main`.
4. Run `Deploy Production` manually and type `DEPLOY`.
5. Confirm post-deploy smoke before continuing with live Wohoo/Embedded Messaging changes.

## Current known blockers the pipeline is designed to catch

- Web chat conversation creation stuck before agent start.
- Open `MessagingSession` records with no `EndTime`.
- Agentforce bots without runtime `BotUserId`.
- Data Cloud calculated insights not visible as agent-usable objects.
- Account augmented fields missing or not mapped.
- Accidental commit of JWT/private-key material.
