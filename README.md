# Salesforce CRM Wizards

Metadata-driven Lightning wizards for creating CRM records without duplicates. Built with Apex and Lightning Web Components, and deployable to any Developer Edition org.

This is a neutral open-source reference. It rewrites patterns I built in enterprise CRM work, using fictitious data and generic names. It makes no external calls and contains no credentials.

| Module | What it shows |
| --- | --- |
| **Record wizard** (Contact, Campaign) | Admins configure record types, fields, pages, sections, labels and duplicate-match weights in Custom Metadata, with no code changes. |
| **Contact identify & merge** | Search as you type with weighted scoring across Contacts and unconverted Leads. A field-by-field review lets the user merge up to 3 Contacts, convert the chosen Leads into the kept Contact and link related Accounts. Duplicate rules are handled with "Save anyway" and "Merge with existing". |
| **Opportunity + products wizard** | The price book is chosen from the Account's country (rule-based, with a fallback). The wizard saves the Opportunity and its lines in one transaction. The server decides the stage, price book and currency. |
| **Contract sync pattern** | A Queueable and a Schedulable run an incremental sync with a watermark and an upsert on an external id. The sync reads a `ContractFeed.Source` interface. This repository only ships a **mock** source (static-resource JSON), so it makes no callouts. |
| **Before-save Flow** | `Campaign_Set_Name` builds a consistent Campaign name. It is bulk-safe and uses no SOQL or DML. |

## Screenshots

Captured in a Developer Edition org with the demo data (fictitious companies and people).

| | |
| --- | --- |
| ![Record type step](docs/images/01-contact-record-type.png) Step 1: record types from Custom Metadata | ![Identify step](docs/images/02-contact-identify.png) Identify: Contacts and Leads scored as you type |
| ![Review values](docs/images/03-contact-review.png) Review: pick the value to keep per field | ![Form](docs/images/04-contact-form.png) Form: merge summary and Account suggestion from the Lead company |
| ![Opportunity details](docs/images/05-opportunity-details.png) Opportunity: configured fields, Account limited by record type | ![Products](docs/images/06-opportunity-products.png) Products: country price book, per-line Line Type, live total |
| ![Campaign form](docs/images/07-campaign-form.png) Campaign: the Flow builds the name from Region and Campaign Name | |

## Architecture

```mermaid
flowchart LR
    subgraph UI[Lightning Web Components]
        RW[recordWizard]
        OW[opportunityWizard]
        FI[wizardFieldInput]
        FU[wizardFieldUtils]
    end
    subgraph Apex
        RWC[RecordWizardController]
        OWC[OpportunityWizardController]
        CFG[WizardConfig]
        FW[WizardFieldWriter]
        CMS[ContactMatchService]
        CMG[ContactMergeService]
        PBR[PriceBookResolver]
        DML[WizardSystemDml<br/>system mode]
    end
    subgraph Config[Custom Metadata]
        RT[(Wizard_Record_Type__mdt)]
        WF[(Wizard_Field__mdt)]
        MR[(Wizard_Match_Rule__mdt)]
        PB[(Price_Book_Rule__mdt)]
    end
    RW --> FI --> FU
    OW --> FI
    RW --> RWC
    OW --> OWC
    RWC --> CFG & FW & CMS & CMG
    OWC --> CFG & FW & PBR
    CFG --> RT & WF & MR
    PBR --> PB
    FW --> DML
    CMS --> DML
    CMG --> DML
    OWC --> DML
```

**Security model.** The wizards serve users who may not have Create or Edit on the object. Writes therefore run in system mode, but only through `WizardSystemDml`, and three controls apply:

1. **Custom permission.** Apex checks `Use_Record_Wizard` or `Use_Opportunity_Wizard` before any search or save.
2. **Field whitelist.** `WizardFieldWriter` writes only the fields configured in `Wizard_Field__mdt`. It never writes read-only, formula or auto-number fields.
3. **Lookup filters.** Record-type restrictions on lookups are enforced again on the server, because the browser filter can be bypassed.

More detail is in [docs/architecture.md](docs/architecture.md).

## Install in a Developer Edition org

