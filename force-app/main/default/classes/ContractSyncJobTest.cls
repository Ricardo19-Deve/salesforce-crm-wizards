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

    // Always reports more pages; items carry the given timestamps.
    private class EndlessSource implements ContractFeed.Source {
        final List<ContractFeed.Item> items;
        EndlessSource(List<ContractFeed.Item> items) {
            this.items = items;
        }
        public ContractFeed.ResultPage fetchUpdatedSince(Datetime updatedSince, Integer page, Integer pageSize) {
            ContractFeed.ResultPage result = new ContractFeed.ResultPage();
            result.items.addAll(items);
            result.hasMore = true;
            return result;
        }
    }

    private static ContractFeed.Item item(String id, Datetime updatedAt) {
        ContractFeed.Item item = new ContractFeed.Item();
        item.id = id;
        item.reference = 'REF ' + id;
        item.status = 'Signed';
        item.updatedAt = updatedAt;
        return item;
    }

    @IsTest
    static void stoppingAtThePageLimitKeepsTheUnreadContracts() {
        Datetime newest = Datetime.newInstanceGmt(2026, 3, 1, 10, 0, 0);
        ContractFeed.sourceOverride = new EndlessSource(new List<ContractFeed.Item>{
            item('EXT-A', newest.addHours(-1)), item('EXT-B', newest)
        });
        Test.startTest();
        System.enqueueJob(new ContractSyncJob(null, ContractSyncJob.MAX_PAGES, Datetime.now()));
        Test.stopTest();

        Contract_Sync_Settings__c settings = Contract_Sync_Settings__c.getOrgDefaults();
        Assert.areEqual(newest.addSeconds(-1), settings.Last_Successful_Sync__c,
            'The next run continues just before the newest saved change, not from the start of this run');
        Assert.isTrue(settings.Last_Sync_Errors__c.contains('Stopped at'), 'The stop is reported');
    }

    @IsTest
    static void oneBadContractDoesNotBlockTheOthers() {
        ContractFeed.Item bad = item('X'.repeat(90), Datetime.now());   // longer than External_Id__c allows
        ContractFeed.Item good = item('EXT-OK', Datetime.now());
        good.status = 'S'.repeat(120);                                   // longer than Status__c: shortened
        ContractFeed.sourceOverride = new SinglePageSource(new List<ContractFeed.Item>{ bad, good });
        Datetime started = Datetime.now().addMinutes(-1);
        Test.startTest();
        System.enqueueJob(new ContractSyncJob(null, 1, started));
        Test.stopTest();

        External_Contract__c saved = [SELECT Status__c FROM External_Contract__c WHERE External_Id__c = 'EXT-OK'];
        Assert.areEqual(80, saved.Status__c.length());
        Contract_Sync_Settings__c settings = Contract_Sync_Settings__c.getOrgDefaults();
        Assert.areEqual(1, settings.Last_Sync_Error_Count__c);
        Assert.isTrue(settings.Last_Sync_Errors__c.startsWith('XXXX'), 'The failed external id is reported');
        Assert.areEqual(started, settings.Last_Successful_Sync__c, 'The run still completes');
    }

    private class SinglePageSource implements ContractFeed.Source {
        final List<ContractFeed.Item> items;
        SinglePageSource(List<ContractFeed.Item> items) {
            this.items = items;
        }
        public ContractFeed.ResultPage fetchUpdatedSince(Datetime updatedSince, Integer page, Integer pageSize) {
            ContractFeed.ResultPage result = new ContractFeed.ResultPage();
            result.items.addAll(items);
            return result;
        }
    }

    @IsTest
    static void mockSourceReturnsTheOldestChangeFirst() {
        ContractFeed.ResultPage all = new MockContractSource().fetchUpdatedSince(null, 1, 1000);
        for (Integer i = 1; i < all.items.size(); i++) {
            Assert.isTrue(all.items[i - 1].updatedAt <= all.items[i].updatedAt, 'Ascending updatedAt');
        }
    }
}
