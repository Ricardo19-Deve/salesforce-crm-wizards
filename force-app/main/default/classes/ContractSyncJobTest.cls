@IsTest
private class ContractSyncJobTest {

    // Two-page fake source, to test paging and the watermark without the static resource.
    private class TwoPageSource implements ContractFeed.Source {
        public ContractFeed.ResultPage fetchUpdatedSince(Datetime updatedSince, Integer page, Integer pageSize) {
            ContractFeed.ResultPage result = new ContractFeed.ResultPage();
            ContractFeed.Item item = new ContractFeed.Item();
            item.id = 'EXT-' + page;
            item.reference = 'REF-' + page;
            item.status = 'Signed';
            item.counterpartyName = 'Northwind Traders';
            item.counterpartyAccountNumber = 'ACC-1001';
            item.updatedAt = Datetime.now();
            result.items.add(item);
            result.hasMore = page == 1;
            return result;
        }
    }

    @TestSetup
    static void setup() {
        insert new Account(Name = 'Northwind Traders', AccountNumber = 'ACC-1001');
    }

    @IsTest
    static void firstPageIsUpsertedAndLinkedToTheAccount() {
        ContractFeed.sourceOverride = new TwoPageSource();
        Test.startTest();
        System.enqueueJob(new ContractSyncJob(null, 1, null));
        Test.stopTest();

        External_Contract__c contract = [SELECT Name, Account__r.Name FROM External_Contract__c WHERE External_Id__c = 'EXT-1'];
        Assert.areEqual('REF-1', contract.Name);
        Assert.areEqual('Northwind Traders', contract.Account__r.Name);
        Assert.isNull(Contract_Sync_Settings__c.getOrgDefaults().Last_Successful_Sync__c, 'More pages pending: watermark unchanged');
    }

    @IsTest
    static void lastPageMovesTheWatermark() {
        ContractFeed.sourceOverride = new TwoPageSource();
        Datetime started = Datetime.now().addMinutes(-5);
        Test.startTest();
        System.enqueueJob(new ContractSyncJob(null, 2, started));
        Test.stopTest();

        Assert.areEqual(started, Contract_Sync_Settings__c.getOrgDefaults().Last_Successful_Sync__c);
    }

    @IsTest
    static void upsertIsIdempotent() {
        ContractFeed.Item item = new ContractFeed.Item();
        item.id = 'EXT-9';
        item.status = 'Draft';
        ContractSyncJob.upsertContracts(new List<ContractFeed.Item>{ item });
        item.status = 'Signed';
        ContractSyncJob.upsertContracts(new List<ContractFeed.Item>{ item });

        List<External_Contract__c> rows = [SELECT Name, Status__c FROM External_Contract__c];
        Assert.areEqual(1, rows.size());
        Assert.areEqual('Signed', rows[0].Status__c);
        Assert.areEqual('EXT-9', rows[0].Name, 'Id is used when there is no reference');
    }

    @IsTest
    static void mockSourcePagesTheSampleData() {
        MockContractSource source = new MockContractSource();
        ContractFeed.ResultPage first = source.fetchUpdatedSince(null, 1, 5);
        Assert.areEqual(5, first.items.size());
        Assert.isTrue(first.hasMore);
        ContractFeed.ResultPage none = source.fetchUpdatedSince(Datetime.now().addYears(10), 1, 5);
        Assert.areEqual(0, none.items.size());
        Assert.isFalse(none.hasMore);
    }

    @IsTest
    static void schedulerEnqueuesTheSync() {
        Test.startTest();
        String jobId = System.schedule('Contract sync test', '0 0 2 * * ?', new ContractSyncScheduler());
        Test.stopTest();
        Assert.isNotNull(jobId);
        Assert.isTrue(ContractFeed.source() instanceof MockContractSource, 'Mock source by default');
    }
}
