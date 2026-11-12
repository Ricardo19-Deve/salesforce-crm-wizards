// Demo data for the CRM Wizards (fictitious companies and people only).
// Run: sf apex run -o <org> -f scripts/apex/seed-demo-data.apex
// Safe to run again: previous demo records (accounts ACC-10xx, people with *.example emails) are deleted first.
// Description is a long text field (not filterable), so it only labels the records.

String TAG = 'CRM Wizards demo';

delete [SELECT Id FROM Opportunity WHERE Account.AccountNumber LIKE 'ACC-10%'];
delete [SELECT Id FROM Lead WHERE Email LIKE '%.example' AND IsConverted = false];
delete [SELECT Id FROM Contact WHERE Email LIKE '%.example'];
delete [SELECT Id FROM Account WHERE AccountNumber LIKE 'ACC-10%'];
delete [SELECT Id FROM External_Contract__c];

Map<String, Id> accountTypes = new Map<String, Id>();
for (RecordType rt : [SELECT Id, DeveloperName FROM RecordType WHERE SobjectType IN ('Account', 'Contact')]) {
    accountTypes.put(rt.DeveloperName, rt.Id);
}

List<Account> accounts = new List<Account>{
    new Account(Name = 'Northwind Traders', AccountNumber = 'ACC-1001', BillingCity = 'Lisbon', BillingCountry = 'Portugal', RecordTypeId = accountTypes.get('Customer_Account'), Description = TAG),
    new Account(Name = 'Contoso Ltd', AccountNumber = 'ACC-1002', BillingCity = 'Madrid', BillingCountry = 'Spain', RecordTypeId = accountTypes.get('Customer_Account'), Description = TAG),
    new Account(Name = 'Fabrikam Inc', AccountNumber = 'ACC-1003', BillingCity = 'Lyon', BillingCountry = 'France', RecordTypeId = accountTypes.get('Customer_Account'), Description = TAG),
    new Account(Name = 'Tailspin Toys', AccountNumber = 'ACC-1004', BillingCity = 'Porto', BillingCountry = 'Portugal', RecordTypeId = accountTypes.get('Customer_Account'), Description = TAG),
    new Account(Name = 'Adventure Works', AccountNumber = 'ACC-1005', BillingCity = 'Munich', BillingCountry = 'Germany', RecordTypeId = accountTypes.get('Customer_Account'), Description = TAG),
    new Account(Name = 'Blue Yonder Distribution', AccountNumber = 'ACC-1006', BillingCity = 'Seville', BillingCountry = 'Spain', RecordTypeId = accountTypes.get('Partner_Account'), Description = TAG)
};
insert accounts;

Id customer = accountTypes.get('Customer_Contact');
Id partner = accountTypes.get('Partner_Contact');
insert new List<Contact>{
    // Scenario A: same person twice (merge) - "Maria Santos"
    new Contact(FirstName = 'Maria', LastName = 'Santos', Email = 'maria.santos@northwind.example', MobilePhone = '+351 912 000 001', AccountId = accounts[0].Id, RecordTypeId = customer, Title = 'Procurement Lead', Description = TAG),
    new Contact(FirstName = 'Maria', LastName = 'Santos', Email = 'm.santos@tailspin.example', AccountId = accounts[3].Id, RecordTypeId = customer, Title = 'Buyer', Description = TAG),
    // Scenario B: unique contact - "Daniel Weber"
    new Contact(FirstName = 'Daniel', LastName = 'Weber', Email = 'daniel.weber@adventure.example', AccountId = accounts[4].Id, RecordTypeId = customer, Description = TAG),
    new Contact(FirstName = 'Lucia', LastName = 'Garcia', Email = 'lucia.garcia@blueyonder.example', AccountId = accounts[5].Id, RecordTypeId = partner, Description = TAG)
};

insert new List<Lead>{
    // Scenario A: the same Maria as a Lead (convert into the kept Contact)
    new Lead(FirstName = 'Maria', LastName = 'Santos', Email = 'maria.santos@northwind.example', Company = 'Northwind Traders', Preferred_Language__c = 'Portuguese', Description = TAG),
    // Scenario C: only a Lead exists - "Tomas Novak" (create Contact + convert, account suggestion from Company)
    new Lead(FirstName = 'Tomas', LastName = 'Novak', Email = 'tomas.novak@fabrikam.example', Company = 'Fabrikam', MobilePhone = '+33 600 000 002', Description = TAG)
};

