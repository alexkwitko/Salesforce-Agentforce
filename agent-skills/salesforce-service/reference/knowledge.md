# Lightning Knowledge (DX reference)

> Verified against v67 PDFs (Metadata API, Object Reference, Knowledge Dev Guide), Summer '26. Several commonly-assumed API names don't exist — corrected inline.

## 1. Enable — `KnowledgeSettings`
`settings/Knowledge.settings-meta.xml`; package.xml type `Settings`, member `Knowledge` (no wildcard). Key fields: `enableKnowledge` (master), `enableLightningKnowledge` (single-object + record-type model), `defaultLanguage` (**locale** e.g. `en_US`, required), `languages` (list of `KnowledgeLanguage`: `active`, `name`=language **code** `en`, `defaultAssignee`/Type, `defaultReviewer`/Type), `votingEnabled` (v50+), `showValidationStatusField`, `suggestedArticles` (`caseFields`/`useSuggestedArticlesForCase`), `cases` (`enableArticleCreation`, `defaultContributionArticleType`, `editor`).
```xml
<KnowledgeSettings xmlns="http://soap.sforce.com/2006/04/metadata">
  <enableKnowledge>true</enableKnowledge>
  <enableLightningKnowledge>true</enableLightningKnowledge>
  <defaultLanguage>en_US</defaultLanguage>
  <languages><language><active>true</active><name>en</name></language></languages>
  <showValidationStatusField>true</showValidationStatusField>
</KnowledgeSettings>
```
Scratch def: `"settings":{"knowledgeSettings":{"enableKnowledge":true,"enableLightningKnowledge":true,"defaultLanguage":"en_US"}}`.
- **Gotchas:** both enable flags are **irreversible**; first activation is often Setup-UI-gated (a metadata deploy can no-op until the manual flip); Classic→Lightning needs the UI **Migration Tool** (rebuild article-types→record-types); EE scratch orgs have Knowledge on and can't disable; `defaultLanguage`=`en_US` vs `KnowledgeLanguage.name`=`en` is intentional. Fields that **don't exist**: `enableChatAnswers`, `enableKnowledgeOnConsole`, `defaultSearchLanguageEnabled`.

## 2. Data model
| Object | API | Role |
|---|---|---|
| Master container | `Knowledge__ka` | stable `KnowledgeArticleId` (`kA…`) across versions/translations |
| **Version (DML target)** | `Knowledge__kav` | one per version per language; body + custom fields; `ka…` id |
| Cross-type SOQL view | `KnowledgeArticleVersion` | read-mostly, all types |
| Stats | `Knowledge__ViewStat` / `Knowledge__VoteStat` | read-only; published+archived only |

Article types = **record types** on the single `Knowledge__kav` (`RecordTypeId`). Key version fields: `KnowledgeArticleId`, `ArticleNumber`, `VersionNumber`, `IsLatestVersion`, `PublishStatus` (`Draft`/`Online`/`Archived`), `Language`, `IsMasterLanguage`, `Title`, `UrlName`, `Summary`, `IsVisibleInApp`/`InPkb`/`InCsp`/`InPrm`.
- **Gotcha:** `PublishStatus` is read-only on insert (always lands `Draft`) and can't transition via update DML — use `KbManagement.PublishingService`. #1 bug: passing the `ka…` version id where the `kA…` master id is required.

## 3. Data categories — `DataCategoryGroup`
`datacategorygroups/<Group>.datacategorygroup-meta.xml`. Fields: `fullName`, `label`, `active` (required), recursive `dataCategory` (`name` immutable, `label`, nested), `objectUsage.object` (valid: `KnowledgeArticleVersion`, `Question` — **no `Case`**). Limits: 100 categories/group, 5 levels, **3 active groups/org**.
```xml
<DataCategoryGroup xmlns="http://soap.sforce.com/2006/04/metadata">
  <fullName>geo</fullName><label>Geography</label><active>true</active>
  <dataCategory><name>WW</name><label>Worldwide</label>
    <dataCategory><name>USA</name><label>United States</label></dataCategory>
  </dataCategory>
  <objectUsage><object>KnowledgeArticleVersion</object></objectUsage>
</DataCategoryGroup>
```
Assign categories to articles via `Knowledge__DataCategorySelection` (`DataCategoryGroupName`, `DataCategoryName`, `ParentId`=`Knowledge__kav` id; DML-able, assign while Draft).

