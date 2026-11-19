/**
 * Incremental synchronisation of External_Contract__c from a ContractFeed.Source (MockContractSource in this
 * repository: sample data from a static resource, no callouts).
 *
 *  - Schedule:  System.schedule('Contract sync', '0 0 2 * * ?', new ContractSyncScheduler());   (daily at 02:00)
 *  - Run now:   System.enqueueJob(ContractSyncJob.fromLastSync());
 *
 * Each Queueable execution fetches one page, upserts it on External_Id__c and enqueues the next page. The
 * watermark (Contract_Sync_Settings__c.Last_Successful_Sync__c):
 *  - moves to the moment the run started once the last page is done;
 *  - when a run stops at MAX_PAGES with more pages left, moves only to one second before the newest contract it saved
 *    (sources return items oldest change first, see ContractFeed), so the next run continues from there and
 *    nothing is skipped;
 *  - stays where it was when a page fails as a whole, so the next run retries it.
 * Contracts that cannot be saved (e.g. a value Salesforce rejects) do not block the others: they are counted in
 * Last_Sync_Error_Count__c, the first messages are kept in Last_Sync_Errors__c, and they are not retried until
 * they change at the source. Accounts are matched on Account.AccountNumber = counterparty account number.
 */
public with sharing class ContractSyncJob implements Queueable {
    @TestVisible private static final Integer PAGE_SIZE = 100;
    @TestVisible private static final Integer MAX_PAGES = 50;
    private static final Integer ERROR_TEXT_LENGTH = 255;

    private final Datetime updatedSince;
    private final Integer page;
    private final Datetime runStartedAt;

    public ContractSyncJob(Datetime updatedSince, Integer page, Datetime runStartedAt) {
        this.updatedSince = updatedSince;
        this.page = page;
        this.runStartedAt = runStartedAt == null ? Datetime.now() : runStartedAt;
    }

    public static ContractSyncJob fromLastSync() {
        return new ContractSyncJob(Contract_Sync_Settings__c.getOrgDefaults()?.Last_Successful_Sync__c, 1, Datetime.now());
    }

    public void execute(QueueableContext context) {
        ContractFeed.ResultPage result = ContractFeed.source().fetchUpdatedSince(updatedSince, page, PAGE_SIZE);
        List<String> errors = upsertContracts(result.items);

        Datetime watermark = null;
        String note = null;
        if (result.hasMore && page < MAX_PAGES) {
            ContractSyncJob next = new ContractSyncJob(updatedSince, page + 1, runStartedAt);
            // Queueables cannot be chained inside Apex tests.
            if (!Test.isRunningTest()) {
                System.enqueueJob(next);
            }
        } else if (result.hasMore) {
            watermark = checkpoint(result.items);
            note = watermark == null
                ? 'Stopped at ' + MAX_PAGES + ' pages without progress; check the source order. '
                : 'Stopped at ' + MAX_PAGES + ' pages; the next run continues from the last saved contract. ';
        } else {
            watermark = runStartedAt;
        }
        saveRunState(page == 1, errors, watermark, note);
    }

    /**
     * Saves one page. Each contract is saved on its own (allOrNone = false), so one bad item cannot block the
     * page; returns "external id: message" for the items that failed.
     */
    @TestVisible
    private static List<String> upsertContracts(List<ContractFeed.Item> items) {
        List<String> errors = new List<String>();
        if (items == null || items.isEmpty()) {
            return errors;
        }
        Set<String> accountNumbers = new Set<String>();
        for (ContractFeed.Item item : items) {
            if (!String.isBlank(item.counterpartyAccountNumber)) accountNumbers.add(item.counterpartyAccountNumber.trim());
        }
        Map<String, Id> accountByNumber = new Map<String, Id>();
        for (Account acc : [SELECT Id, AccountNumber FROM Account WHERE AccountNumber IN :accountNumbers WITH SYSTEM_MODE]) {
            accountByNumber.put(acc.AccountNumber, acc.Id);
        }

        List<External_Contract__c> records = new List<External_Contract__c>();
        for (ContractFeed.Item item : items) {
            if (String.isBlank(item.id)) continue;
            records.add(new External_Contract__c(
                External_Id__c = item.id,
                Name = String.isBlank(item.reference) ? item.id.left(80) : item.reference.left(80),
                Status__c = fit(item.status, 80),
                Counterparty_Name__c = fit(item.counterpartyName, 255),
                Counterparty_Account_Number__c = fit(item.counterpartyAccountNumber, 80),
                Account__c = item.counterpartyAccountNumber == null ? null : accountByNumber.get(item.counterpartyAccountNumber.trim()),
                Effective_Date__c = item.effectiveDate,
                End_Date__c = item.endDate,
                Remote_Last_Modified__c = item.updatedAt,
                Document_Url__c = fit(item.documentUrl, 255)
            ));
        }
        List<Database.UpsertResult> results = Database.upsert(records, External_Contract__c.External_Id__c, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                String message = results[i].getErrors().isEmpty() ? 'unknown error' : results[i].getErrors()[0].getMessage();
                errors.add(records[i].External_Id__c + ': ' + message);
            }
        }
        return errors;
    }

    /**
     * One second before the newest change on this page (the watermark field stores whole seconds), so contracts
     * changed in that second are read again; the upsert makes that harmless.
     */
    @TestVisible
    private Datetime checkpoint(List<ContractFeed.Item> items) {
        Datetime newest = null;
        for (ContractFeed.Item item : items) {
            if (item.updatedAt != null && (newest == null || item.updatedAt > newest)) newest = item.updatedAt;
        }
        if (newest == null) {
            return null;
        }
        Datetime resumeFrom = newest.addSeconds(-1);
        return updatedSince == null || resumeFrom > updatedSince ? resumeFrom : null;
    }

    private static String fit(String value, Integer maxLength) {
        return value == null ? null : value.left(maxLength);
    }

    /** One write per page: resets the error summary on the first page, adds this page's errors, moves the watermark. */
    private static void saveRunState(Boolean firstPage, List<String> errors, Datetime watermark, String note) {
        if (!firstPage && errors.isEmpty() && watermark == null && note == null) {
            return;
        }
        Contract_Sync_Settings__c settings = Contract_Sync_Settings__c.getOrgDefaults();
        if (settings == null || settings.Id == null) {
            settings = new Contract_Sync_Settings__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        if (firstPage) {
            settings.Last_Sync_Error_Count__c = 0;
            settings.Last_Sync_Errors__c = null;
        }
        if (!errors.isEmpty()) {
            settings.Last_Sync_Error_Count__c = (settings.Last_Sync_Error_Count__c == null ? 0 : settings.Last_Sync_Error_Count__c) + errors.size();
        }
        String summary = (note == null ? '' : note) + String.join(errors, '; ');
        if (String.isNotBlank(summary)) {
            String existing = String.isBlank(settings.Last_Sync_Errors__c) ? '' : settings.Last_Sync_Errors__c + '; ';
            settings.Last_Sync_Errors__c = (existing + summary).left(ERROR_TEXT_LENGTH);
        }
        if (watermark != null) {
            settings.Last_Successful_Sync__c = watermark;
        }
        Database.upsert(settings, true, AccessLevel.SYSTEM_MODE);
    }
}