// Products and price books: Global (default), Portugal and Spain (country rules in Price_Book_Rule__mdt).
Id standardBook = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
update new Pricebook2(Id = standardBook, IsActive = true);

Map<String, Pricebook2> books = new Map<String, Pricebook2>();
for (Pricebook2 book : [SELECT Id, Name FROM Pricebook2 WHERE Name IN ('Global Price Book', 'Portugal Price Book', 'Spain Price Book')]) {
    books.put(book.Name, book);
}
for (String name : new List<String>{ 'Global Price Book', 'Portugal Price Book', 'Spain Price Book' }) {
    if (!books.containsKey(name)) books.put(name, new Pricebook2(Name = name, IsActive = true));
}
upsert books.values();

List<Product2> products = [SELECT Id, ProductCode FROM Product2 WHERE ProductCode IN ('LIC-START', 'LIC-PRO', 'SRV-IMPL', 'SRV-TRAIN', 'SUP-PREM', 'SRV-DATA')];
if (products.isEmpty()) {
    products = new List<Product2>{
        new Product2(Name = 'CRM Starter Licence', ProductCode = 'LIC-START', Family = 'Licences', IsActive = true, Description = TAG),
        new Product2(Name = 'CRM Professional Licence', ProductCode = 'LIC-PRO', Family = 'Licences', IsActive = true, Description = TAG),
        new Product2(Name = 'Implementation Package', ProductCode = 'SRV-IMPL', Family = 'Services', IsActive = true, Description = TAG),
        new Product2(Name = 'Training Day', ProductCode = 'SRV-TRAIN', Family = 'Services', IsActive = true, Description = TAG),
        new Product2(Name = 'Premium Support (12 months)', ProductCode = 'SUP-PREM', Family = 'Support', IsActive = true, Description = TAG),
        new Product2(Name = 'Data Migration', ProductCode = 'SRV-DATA', Family = 'Services', IsActive = true, Description = TAG)
    };
    insert products;
}

Map<String, Decimal> listPrice = new Map<String, Decimal>{
    'LIC-START' => 300, 'LIC-PRO' => 900, 'SRV-IMPL' => 12000, 'SRV-TRAIN' => 1500, 'SUP-PREM' => 4800, 'SRV-DATA' => 6000
};
Set<String> existing = new Set<String>();
for (PricebookEntry e : [SELECT Pricebook2Id, Product2Id FROM PricebookEntry WHERE Product2Id IN :products]) {
    existing.add(e.Pricebook2Id + ':' + e.Product2Id);
}
List<PricebookEntry> standardEntries = new List<PricebookEntry>();
List<PricebookEntry> customEntries = new List<PricebookEntry>();
for (Product2 p : products) {
    Decimal price = listPrice.get(p.ProductCode);
    if (!existing.contains(standardBook + ':' + p.Id)) {
        standardEntries.add(new PricebookEntry(Pricebook2Id = standardBook, Product2Id = p.Id, UnitPrice = price, IsActive = true));
    }
    Map<String, Decimal> factorByBook = new Map<String, Decimal>{ 'Global Price Book' => 1, 'Portugal Price Book' => 0.9, 'Spain Price Book' => 0.95 };
    for (String bookName : factorByBook.keySet()) {
        Id bookId = books.get(bookName).Id;
        // Spain sells licences only, to show that the catalog changes with the country.
        if (bookName == 'Spain Price Book' && !p.ProductCode.startsWith('LIC')) continue;
        if (!existing.contains(bookId + ':' + p.Id)) {
            customEntries.add(new PricebookEntry(Pricebook2Id = bookId, Product2Id = p.Id, UnitPrice = price * factorByBook.get(bookName), IsActive = true));
        }
    }
}
insert standardEntries;
insert customEntries;

// Contract sync from the mock source (sample JSON in the static resource MockContracts).
delete [SELECT Id FROM Contract_Sync_Settings__c];
System.enqueueJob(new ContractSyncJob(null, 1, null));

System.debug('Demo data ready: ' + accounts.size() + ' accounts, 4 contacts, 2 leads, ' + products.size() + ' products.');