**Visibility — three layers, sharply different deployability:**
- **Profile-based — DEPLOYABLE.** `Profile.categoryGroupVisibilities` (`dataCategoryGroup`, `visibility` `ALL`/`CUSTOM`/`NONE`, `dataCategories`). **Profile-only — NO PermissionSet equivalent.**
- Role-based + Default visibility — **UI-only** (no metadata type).
- **Gotchas:** `DataCategoryGroup` deploy is **destructive/full-replace** — any category not in the XML is permanently deleted (re-parents records). Always deploy the complete tree; build in prod manually if unsure. Without visibility, `WITH DATA CATEGORY` silently returns 0 rows. XML uses bare `name` (`USA`); SOQL uses `__c` (`usa__c`).

## 4. Publishing lifecycle — `KbManagement.PublishingService`
**Never `update PublishStatus`.** All transitions via static methods, each taking the **`KnowledgeArticleId` master id**:
| Method | Action |
|---|---|
| `publishArticle(articleId, flagAsNew)` | Draft→Online (true = new major version) |
| `editOnlineArticle(articleId, unpublish)` → new draft id | Draft from Online |
| `editArchivedArticle(articleId)` → id | new Draft from Archived |
| `archiveOnlineArticle(articleId, scheduledDate)` | Online→Archived (null=now) |
| `scheduleForPublication` / `cancelScheduled{Publication,Archiving}OfArticle` | scheduling |
| `restoreOldVersion(articleId, versionNumber)` → id | clone old → new Draft |
| `assignDraftArticleTask`, `deleteDraft/ArchivedArticle(Version)` | tasks/deletes |
| `submitForTranslation(articleId, lang, assignee, due)` → id | queue translation draft |
| `completeTranslation`, `setTranslationToIncomplete`, `editPublishedTranslation`, `deleteDraftTranslation` | translation lifecycle |

> Names that **don't exist** (and their real form): `archiveArticle`→`archiveOnlineArticle`; `queueForTranslation`→`submitForTranslation`; `setTranslationToReadyForReview`→`completeTranslation`; `publishDraftTranslation`→`publishArticle(<fr version id>)`.

Create: `insert Knowledge__kav` (lands Draft; required `Title`, `UrlName` [globally unique, alphanumeric+hyphen], `Language`, `RecordTypeId` if RTs exist) → re-query `KnowledgeArticleId` → `publishArticle(...)`.
- **Gotchas:** not bulkified (loop → "Too many DML: 151"; batch ~100/txn, Queueable/`@future`); touches setup objects → **`MIXED_DML_OPERATION`** (isolate via `@future`/`enqueueJob`); archived-edit/restore returns a **new Draft id** (capture, then publish).

## 5. Querying from Apex — SOQL `WITH DATA CATEGORY` + dynamic SOSL
Article queries **must** filter `PublishStatus` (or `Id`); published queries need a **single `Language`**.
```sql
SELECT Id, Title FROM Knowledge__kav
WHERE PublishStatus='Online' AND Language='en_US'
WITH DATA CATEGORY Geography__c ABOVE usa__c
```
Operators `AT`/`ABOVE`/`BELOW`/`ABOVE_OR_BELOW`; **`AND` only** (no `OR`), ≤3 conditions, **no bind variables**.

