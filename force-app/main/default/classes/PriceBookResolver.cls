/**
 * Picks the price book of an Opportunity from the Account's billing country (Price_Book_Rule__mdt).
 *
 *  - Active rule whose Country__c equals Account.BillingCountry (case-insensitive) -> that price book, if active.
 *  - Otherwise the active rule marked Is_Default__c.
 * If the same rule is also needed by automation (e.g. a before-insert flow on Opportunity), read the same
 * custom metadata there so UI and automation never disagree.
 */
public with sharing class PriceBookResolver {
    @TestVisible private static List<Price_Book_Rule__mdt> ruleRows;

    public class PriceBookChoice {
        @AuraEnabled public Id priceBookId;
        @AuraEnabled public String name;
        @AuraEnabled public Boolean isCountrySpecific;
    }

    public static PriceBookChoice forAccount(Id accountId) {
        String country;
        if (accountId != null) {
            List<Account> accounts = [SELECT BillingCountry FROM Account WHERE Id = :accountId WITH SYSTEM_MODE LIMIT 1];
            if (!accounts.isEmpty() && !String.isBlank(accounts[0].BillingCountry)) {
                country = accounts[0].BillingCountry.trim();
            }
        }

        String countryBook;
        String defaultBook;
        for (Price_Book_Rule__mdt rule : rules()) {
            if (rule.Is_Default__c == true) {
                defaultBook = rule.Price_Book_Name__c;
            } else if (country != null && country.equalsIgnoreCase(rule.Country__c?.trim())) {
                countryBook = rule.Price_Book_Name__c;
            }
        }

        if (countryBook != null) {
            PriceBookChoice choice = find(countryBook, true);
            if (choice != null) return choice;
        }
        if (defaultBook == null) {
            throw new WizardException('No default Price Book Rule is configured.');
        }
        PriceBookChoice fallback = find(defaultBook, false);
        if (fallback == null) {
            throw new WizardException('Active price book "' + defaultBook + '" was not found.');
        }
        return fallback;
    }

    private static PriceBookChoice find(String name, Boolean isCountrySpecific) {
        List<Pricebook2> books = [
            SELECT Id, Name FROM Pricebook2 WHERE Name = :name AND IsActive = true WITH SYSTEM_MODE LIMIT 2
        ];
        if (books.size() != 1) {
            return null;
        }
        PriceBookChoice choice = new PriceBookChoice();
        choice.priceBookId = books[0].Id;
        choice.name = books[0].Name;
        choice.isCountrySpecific = isCountrySpecific;
        return choice;
    }

    private static List<Price_Book_Rule__mdt> rules() {
        List<Price_Book_Rule__mdt> source = ruleRows != null ? ruleRows : Price_Book_Rule__mdt.getAll().values();
        List<Price_Book_Rule__mdt> active = new List<Price_Book_Rule__mdt>();
        for (Price_Book_Rule__mdt rule : source) {
            if (rule.Active__c == true && !String.isBlank(rule.Price_Book_Name__c)) active.add(rule);
        }
        return active;
    }
}
