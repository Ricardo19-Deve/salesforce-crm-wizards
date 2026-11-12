@IsTest
private class OpportunityWizardControllerTest {

    @TestSetup
    static void setup() {
        insert new List<Account>{
            WizardTestData.customerAccount('Northwind Traders', 'Portugal'),
            WizardTestData.customerAccount('Contoso Ltd', 'France')
        };
        Product2 laptop = new Product2(Name = 'Laptop Pro', ProductCode = 'LP-01', Family = 'Hardware', IsActive = true);
        Product2 support = new Product2(Name = 'Support Plan', ProductCode = 'SP-01', Family = 'Services', IsActive = true);
        insert new List<Product2>{ laptop, support };

        Pricebook2 globalBook = new Pricebook2(Name = 'Global Price Book', IsActive = true);
        Pricebook2 portugal = new Pricebook2(Name = 'Portugal Price Book', IsActive = true);
        insert new List<Pricebook2>{ globalBook, portugal };

        Id standard = Test.getStandardPricebookId();
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = standard, Product2Id = laptop.Id, UnitPrice = 1000, IsActive = true),
            new PricebookEntry(Pricebook2Id = standard, Product2Id = support.Id, UnitPrice = 200, IsActive = true)
        };
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = globalBook.Id, Product2Id = laptop.Id, UnitPrice = 1100, IsActive = true),
            new PricebookEntry(Pricebook2Id = globalBook.Id, Product2Id = support.Id, UnitPrice = 220, IsActive = true),
            new PricebookEntry(Pricebook2Id = portugal.Id, Product2Id = laptop.Id, UnitPrice = 950, IsActive = true)
        };

        System.runAs(new User(Id = UserInfo.getUserId())) {
            WizardTestData.userWith(new List<String>{ 'Opportunity_Wizard_User' });
        }
    }

    private static void useRules() {
        PriceBookResolver.ruleRows = new List<Price_Book_Rule__mdt>{
            new Price_Book_Rule__mdt(Price_Book_Name__c = 'Global Price Book', Is_Default__c = true, Active__c = true),
            new Price_Book_Rule__mdt(Country__c = 'Portugal', Price_Book_Name__c = 'Portugal Price Book', Active__c = true)
        };
    }

    private static User wizardUser() {
        return [SELECT Id FROM User WHERE LastName = 'Wizard Tester' ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static Id accountId(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1].Id;
    }

    @IsTest
    static void priceBookFollowsTheAccountCountry() {
        useRules();
        Assert.areEqual('Portugal Price Book', PriceBookResolver.forAccount(accountId('Northwind Traders')).name);
        Assert.isTrue(PriceBookResolver.forAccount(accountId('Northwind Traders')).isCountrySpecific);
        Assert.areEqual('Global Price Book', PriceBookResolver.forAccount(accountId('Contoso Ltd')).name, 'No rule for France');
        Assert.areEqual('Global Price Book', PriceBookResolver.forAccount(null).name);
    }

    @IsTest
    static void missingDefaultRuleIsReported() {
        PriceBookResolver.ruleRows = new List<Price_Book_Rule__mdt>();
        try {
            PriceBookResolver.forAccount(null);
            Assert.fail('A default rule is required');
        } catch (WizardException e) {
            Assert.isTrue(e.getMessage().contains('default'));
        }
    }

    @IsTest
    static void catalogListsThePriceBookProducts() {
        useRules();
        System.runAs(wizardUser()) {
            Assert.isTrue(OpportunityWizardController.hasWizardAccess());
            Assert.isFalse(OpportunityWizardController.getFields().isEmpty());
            OpportunityWizardController.ProductCatalog catalog = OpportunityWizardController.getCatalog(accountId('Contoso Ltd'));
            Assert.areEqual(2, catalog.products.size());
            Assert.areEqual(1, OpportunityWizardController.getCatalog(accountId('Northwind Traders')).products.size());
        }
    }

    @IsTest
    static void createsOpportunityWithLines() {
        useRules();
        Id accountId = accountId('Contoso Ltd');
        PricebookEntry laptop = [SELECT Id FROM PricebookEntry WHERE Pricebook2.Name = 'Global Price Book' AND Product2.ProductCode = 'LP-01'];
        Map<String, Object> opportunity = new Map<String, Object>{
            'AccountId' => accountId, 'Name' => 'Contoso - laptops', 'CloseDate' => String.valueOf(Date.today().addDays(30)),
            'StageName' => 'Closed Won', 'Probability' => 100
        };
        List<Object> lines = new List<Object>{ new Map<String, Object>{
            'pricebookEntryId' => laptop.Id, 'quantity' => 3, 'unitPrice' => 1000, 'discount' => 10, 'lineType' => 'New Business'
        } };

        Id opportunityId;
        Test.startTest();
        System.runAs(wizardUser()) {
            opportunityId = OpportunityWizardController.createOpportunity(JSON.serialize(opportunity), JSON.serialize(lines));
        }
        Test.stopTest();

        Opportunity saved = [SELECT StageName, IsClosed, Pricebook2.Name, (SELECT Quantity, Line_Type__c FROM OpportunityLineItems)
                             FROM Opportunity WHERE Id = :opportunityId];
        Assert.isFalse(saved.IsClosed, 'The stage sent by the browser is ignored');
        Assert.areEqual(OpportunityWizardController.firstOpenStage(), saved.StageName);
        Assert.areEqual('Global Price Book', saved.Pricebook2.Name);
        Assert.areEqual(1, saved.OpportunityLineItems.size());
        Assert.areEqual('New Business', saved.OpportunityLineItems[0].Line_Type__c);
    }

    @IsTest
    static void invalidInputRollsBack() {
        useRules();
        Id accountId = accountId('Northwind Traders');
        PricebookEntry wrongBook = [SELECT Id FROM PricebookEntry WHERE Pricebook2.Name = 'Global Price Book' AND Product2.ProductCode = 'SP-01'];
        Map<String, Object> opportunity = new Map<String, Object>{
            'AccountId' => accountId, 'Name' => 'Northwind', 'CloseDate' => String.valueOf(Date.today().addDays(5))
        };
        List<Map<String, Object>> cases = new List<Map<String, Object>>{
            new Map<String, Object>{ 'pricebookEntryId' => wrongBook.Id, 'quantity' => 1, 'unitPrice' => 1, 'lineType' => 'Renewal' },
            new Map<String, Object>{ 'pricebookEntryId' => wrongBook.Id, 'quantity' => 0, 'unitPrice' => 1, 'lineType' => 'Renewal' },
            new Map<String, Object>{ 'pricebookEntryId' => wrongBook.Id, 'quantity' => 1, 'unitPrice' => -1, 'lineType' => 'Renewal' },
            new Map<String, Object>{ 'pricebookEntryId' => wrongBook.Id, 'quantity' => 1, 'unitPrice' => 1, 'discount' => 150, 'lineType' => 'Renewal' },
            new Map<String, Object>{ 'pricebookEntryId' => wrongBook.Id, 'quantity' => 1, 'unitPrice' => 1 }
        };
        System.runAs(wizardUser()) {
            for (Map<String, Object> line : cases) {
                try {
                    OpportunityWizardController.createOpportunity(JSON.serialize(opportunity), JSON.serialize(new List<Object>{ line }));
                    Assert.fail('Invalid line accepted: ' + line);
                } catch (AuraHandledException e) {
                    Assert.isNotNull(e.getMessage());
                }
            }
            try {
                opportunity.put('CloseDate', String.valueOf(Date.today().addDays(-1)));
                OpportunityWizardController.createOpportunity(JSON.serialize(opportunity), JSON.serialize(new List<Object>{ cases[0] }));
                Assert.fail('Past close date accepted');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Close Date'));
            }
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Opportunity], 'Nothing is left behind');
    }

    @IsTest
    static void usersWithoutThePermissionCannotSave() {
        User noAccess = WizardTestData.userWith(new List<String>());
        System.runAs(noAccess) {
            try {
                OpportunityWizardController.createOpportunity('{}', '[]');
                Assert.fail('Users without Use_Opportunity_Wizard must be rejected');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('do not have access'));
            }
        }
    }
}