```bash
sf org login web -a crm-wizards
sf project deploy start -o crm-wizards -d force-app -l RunLocalTests
sf org assign permset -o crm-wizards -n Record_Wizard_User -n Opportunity_Wizard_User -n Contract_Integration
sf apex run -o crm-wizards -f scripts/apex/seed-demo-data.apex
```

Then add the list buttons **New Contact (Wizard)**, **New Campaign (Wizard)** and **New Opportunity (Wizard)** to the list view button layout of each object. You can also open the wizards directly:

- `/lightning/cmp/c__recordWizard?c__object=Contact&c__session=1`
- `/lightning/cmp/c__recordWizard?c__object=Campaign&c__session=1`
- `/lightning/cmp/c__opportunityWizard?c__session=1`

Optional settings:

- **Related Accounts.** Enable *Contacts to Multiple Accounts* in Setup → Account Settings. Without it the wizard simply hides Related Accounts; the code uses `AccountContactRelation` dynamically.
- **Duplicate rule.** The demo rule `Contact_Same_Email` uses `sortOrder` 2, which assumes one existing Contact duplicate rule. Adjust it if your org has a different number.

## Demo script (5 minutes)

1. **New Contact (Wizard).** Choose *Customer Contact* and type `maria.santos@northwind.example`.
   - Two Contacts and one Lead appear, each with a score and the fields that matched or differed.
2. **Merge and convert.** Tick both Contacts and the Lead, then choose **Review values**.
   - Pick the value to keep for each field, then continue to the form and save.
   - Result: one Contact, the other merged into it, the Lead converted into it, and the second Account linked as a Related Account.
3. **New Contact for `tomas.novak@fabrikam.example`.** Only a Lead exists for this person.
   - The wizard suggests the Account *Fabrikam Inc* from the Lead's Company.
4. **Duplicate rule.** Create a Contact with an email that already exists.
   - The duplicate panel offers **Save anyway** or **Merge with existing**.
5. **New Opportunity (Wizard).** Choose the Account *Northwind Traders* (Portugal) and you get the Portugal price book.
   - Choose *Contoso Ltd* (Spain) and you get the Spain price book, which only has licences.
   - Choose *Fabrikam Inc* (France) and you get the default price book.
6. **Contract sync.** The seed script ran the sync from the mock source.
   - Open **External Contracts**: the contracts are linked to Accounts by account number.

[docs/presentation.md](docs/presentation.md) has a talk track for presenting the project.

## Configure

The configuration guide is in [docs/configuration.md](docs/configuration.md). In short:

| To change | Edit |
| --- | --- |
| Record types offered in step 1 | `Wizard_Record_Type__mdt` |
| Fields, labels, pages, sections, required, lookup filters | `Wizard_Field__mdt` |
| Identify step fields and weights, minimum score | `Wizard_Match_Rule__mdt`, `Wizard_Record_Type__mdt.Minimum_Match_Score__c` |
| Price book by country | `Price_Book_Rule__mdt` |
| Contract source | Implement `ContractFeed.Source` and return it from `ContractFeed.source()` |

## Tests

- **Apex:** 45 tests with `sf apex run test -l RunLocalTests -c`. Coverage of the project classes is 70–100% (about 90% overall).
- **Org-dependent branches:** a few branches depend on org features. Related Accounts need *Contacts to Multiple Accounts* enabled.
- **Configuration tests:** they use in-memory Custom Metadata rows.
- **Controller tests:** they use the sample configuration shipped in `customMetadata/`.
- **JavaScript:** `npm test` runs Jest on the shared field helpers.

## Project structure

```
force-app/main/default/
  classes/           Apex: controllers, services, config, tests
  lwc/               recordWizard, opportunityWizard, wizardFieldInput, wizardFieldUtils
  customMetadata/    sample configuration (Contact, Campaign, Opportunity, price book rules)
  objects/           custom metadata types, record types, fields, External_Contract__c
  flows/             Campaign_Set_Name (before-save)
  permissionsets/    Record_Wizard_User, Opportunity_Wizard_User, Contract_Integration
  staticresources/   MockContracts.json (fictitious data)
scripts/apex/        seed-demo-data.apex
docs/                architecture, configuration, presentation
```

## License

MIT. See [LICENSE](LICENSE).
