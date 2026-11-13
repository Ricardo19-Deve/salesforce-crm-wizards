# Presenting the project (10–15 minutes)

## 1. The problem (1 min)

- **Duplicates.** Standard "New" pages create duplicates. Sales reps don't search first, and Leads and Contacts for the same person drift apart.
- **Access.** Some users must not get Create or Edit on an object, but still need to create records in a controlled way.
- **Change requests.** Every layout or rule change becomes a development ticket.

## 2. The approach (2 min)

- **Guided wizards:** step by step, always identifying the person before creating.
- **Configuration in Custom Metadata:** admins change fields, labels, pages and match rules without a deployment.
- **One governed write path:** system mode behind a custom permission, a field whitelist and server-side lookup checks.

Show the architecture diagram in the README.

## 3. Live demo (6–8 min)

Follow the "Demo script" in the README:

1. Search as you type finds Maria Santos as 2 Contacts and 1 Lead, most similar first, with the fields that matched. Users see no percentages: the weights only rank the results.
2. In the review, choose the value to keep for each field. The Accounts section separates the one Principal Account from any number of Related Accounts. The Summary shows what will be kept, merged and converted before anything is saved.
3. Only a Lead exists for Tomas Novak: the wizard creates the Contact, converts the Lead and suggests the Account from the Company name.
4. A duplicate rule returns the matches to the UI, with "Save anyway" or "Merge".
5. In the Opportunity wizard, the price book changes with the country (Portugal, Spain, default). The products, the server-set stage and the line type are all saved in one transaction.
6. In Setup, change a label or move a field to page 2 in Custom Metadata, then refresh the wizard: no deployment is needed.

## 4. Engineering choices (2 min)

- **Thin controllers and small services:** each class has one responsibility. Tests use in-memory metadata.
- **Real-world constraints handled:**
  - encrypted fields (exact match only);
  - Lead conversion across sales processes;
  - unreliable `ORDER BY` on Custom Metadata;
  - optional org features used dynamically.
- **Integration as a pattern, not a dependency:**
  - an interface plus a mock source;
  - incremental sync with a watermark;
  - idempotent upsert.

  Plugging in a real API means writing one class.
- **AI- and handover-friendly:**
  - every class starts with a "what / where / gotchas" header;
  - `AGENTS.md` explains how to work in the repository.

## 5. Questions to expect

- **Why not Screen Flows?** Search as you type, the field-by-field merge grid and dynamic per-row product editing are much simpler and faster in LWC. Flows are used where they fit best: before-save field logic.
- **Why system mode?** The business wants a governed creation path for users without Create rights. Three explicit controls replace CRUD/FLS on the write path, and they are covered by tests.
- **How does it scale?** Custom Metadata reads cost no SOQL. Searching uses one selective query per strong rule with row limits. The sync is paged and resumable.

## 6. Bonus: Project Board (5 minutes)

- **The problem.** Salesforce delivery teams keep requirements in Word, tests in Excel and the backlog in another tool. The links between them get lost.
- **The answer.** One app where each issue carries its BRD, its test scripts and its evidence, and every sprint produces a report that is ready to present.
- **Demo.** Follow the demo script in [project-board.md](project-board.md#demo-script-5-minutes). The strongest moments are dragging a card while the progress ring updates, **Generate from BRD**, and the sprint report PDF.
- **Engineering points.**
  - Fractional ranks: one update per drag & drop.
  - Sprint snapshots, so "committed vs delivered" survives carry-over.
  - User-mode security throughout.
  - One design system that renders the same in Lightning Experience and in an LWR portal.
