/**
 * Server API of the opportunity wizard (LWC opportunityWizard): Opportunity + products in one transaction.
 *
 *  Step 1  Opportunity fields from Wizard_Field__mdt (Object_Api_Name__c = Opportunity). The Account picker is
 *          limited to the record types configured on the AccountId row (Lookup_Record_Types__c).
 *  Step 2  Products of the price book chosen by PriceBookResolver (country of the Account, else the default),
 *          in the Account currency when the org uses multiple currencies. Each line needs a Line Type.
 *  Save    createOpportunity: stage = first open stage, price book and currency set by the server, only the
 *          configured fields are written (WizardFieldWriter), lines validated against the price book. Everything
 *          is rolled back if one line fails.
 *
 * Users without Create on Opportunity can use the wizard (system-mode DML in WizardSystemDml); access is the
 * custom permission Use_Opportunity_Wizard (permission set Opportunity_Wizard_User).
 */
public with sharing class OpportunityWizardController {
    public static final String ACCESS_PERMISSION = 'Use_Opportunity_Wizard';

    public class ProductOption {
        @AuraEnabled public Id pricebookEntryId;
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public String productCode;
        @AuraEnabled public String family;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String currencyIsoCode;
    }

    public class ProductCatalog {
        @AuraEnabled public PriceBookResolver.PriceBookChoice priceBook;
        @AuraEnabled public List<ProductOption> products;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean hasWizardAccess() {
        return FeatureManagement.checkPermission(ACCESS_PERMISSION);
    }

    @AuraEnabled(cacheable=true)
    public static List<WizardConfig.FieldConfig> getFields() {
        try {
            return WizardConfig.fields(Opportunity.SObjectType.getDescribe(), null);
        } catch (WizardException e) {
            throw auraError(e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static ProductCatalog getCatalog(Id accountId) {
        try {
            ProductCatalog catalog = new ProductCatalog();
            catalog.priceBook = PriceBookResolver.forAccount(accountId);
            catalog.products = new List<ProductOption>();
            String currencyCode = accountCurrency(accountId);
            Map<String, Object> binds = new Map<String, Object>{
                'priceBookId' => catalog.priceBook.priceBookId, 'currencyCode' => currencyCode
            };
            String soql = 'SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.Family, UnitPrice' +
                (currencyCode == null ? '' : ', CurrencyIsoCode') +
                ' FROM PricebookEntry WHERE Pricebook2Id = :priceBookId AND IsActive = true AND Product2.IsActive = true' +
                (currencyCode == null ? '' : ' AND CurrencyIsoCode = :currencyCode') +
                ' ORDER BY Product2.Name LIMIT 1000';
            for (SObject row : new WizardSystemDml().query(soql, binds)) {
                PricebookEntry entry = (PricebookEntry) row;
                ProductOption option = new ProductOption();
                option.pricebookEntryId = entry.Id;
                option.productId = entry.Product2Id;
                option.name = entry.Product2.Name;
                option.productCode = entry.Product2.ProductCode;
                option.family = entry.Product2.Family;
                option.unitPrice = entry.UnitPrice;
                option.currencyIsoCode = currencyCode;
                catalog.products.add(option);
            }
            return catalog;
        } catch (WizardException e) {
            throw auraError(e.getMessage());
        }
    }

    // linesJson: [{ "pricebookEntryId": "...", "quantity": 2, "unitPrice": 100, "discount": 5, "lineType": "Renewal" }]
    @AuraEnabled
    public static Id createOpportunity(String opportunityJson, String linesJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            if (!hasWizardAccess()) {
                throw new WizardException('You do not have access to this wizard. Ask your administrator for the Opportunity Wizard User permission set.');
            }
            Schema.DescribeSObjectResult opportunityDescribe = Opportunity.SObjectType.getDescribe();
            Map<String, Object> values = WizardFieldWriter.parse(opportunityJson);
            List<LineInput> lines = parseLines(linesJson);

            Opportunity opportunity = new Opportunity();
            WizardFieldWriter.apply(opportunity, opportunityDescribe, WizardConfig.fields(opportunityDescribe, null), values, false);
            if (opportunity.CloseDate == null || opportunity.CloseDate < Date.today()) {
                throw new WizardException('Close Date must be today or later.');
            }
            if (String.isBlank(opportunity.Name)) {
                throw new WizardException('Opportunity Name is required.');
            }

            // Stage, price book and currency are always decided here, never by the browser.
            opportunity.StageName = firstOpenStage();
            opportunity.Pricebook2Id = PriceBookResolver.forAccount(opportunity.AccountId).priceBookId;
            String currencyCode = accountCurrency(opportunity.AccountId);
            if (currencyCode != null) {
                opportunity.put('CurrencyIsoCode', currencyCode);
            }

            WizardSystemDml dml = new WizardSystemDml();
            dml.insertRecords(new List<SObject>{ opportunity });
            dml.insertRecords(buildLines(opportunity, currencyCode, lines));
            return opportunity.Id;
        } catch (WizardException e) {
            Database.rollback(sp);
            throw auraError(e.getMessage());
        } catch (DmlException e) {
            Database.rollback(sp);
            throw auraError(e.getDmlMessage(0));
        }
    }

    private class LineInput {
        Id pricebookEntryId;
        Decimal quantity;
        Decimal unitPrice;
        Decimal discount;
        String lineType;
    }

    private static List<LineInput> parseLines(String linesJson) {
        List<Object> raw = String.isBlank(linesJson) ? new List<Object>() : (List<Object>) JSON.deserializeUntyped(linesJson);
        List<LineInput> lines = new List<LineInput>();
        for (Object item : raw) {
            Map<String, Object> values = (Map<String, Object>) item;
            LineInput line = new LineInput();
            line.pricebookEntryId = Id.valueOf(String.valueOf(values.get('pricebookEntryId')));
            line.quantity = decimalOf(values.get('quantity'));
            line.unitPrice = decimalOf(values.get('unitPrice'));
            line.discount = values.get('discount') == null ? 0 : decimalOf(values.get('discount'));
            line.lineType = values.get('lineType') == null ? null : String.valueOf(values.get('lineType')).trim();
            if (line.quantity == null || line.quantity <= 0) {
                throw new WizardException('Quantity must be greater than zero.');
            }
            if (line.unitPrice == null || line.unitPrice < 0) {
                throw new WizardException('Sales Price cannot be negative.');
            }
            if (line.discount < 0 || line.discount > 100) {
                throw new WizardException('Discount must be between 0 and 100.');
            }
            if (String.isBlank(line.lineType)) {
                throw new WizardException('Line Type is required for every product.');
            }
            lines.add(line);
        }
        if (lines.isEmpty()) {
            throw new WizardException('Select at least one product.');
        }
        return lines;
    }

    // Every entry must still be active and belong to the price book (and currency) of the new Opportunity.
    private static List<OpportunityLineItem> buildLines(Opportunity opportunity, String currencyCode, List<LineInput> lines) {
        Set<Id> entryIds = new Set<Id>();
        for (LineInput line : lines) entryIds.add(line.pricebookEntryId);
        Map<String, Object> binds = new Map<String, Object>{
            'ids' => entryIds, 'priceBookId' => opportunity.Pricebook2Id, 'currencyCode' => currencyCode
        };
        Integer valid = new WizardSystemDml().query(
            'SELECT Id FROM PricebookEntry WHERE Id IN :ids AND Pricebook2Id = :priceBookId AND IsActive = true' +
            ' AND Product2.IsActive = true' + (currencyCode == null ? '' : ' AND CurrencyIsoCode = :currencyCode'),
            binds
        ).size();
        if (valid != entryIds.size()) {
            throw new WizardException('One or more products are not available in the price book of this Opportunity.');
        }
        List<OpportunityLineItem> items = new List<OpportunityLineItem>();
        for (LineInput line : lines) {
            items.add(new OpportunityLineItem(
                OpportunityId = opportunity.Id,
                PricebookEntryId = line.pricebookEntryId,
                Quantity = line.quantity,
                UnitPrice = line.unitPrice,
                Discount = line.discount,
                Line_Type__c = line.lineType
            ));
        }
        return items;
    }

    @TestVisible
    private static String firstOpenStage() {
        List<OpportunityStage> stages = [
            SELECT ApiName FROM OpportunityStage WHERE IsActive = true AND IsClosed = false ORDER BY SortOrder LIMIT 1
        ];
        if (stages.isEmpty()) {
            throw new WizardException('No active open Opportunity stage is configured.');
        }
        return stages[0].ApiName;
    }

    // Null when the org has a single currency.
    private static String accountCurrency(Id accountId) {
        if (accountId == null || !UserInfo.isMultiCurrencyOrganization()) {
            return null;
        }
        List<SObject> rows = new WizardSystemDml().query(
            'SELECT CurrencyIsoCode FROM Account WHERE Id = :accountId', new Map<String, Object>{ 'accountId' => accountId }
        );
        return rows.isEmpty() ? null : (String) rows[0].get('CurrencyIsoCode');
    }

    private static Decimal decimalOf(Object raw) {
        return raw == null || String.isBlank(String.valueOf(raw)) ? null : Decimal.valueOf(String.valueOf(raw));
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
