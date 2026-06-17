# Kwitko Current Goal Requirements/Evidence Matrix - 2026-06-16

Refreshed: `2026-06-16T17:50:25Z`

## Verdict

The Salesforce Apex/service layer is much stronger now and the latest broad regression is green. The solution is not yet production-ready because the active Agentforce runtime still needs a publish/activate step, storefront signed-in recognition is still intermittent, Data Cloud/IR has not been freshly proven today, and expired OTP rows still need a real cleanup execution.

## Matrix

| Requirement | Current status | Evidence | Missing before "production-ready" |
|---|---|---|---|
| Agent action schemas do not break preview (`email`, `chatSummary`) | Source/generated contracts pass | Static gates: agent `53/53`, planner `30/30`; latest generated v81 request-verification outputs expose `email`; service actions do not require `chatSummary` | Publish/activate a new active Agentforce version so runtime definitely matches source/generated contracts |
| All service interactions create Cases | Backend certified | Service case static `62/62`; Apex run `707fj00000dw56d` passed `147/147`; latest closed chat Cases have populated summary/resolution/resolved-by and transcript Tasks | New post-deploy live chat Case should be created to prove `Service_Interaction_Id__c` is populated on live runtime-created rows |
| Solved service Cases close with resolution/details/transcript | Backend certified | Closed chat Cases `00001114`, `00001113`, `00001112`, etc. have `Status=Closed`, resolution/summary/resolved-by, and `Chat transcript` Tasks | Same as above: one fresh live widget/headless chat after active runtime publish |
| Customer-facing order numbers use Woo order numbers | Backend certified | Deploy `0Affj00000H1dC1CAJ`; Alex Salesforce order `00000734` has `Woo_Order_Id__c=506`; helpers now display `#506` or neutral wording | Fresh live chat smoke after runtime publish |
| OTP email sends and verifies safely | Backend fixed live | Deploy `0Affj00000H1z9KCAR`; `VerificationServiceTest`/`EmailServiceTest` `20/20`; broad run `707fj00000dw56d` `147/147` | Fresh visible-widget OTP test and Gmail Inbox/Spam/Trash check after the unique-subject fix |
| OTP does not flood or hide in trashed Gmail thread | Fixed for next sends | Gmail search found recent OTPs in `TRASH`/`SENT`, no Spam; `VerificationService` now suppresses rapid duplicate requests for 120s and uses unique subject suffixes | Need a new live OTP request after deploy to prove the next code lands visibly |
| Expired OTP storage cleanup | Patched, not live-proven | `OrgStorageGuard` deployed/tested; `VerificationService` now cleans expired rows at OTP request start | Existing rows still `11` verified / `43` unverified after 17:45 guard; need execute-anonymous/UI/working CLI to reschedule `OrgStorageGuard.scheduleDefault()` or trigger a real OTP request |
| Signed-in Woo user recognition in chat | Not reliable | Latest `MessagingSession` rows still alternate between `Kwitko_Logged_In_Email__c=null` and `alexkwitko@gmail.com` | Implement/enable a non-racy auth gate such as Salesforce User Verification/JWT, or certify a corrected prechat startup path in the visible widget |
| Logout/stale conversation reset | Source/WPCode static pass | Chat identity static `14/14`; WPCode combined static `41/41` includes logout reset and stale guest reset | Visible widget proof after login/logout cycle |
| Explicit guest complaint/open-case without OTP | Source fixed, active runtime not fixed | Authoring deploy `0Affj00000H1lMVCAZ`; static contracts keep guest complaint open-case path | Active v81 still needs publish/new-version + activate; direct active deploy failed with `Cannot update record as Agent is Active` |
| Return/refund/full and partial returns | Backend certified | `707fj00000dw56d` includes return/refund/service coverage; previous `707fj00000dvNAj` `59/59` covered full/partial returns, pending refund before receipt, Woo refund after receipt, HMAC Woo receipt endpoint | Do not run real money-moving Woo refund without explicit approval; route POSTs still need unrestricted network/browser proof |
| Return label/customer email route | Source/WPCode static pass | WPCode combined static `41/41`; return-label page browser proof exists | Signed POST `/return-label-email` needs rerun from unrestricted route-test path |
| Shopping/recommendation/cart link | Backend/source pass | Revenue/Data Cloud static `45/45`; broad Apex `147/147`; recommendation uses Data Cloud SDK cache and real products/prices | Fresh visible widget cart/recommendation smoke after active runtime publish |
| Abandoned cart/post-purchase/win-back emails | Backend certified | Broad Apex `147/147`; prior Gmail proofs for abandoned cart, post-purchase, win-back; current focused revenue run documented | Fresh live email proof optional; production domain SPF/DKIM/Org-Wide Email still needed |
| Data Cloud Web SDK browsing capture | Configured, not fresh today | Data streams active/successful; SDK stream totals exist; WPCode/static SDK gates pass | Fresh incognito browse + wait + Data Cloud row-count growth proof |
| DLO to DMO mappings | Present in metadata/source | ObjectSourceTargetMap files exist for SDK identity/contact/behavioral DLOs and Web Event DMO | Fresh Data Cloud mapping/UI sanity check if Profile Explorer remains empty |
| Identity Resolution device/email stitch | Configured, not fresh today | Ruleset `inCoffee Unified Profile` is scheduled, last run success `2026-06-14T22:48:51Z`, source `185`, matched `7`, unified `179` | Run/observe a fresh two-device browse/login/IR cycle and prove both devices stitch to one Unified Individual |
| Unified Profile / Account 360 enrichment | CRM cache populated | Alex Account has unified id `6ca1578d414d70dfe49572a9f82e0a5a`, risk `High`, orders `7`, LTV `886.1`, web/device/session `148/6/17`, cases/returns `21/3` | Data Cloud Profile Explorer UI related-list/CI placement still needs browser/UI certification |
| Calculated Insights | Mostly configured | `UP Customer Value`, `UP Web Engagement`, `UP Service Profile` active/success; `UP Web Engagement Device Profile` active | Device-profile CI still has null last-run status; rerun/verify UI or query output |
| Prediction | Scores exist, model definition not certified | `MktMLPredictionJob` success, 483 processed/updated; `Churn_Predictions__dlm=161`; activation CampaignMember exists | `MLPredictionDefinition`, `AIPredictionDefinition`, `MktMLModel`, `MLModel` all zero/API-unsupported; do not claim a certified active Model Builder model |
| Local/source safe runner | Pass | `LOCAL_ONLY=1 bash tools/certify_kwitko_safe_state.sh` passed `9/9` | Full live runner blocked by shell DNS to Hostinger and stale local Salesforce CLI auth |

## Hard Blockers

- Agentforce active runtime publish/activation: MCP cannot publish/activate, local `sf` lacks the Agent CLI plugin and auth is stale.
- Visible storefront widget certification: in-app browser can inspect the page but cannot complete cross-origin Salesforce iframe chat interactions; Chrome fallback requires explicit user approval.
- Hostinger/Woo route POST certification: shell DNS cannot resolve the Hostinger domain from this sandbox.
- Immediate OTP storage cleanup: MCP does not expose execute-anonymous or DML, so existing expired rows cannot be purged immediately from here.
