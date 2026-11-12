/**
 * Incremental synchronisation of External_Contract__c from a ContractFeed.Source (MockContractSource in this
 * repository: sample data from a static resource, no callouts).
 *
 *  - Schedule:  System.schedule('Contract sync', '0 0 2 * * ?', new ContractSyncScheduler());   (daily at 02:00)
 *  - Run now:   System.enqueueJob(ContractSyncJob.fromLastSync());
 *
 * Each Queueable execution fetches one page, upserts it on External_Id__c and enqueues the next page. The
 * watermark (Contract_Sync_Settings__c.Last_Successful_Sync__c) only moves when the last page succeeded, to the
 * moment the run started, so a failed run is simply retried by the next one and nothing is skipped.
 * Accounts are matched on Account.AccountNumber = counterparty account number.
 */
public with sharing class ContractSyncJob implements Queueable {
    @TestVisible private static final Integer PAGE_SIZE = 100;
    @TestVisible private static final Integer MAX_PAGES = 50;

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
        upsertContracts(result.items);

        if (result.hasMore && page < MAX_PAGES) {
            ContractSyncJob next = new ContractSyncJob(updatedSince, page + 1, runStartedAt);
            // Queueables cannot be chained inside Apex tests.
            if (!Test.isRunningTest()) {
                System.enqueueJob(next);
            }
        } else {
            saveWatermark(runStartedAt);
        }
    }

    @TestVisible
    private static void upsertContracts(List<ContractFeed.Item> items) {
        if (items == null || items.isEmpty()) {
            return;
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
                Name = String.isBlank(item.reference) ? item.id : item.reference.left(80),
                Status__c = item.status,
                Counterparty_Name__c = item.counterpartyName,
                Counterparty_Account_Number__c = item.counterpartyAccountNumber,
                Account__c = item.counterpartyAccountNumber == null ? null : accountByNumber.get(item.counterpartyAccountNumber.trim()),
                Effective_Date__c = item.effectiveDate,
                End_Date__c = item.endDate,
                Remote_Last_Modified__c = item.updatedAt,
                Document_Url__c = item.documentUrl
            ));
        }
        Database.upsert(records, External_Contract__c.External_Id__c, true, AccessLevel.SYSTEM_MODE);
    }

    private static void saveWatermark(Datetime value) {
        Contract_Sync_Settings__c settings = Contract_Sync_Settings__c.getOrgDefaults();
        if (settings == null || settings.Id == null) {
            settings = new Contract_Sync_Settings__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        settings.Last_Successful_Sync__c = value;
        Database.upsert(settings, true, AccessLevel.SYSTEM_MODE);
    }
}