**The dynamic-query gotcha (load-bearing) — three triggers force dynamic:**
1. **Bind variables fail to COMPILE** in static SOQL against `Knowledge__kav`/`KnowledgeArticleVersion` → use `Database.query(string)`.
2. **Snippets/SearchResult metadata require `Search.find(String)`** (not inline `[FIND …]`).
3. **Article-type unknown at compile time** (packages/Classic `<Type>__kav`) → `Search.query(String)`.
```apex
String term = String.escapeSingleQuotes(keyword);
String sosl = 'FIND \'' + term + '\' IN ALL FIELDS RETURNING KnowledgeArticleVersion '
   + '(Id, Title, UrlName WHERE PublishStatus=\'Online\' AND Language=\'en_US\') WITH SNIPPET (target_length=120)';
Search.SearchResults results = Search.find(sosl);
for (Search.SearchResult r : results.get('KnowledgeArticleVersion')) {
    KnowledgeArticleVersion kav = (KnowledgeArticleVersion) r.getSObject();
    System.debug(kav.Title + ' :: ' + r.getSnippet());
}
```
`UPDATE VIEWSTAT` / `UPDATE TRACKING` clauses work in SOSL+SOQL (the **only** programmatic view-stat increment — no Apex method). Suggested-articles on a Case: `Search.suggest` + `Search.KnowledgeSuggestionFilter`. Results silently filtered by the running user's data-category visibility + record-type + channel.

## 6. Surfacing — console, Omni, search, Experience Cloud
- The App-Builder **"Knowledge"** component (Case record page or utility bar) shows suggested/searched articles; auto-suggestions need **Data Category Mapping** (case field → category). **Einstein Article Recommendations** renders in the same component.
- **The Knowledge component for the Case record page = `forceKnowledge:articleSearchDesktop`** (confirmed by placing it in App Builder + retrieving the FlexiPage). It renders a "New Article" + "Search Knowledge" panel so human agents can search/insert articles inline. Add it to the Case `FlexiPage` (or via App Builder → double-click → insertion point → save).
- **Authoring articles fast via Apex (verified):** `insert Knowledge__kav` (Title, UrlName [unique, alphanumeric+hyphen], Language, Summary as the body) → in a **separate transaction** (avoid MIXED_DML) re-query `KnowledgeArticleId` and call `KbManagement.PublishingService.publishArticle(articleId, true)`. Published articles immediately feed a READY Agentforce Data Library's RAG index + appear in the case-page Knowledge component.
- Search: global search works once Lightning Knowledge is on; **Einstein Search for Knowledge** / **Search Answers** are Setup-UI toggles. Deployable: `SearchSettings`, `SearchCustomization`, `SearchLayouts`.
- Experience Cloud: Aura has built-in components; **Enhanced LWR** uses Knowledge Article + Knowledge Article List components and needs **Data Category → Topic mapping** for site search.

