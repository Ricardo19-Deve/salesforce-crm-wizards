# Architecture

## Design goals

1. **Admins configure, developers don't redeploy.** Fields, labels, pages, record types, match rules and price-book rules live in Custom Metadata. Custom Metadata deploys with the code and can be changed in Setup.
2. **One governed path to write data.** Users who must not use the standard New page (no Create permission, or duplicates to avoid) get a guided UI. All writes go through a single system-mode class guarded by explicit controls.
3. **Avoid duplicates before they exist.** Identify the person first, then decide whether to create, merge or convert.
4. **Portable.** It deploys to any org, depends on no optional feature, makes no external calls and uses no hard-coded ids.

## Apex layers

| Layer | Classes | Responsibility |
| --- | --- | --- |
| Controllers | `RecordWizardController`, `OpportunityWizardController` | `@AuraEnabled` API. They check the custom permission, resolve the object and record type, and translate `WizardException` into `AuraHandledException`. |
| Configuration | `WizardConfig`, `PriceBookResolver` | Read Custom Metadata with `getAll()`, which costs no SOQL, sort the rows in Apex and validate them, with clear errors for wrong configuration. |
| Domain services | `ContactMatchService`, `ContactMergeService` | Duplicate scoring, Account suggestions, the field-by-field review, merge, lead conversion and Related Accounts. |
| Write boundary | `WizardFieldWriter`, `WizardSystemDml` | The field whitelist, type coercion and server-side lookup checks, then system-mode DML with duplicate-rule headers. |
| Integration | `ContractFeed`, `MockContractSource`, `ContractSyncJob`, `ContractSyncScheduler` | Interface, mock implementation, paged Queueable and daily Schedulable. |

## Key decisions

- **Custom permission instead of a permission-set name check.** `FeatureManagement.checkPermission` works whether the permission comes from a permission set or a permission set group, and it can be tested.
- **Ordering in Apex.** `ORDER BY` on Custom Metadata fields is not reliable, so rows are sorted with `Comparator` classes.
- **Scoring vs filtering.** Only rules whose weight alone reaches the minimum score become SOQL filters, with one query per filter. Weaker rules such as first name only add points. Otherwise a common first name fills the row limit and hides the real matches.
- **Encrypted fields.** With Shield Platform Encryption (deterministic), email, phone and name support only exact comparisons, with no `LIKE` or `ORDER BY`. The service therefore searches the usual capitalisations of each value. The same code works with or without encryption.
- **Lead conversion across sales processes.** Each Lead record type can have a different set of converted statuses. The service tries the converted statuses in order until every Lead converts.
- **Duplicate rules.**
  - **Alert rules:** the duplicates are returned to the UI as data, not as an exception. The user can then "Save anyway" (`DuplicateRuleHeader.allowSave`) or merge.
  - **Block rules:** they still stop the save.
- **Optional features used dynamically.** `AccountContactRelation` only exists when *Contacts to Multiple Accounts* is enabled. The code uses it dynamically and the UI hides the section when it is absent, so the package deploys everywhere.
- **Server-authoritative values.** Opportunity stage, price book and currency are always set in Apex. Values sent by the browser for them are ignored.
- **All or nothing.** Every save that touches several records uses a savepoint and rolls back on error.

## LWC

- **`recordWizard`:** a URL-addressable component (`lightning__UrlAddressable`), so no Aura wrapper is needed. `c__session` in the URL resets the wizard on every click of the list button.
  - Contact: the Account Name field is replaced by an Accounts section (one Principal Account = `AccountId`, any number of Related Accounts sent as `relatedAccountIds`). Only the Accounts left in the list are linked.
  - A Summary step shows the final values (`describeRecords` resolves lookup names in user mode) and groups the records kept, merged and converted, before calling `createRecord` or `mergeContacts`.
- **`opportunityWizard`:** the same pattern, with a products step that searches, filters by family, edits lines and shows the total.
- **`wizardFieldInput`:** renders one configured field with the right base component, including dependent picklists, multi-select, record pickers filtered by record type, dates and numbers.
- **`wizardFieldUtils`:** pure functions covered by Jest. They resolve fields, build sections and the payload, and turn errors into messages.

Wire results are kept when the wizard resets for the same object. Wires do not provision again when their parameters are unchanged, so clearing them would leave an endless spinner.

## Integration pattern

```
ContractSyncScheduler (daily) -> ContractSyncJob(page 1) -> ContractFeed.source().fetchUpdatedSince(watermark, page)
                                         |-> upsert External_Contract__c on External_Id__c (Account by AccountNumber)
                                         |-> more pages? enqueue page + 1 : save watermark = run start time
```

- **Watermark:** it moves only after the last page succeeds, so a failed run is retried by the next one and nothing is skipped.
- **Connecting a real system:** implement `ContractFeed.Source` (for example an HTTP adapter using a Named Credential, so no secret lives in code) and return it from `ContractFeed.source()`.
