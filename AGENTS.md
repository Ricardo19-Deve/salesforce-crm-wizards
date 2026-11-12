# Notes for maintainers and AI coding assistants

## Where things are

| Need | File |
| --- | --- |
| What a class does | The header comment at the top of every Apex class and LWC (what / where to configure / gotchas) |
| Configuration model | `docs/configuration.md` |
| Design decisions | `docs/architecture.md` |
| Sample configuration | `force-app/main/default/customMetadata/` |
| Demo data | `scripts/apex/seed-demo-data.apex` |

## Rules of this codebase

1. **System-mode writes go only through `WizardSystemDml`.** Values written there must come through `WizardFieldWriter`, which applies the `Wizard_Field__mdt` whitelist and the lookup checks. Do not add `without sharing` anywhere else.
2. **Access** is the custom permission checked by the controllers (`Use_Record_Wizard`, `Use_Opportunity_Wizard`). New `@AuraEnabled` methods that read or write records must call the access check.
3. **Errors:** services throw `WizardException`; controllers convert it with `auraError()`, so users see the message as written.
4. **Custom Metadata:** read it with `getAll()` and sort in Apex. Do not rely on `ORDER BY` for metadata fields.
5. **Encrypted fields:** keep comparisons exact (see `ContactMatchService.variants`). Do not introduce `LIKE` or `ORDER BY` on email, phone or name fields.
6. **Optional org features** (e.g. `AccountContactRelation`) are used dynamically, so the project deploys to any org.
7. **No callouts or credentials in this repository.** Integrations implement `ContractFeed.Source`, and the default is `MockContractSource`.
8. **Every new class gets a header comment** in the same style, and a test class. Keep the tests independent of org data: use `WizardTestData` and in-memory metadata rows.

## Commands

```bash
sf project deploy start -o <org> -d force-app -l RunLocalTests   # deploy + tests
sf apex run test -o <org> -l RunLocalTests -c -w 20              # tests with coverage
npm install && npm run lint && npm test                          # LWC lint + Jest
```

Validate before deploying to a production org: `sf project deploy start --dry-run -l RunLocalTests ...`.