## 7. Agent / AI grounding (Summer '26)
RAG: an **Agentforce Data Library (ADL)** indexes Knowledge into a Data Cloud vector index, exposes a retriever (auto-named `KA_*`), invoked by the standard **Answer Questions with Knowledge** action (OOB **General FAQ** topic).
- **DX line:** the agent "brain" (`Bot`/`BotVersion`/`GenAiPlannerBundle`/`GenAiPlugin`/`GenAiPromptTemplate`/`AiAuthoringBundle`) is metadata-deployable. The **grounding substrate (Data Library, search index, `Knowledge_kav_Home` stream, retriever) is NOT deployable** — recreate per org via `sf agent adl create --source-type knowledge [--restrict-to-public-articles]`, poll `sf agent adl status` until index Ready + `retrieverId` non-null, then `sf agent activate` (publish ≠ activate).
- **Article eligibility:** Lightning Knowledge on, `Published`, right channel, indexed content fields, agent user has data-category visibility + **"Allow View Knowledge"** (the #1 "agent finds no articles" cause), published translation in the configured language.
- **✅ Wiring KB into an Agent-Script agent — the DX recipe (PROVEN, Summer '26).** Add the OOB **General FAQ** subagent (ships **Answer Questions with Knowledge** = `standardInvocableAction://streamKnowledgeSearch`) from the Agentforce Builder Asset Library + Save. Its inputs default to `@knowledge.rag_feature_config_id`/`citations_url`/`citations_enabled`, which only resolve when a Data Library is *assigned* — and the Agent-Script Builder has **no assignment UI** (Data node read-only; "Add connections" = channels) and `sf agent adl` can't assign. **You don't need the assignment:** the `ragFeatureConfigId` is deterministic = **`ARFPC_<libraryId>`** (libraryId `1JD…` from `sf agent adl get -i <id> --json`). Retrieve the bundle (`AiAuthoringBundle:<Agent>` — the saved Builder draft IS retrievable), set the input defaults to literals (`ragFeatureConfigId="ARFPC_<libraryId>"`, `citationsUrl=""`, `citationsEnabled=False`), drop the `with …=…` overrides in the subagent reasoning (keep `with query=…`), then `sf agent validate/publish/activate`. Smoke-test headlessly via `AgentInvoker` (a policy question returns KB text; guest order-status still hits the identity gate). Full recipe in `salesforce-agentforce/agentforce-agents.md` → "Knowledge grounding (RAG) in an Agent-Script agent — the DX recipe".

## 8. CaseArticle, KCS, permissions
- **`CaseArticle`** (Case↔Knowledge junction): `CaseId`, `KnowledgeArticleId` (**abstract `kA…` id**, not the `_kav` version), `ArticleLanguage`, `ArticleVersionNumber`, `IsSharedByEmail`. **create+delete only (no update); idempotent.** Does NOT carry `ArticleNumber`/`Title`/`Type` (traverse via `KnowledgeArticleId`). Inserting article content into a Case Email action auto-creates the `CaseArticle`.
- **KCS:** capture-in-workflow → draft-from-Case; flag-for-review = **Validation Status** field + approvals; feedback = `Vote` (one/user; guests can't vote) → `Knowledge__VoteStat`.
- **Permissions:** Knowledge User license = `User.UserPermissionsKnowledgeUser` (seat-capped gate, not a grant; **all internal users read without it**). Actions = user perms + object CRUD combined. Metadata `<userPermissions><name>` **drops the `Permissions` prefix** the SOQL field uses (`ManageKnowledge` vs SOQL `PermissionsManageKnowledge`): `EditKnowledge` (Manage Articles), `ManageKnowledge`, `PublishArticles`, `AllowViewKnowledge`, `AllowUniversalSearch`, `ManageDataCategories`. Min author set = license true + `ManageKnowledge` + `EditKnowledge` + object CRUD + `PublishArticles`. Lightning has **no public-group article actions** (Classic did). Data-category visibility can't go on a permission set.

## Key doc URLs
- [KnowledgeSettings](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_knowledgesettings.htm) · [Knowledge__kav](https://developer.salesforce.com/docs/atlas.en-us.knowledge_dev.meta/knowledge_dev/sforce_api_objects_knowledge__kav.htm) · [DataCategoryGroup](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_datacategorygroup.htm)
- [PublishingService](https://developer.salesforce.com/docs/atlas.en-us.knowledge_dev.meta/knowledge_dev/apex_classes_knowledge_kbManagement.htm) · [Articles via SOQL/SOSL](https://developer.salesforce.com/docs/atlas.en-us.knowledge_dev.meta/knowledge_dev/articles_using_soql.htm) · [Search class](https://developer.salesforce.com/docs/atlas.en-us.apexref.meta/apexref/apex_methods_system_search.htm)
- [CaseArticle](https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_casearticle.htm) · [ADL Connect API](https://developer.salesforce.com/docs/ai/agentforce/guide/adl.html) · [Answer Questions with Knowledge](https://help.salesforce.com/s/articleView?id=sf.copilot_actions_ref_answer_questions_with_knowledge.htm)
