# Configuration guide

All configuration is in **Setup → Custom Metadata Types**. Changes take effect immediately and need no deployment. To promote them between orgs, retrieve the `CustomMetadata` records and deploy them with the code.

## Wizard Record Type (`Wizard_Record_Type__mdt`)

One row for each record type offered in step 1.

| Field | Meaning |
| --- | --- |
| Object API Name | `Contact`, `Campaign` or any object with record types |
| Record Type Developer Name | The record type's developer name |
| Description | Text shown on the card. Blank means the record type description from Setup. |
| Sort Order | Order of the cards |
| Minimum Match Score | Identify step: candidates scoring below this (0–100) are hidden. Default 30. |
| Active | Unchecked rows are ignored |

A record type appears only if it is active and available to the user. In this project it is granted by the permission set `Record_Wizard_User`.

## Wizard Field (`Wizard_Field__mdt`)

One row per field and per object. The same field can have several rows with different record types, for example `AccountId` restricted to Customer accounts for Customer Contacts and to Partner accounts for Partner Contacts.

| Field | Meaning |
| --- | --- |
| Object API Name | Object of the field (`Opportunity` rows feed the opportunity wizard) |
| Record Types | Comma-separated developer names. Blank means every record type. |
| Field API Name | The field to show and allow writing to |
| Field Label | Optional label shown instead of the field label |
| Page / Section / Section Order / Column / Sort Order | Layout of the form |
| Required | Required in the wizard, even if optional on the object |
| Read Only | Shown but never written |
| Lookup Record Types | Lookups only: target record types allowed. The filter applies in the picker and is checked again in Apex. |

> Security: saving runs in system mode, so **this list is the write whitelist**. A field that is not here cannot be written through the wizard.

## Wizard Match Rule (`Wizard_Match_Rule__mdt`)

These rules define the Identify step, which exists for Contact only.

| Field | Meaning |
| --- | --- |
| Field API Name | Contact field asked in the Identify step |
| Lead Field API Name | Lead field compared with it. Blank means Leads are not compared on this rule. |
| Weight | Points added when equal. The score is the sum, capped at 100. |
| Sort Order | Order of the inputs |

A rule whose weight is at least the minimum score is used as a **search filter**; the others only add points. With the sample configuration, Email (60) and Last Name (30) search; First Name (15), Mobile (20) and Account (15) only add points.

## Price Book Rule (`Price_Book_Rule__mdt`)

| Field | Meaning |
| --- | --- |
| Country | `Account.BillingCountry` value, compared case-insensitively |
| Price Book Name | Name of an active price book |
| Is Default | Fallback when no country rule matches. Exactly one active row should have it. |

## Adapting to another project

1. **Fields.** Replace the sample rows in `force-app/main/default/customMetadata/` with your objects and fields.
2. **Record types.** Add your record types to `Wizard_Record_Type__mdt` and to the permission set's record type visibilities.
3. **Duplicate search.** For a different object than Contact, `ContactMatchService` is the part to generalise. The rest is already object-agnostic.
4. **Contract sync.** Replace `MockContractSource` with a real `ContractFeed.Source` and change the mapping in `ContractSyncJob.upsertContracts`.
