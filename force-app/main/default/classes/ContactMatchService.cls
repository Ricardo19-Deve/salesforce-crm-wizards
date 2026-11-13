/**
 * Identify step of the Contact wizard: finds existing Contacts and unconverted Leads that look like the person
 * being created, and suggests Accounts from a Lead's free-text Company.
 *
 * Scoring
 *  - Each Wizard_Match_Rule__mdt has a weight. Score = sum of the weights of the rules whose value is equal
 *    (case-insensitive; phone numbers compared on digits only), capped at 100.
 *  - Only rules whose weight reaches the minimum score on their own (e.g. Email, Last Name) are used as SOQL
 *    filters, one query per filter. The others (First Name, Mobile, Account) only add points: as a filter a
 *    common first name or a large Account would fill the row limit and hide the real matches.
 *
 * Encrypted fields: with Shield Platform Encryption (deterministic, case-sensitive) email, phone and name fields
 * only support exact comparisons and cannot be used in ORDER BY or LIKE, so the usual capitalisations of every
 * value are searched explicitly (variants()). Without encryption this is simply a harmless IN list.
 */
public with sharing class ContactMatchService {
    public static final Integer MAX_CANDIDATES = 25;
    private static final Integer ROWS_PER_FILTER = 200;

    public class MatchCandidate {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String recordType;   // 'Contact' or 'Lead'
        @AuraEnabled public String name;
        @AuraEnabled public String detail;
        @AuraEnabled public Integer score;
        @AuraEnabled public List<String> matched;
        @AuraEnabled public List<String> notMatched;
        @AuraEnabled public Id accountId;        // Contact account, or the Account whose name equals the Lead Company
        @AuraEnabled public String accountName;
        @AuraEnabled public String company;      // Lead Company (free text), used for Account suggestions
        @AuraEnabled public String email;
    }

    public class MatchResult {
        @AuraEnabled public Integer minimumScore;
        @AuraEnabled public List<MatchCandidate> candidates;
    }

    public class AccountSuggestion {
        @AuraEnabled public Id accountId;
        @AuraEnabled public String name;
        @AuraEnabled public String detail;
        @AuraEnabled public Boolean exact;
    }

    private final WizardSystemDml dml = new WizardSystemDml();

    public MatchResult findMatches(WizardConfig.RecordTypeOption recordType, Map<String, Object> inputs) {
        Schema.DescribeSObjectResult contactDescribe = Contact.SObjectType.getDescribe();
        Map<String, Schema.SObjectField> fieldMap = contactDescribe.fields.getMap();
        List<WizardConfig.MatchRule> rules = WizardConfig.matchRules(contactDescribe);

        MatchResult result = new MatchResult();
        result.minimumScore = WizardConfig.minimumScore('Contact', recordType.developerName);
        result.candidates = new List<MatchCandidate>();

        String inputAccountName;
        List<String> contactFilters = new List<String>();
        List<String> leadFilters = new List<String>();
        Map<String, Object> contactBinds = new Map<String, Object>();
        Map<String, Object> leadBinds = new Map<String, Object>();
        Integer i = 0;
        for (WizardConfig.MatchRule rule : rules) {
            String value = inputValue(inputs, rule.fieldApiName);
            if (value == null) {
                continue;
            }
            Schema.DescribeFieldResult fieldDescribe = fieldMap.get(rule.fieldApiName.toLowerCase()).getDescribe();
            String bind = 'v' + (i++);
            if (fieldDescribe.getType() == Schema.DisplayType.REFERENCE) {
                if (rule.fieldApiName == 'AccountId') {
                    inputAccountName = accountName(Id.valueOf(value));
                }
            } else if (rule.weight >= result.minimumScore) {
                contactFilters.add(rule.fieldApiName + ' IN :' + bind);
                contactBinds.put(bind, variants(value));
                if (rule.leadFieldApiName != null) {
                    leadFilters.add(rule.leadFieldApiName + ' IN :' + bind);
                    leadBinds.put(bind, variants(value));
                }
            }
        }
        if (contactFilters.isEmpty()) {
            return result;
        }

        Set<Id> recordTypeIds = new Set<Id>();
        for (WizardConfig.RecordTypeOption option : WizardConfig.availableRecordTypes(contactDescribe)) {
            recordTypeIds.add(option.recordTypeId);
        }
        contactBinds.put('recordTypeIds', recordTypeIds);

        Set<String> contactFields = new Set<String>{ 'Id', 'Name', 'Email', 'AccountId', 'Account.Name', 'RecordType.Name' };
        for (WizardConfig.MatchRule rule : rules) {
            contactFields.add(rule.fieldApiName);
        }
        Map<Id, SObject> contactsFound = new Map<Id, SObject>();
        for (String filter : contactFilters) {
            contactsFound.putAll(dml.query(
                'SELECT ' + String.join(new List<String>(contactFields), ', ') + ' FROM Contact' +
                ' WHERE RecordTypeId IN :recordTypeIds AND ' + filter + ' LIMIT ' + ROWS_PER_FILTER,
                contactBinds
            ));
        }
        for (SObject record : contactsFound.values()) {
            Contact c = (Contact) record;
            MatchCandidate candidate = score(record, rules, inputs, false, inputAccountName, fieldMap);
            candidate.recordType = 'Contact';
            candidate.name = c.Name;
            candidate.accountId = c.AccountId;
            candidate.accountName = c.Account?.Name;
            candidate.email = c.Email;
            candidate.detail = joinParts(new List<String>{ c.Email, c.Account?.Name, c.RecordType?.Name });
            result.candidates.add(candidate);
        }

        if (!leadFilters.isEmpty()) {
            Set<String> leadFields = new Set<String>{ 'Id', 'Name', 'Email', 'Company' };
            for (WizardConfig.MatchRule rule : rules) {
                if (rule.leadFieldApiName != null) leadFields.add(rule.leadFieldApiName);
            }
            Map<Id, Lead> leadsFound = new Map<Id, Lead>();
            for (String filter : leadFilters) {
                leadsFound.putAll((List<Lead>) dml.query(
                    'SELECT ' + String.join(new List<String>(leadFields), ', ') +
                    ' FROM Lead WHERE IsConverted = false AND ' + filter + ' LIMIT ' + ROWS_PER_FILTER,
                    leadBinds
                ));
            }
            Map<String, Account> accountsByCompany = companyAccounts(leadsFound.values(), recordType);
            for (Lead l : leadsFound.values()) {
                MatchCandidate candidate = score(l, rules, inputs, true, inputAccountName, fieldMap);
                candidate.recordType = 'Lead';
                candidate.name = l.Name;
                Account companyAccount = l.Company == null ? null : accountsByCompany.get(l.Company.trim().toLowerCase());
                candidate.accountId = companyAccount?.Id;
                candidate.accountName = companyAccount?.Name;
                candidate.company = l.Company;
                candidate.email = l.Email;
                candidate.detail = joinParts(new List<String>{ l.Email, l.Company });
                result.candidates.add(candidate);
            }
        }

        List<MatchCandidate> kept = new List<MatchCandidate>();
        for (MatchCandidate candidate : result.candidates) {
            if (candidate.score >= result.minimumScore) kept.add(candidate);
        }
        kept.sort(new HighestScoreFirst());
        result.candidates = new List<MatchCandidate>();
        for (Integer a = 0; a < Math.min(kept.size(), MAX_CANDIDATES); a++) {
            result.candidates.add(kept[a]);
        }
        return result;
    }

    // Accounts whose name contains a Lead Company (exact names first), restricted to the record types the
    // wizard allows for Contact.AccountId.
    public List<AccountSuggestion> suggestAccounts(WizardConfig.RecordTypeOption recordType, List<String> companies) {
        List<AccountSuggestion> suggestions = new List<AccountSuggestion>();
        if (companies == null || companies.isEmpty()) return suggestions;
        Set<Id> recordTypes = allowedAccountRecordTypes(recordType);
        Set<Id> seen = new Set<Id>();
        for (String company : companies) {
            if (String.isBlank(company) || company.trim().length() < 3) continue;
            String term = company.trim();
            Map<String, Object> binds = new Map<String, Object>{
                'pattern' => '%' + term.replace('%', '').replace('_', '\\_') + '%', 'recordTypes' => recordTypes
            };
            for (SObject row : dml.query(
                'SELECT Id, Name, BillingCity, BillingCountry FROM Account WHERE Name LIKE :pattern' +
                (recordTypes.isEmpty() ? '' : ' AND RecordTypeId IN :recordTypes') + ' ORDER BY Name LIMIT 10',
                binds
            )) {
                Account acc = (Account) row;
                if (seen.contains(acc.Id)) continue;
                seen.add(acc.Id);
                AccountSuggestion suggestion = new AccountSuggestion();
                suggestion.accountId = acc.Id;
                suggestion.name = acc.Name;
                suggestion.detail = joinParts(new List<String>{ acc.BillingCity, acc.BillingCountry });
                suggestion.exact = acc.Name.trim().equalsIgnoreCase(term);
                if (suggestion.exact && !suggestions.isEmpty()) suggestions.add(0, suggestion); else suggestions.add(suggestion);
            }
        }
        List<AccountSuggestion> top = new List<AccountSuggestion>();
        for (Integer i = 0; i < Math.min(5, suggestions.size()); i++) top.add(suggestions[i]);
        return top;
    }

    // Lead Company -> the single eligible Account whose name is exactly that Company (ambiguous names are skipped).
    public Map<String, Account> companyAccounts(List<Lead> leads, WizardConfig.RecordTypeOption recordType) {
        Set<String> companies = new Set<String>();
        for (Lead l : leads) {
            if (!String.isBlank(l.Company)) companies.add(l.Company.trim());
        }
        Map<String, Account> byName = new Map<String, Account>();
        if (companies.isEmpty()) return byName;
        Set<Id> recordTypes = allowedAccountRecordTypes(recordType);
        Map<String, Integer> counts = new Map<String, Integer>();
        Map<String, Object> binds = new Map<String, Object>{ 'companies' => companies, 'recordTypes' => recordTypes };
        for (SObject row : dml.query(
            'SELECT Id, Name FROM Account WHERE Name IN :companies' +
            (recordTypes.isEmpty() ? '' : ' AND RecordTypeId IN :recordTypes') + ' LIMIT 500',
            binds
        )) {
            Account acc = (Account) row;
            String key = acc.Name.trim().toLowerCase();
            counts.put(key, (counts.containsKey(key) ? counts.get(key) : 0) + 1);
            byName.put(key, acc);
        }
        for (String key : counts.keySet()) {
            if (counts.get(key) > 1) byName.remove(key);
        }
        return byName;
    }

    // Account record types allowed for Contact.AccountId by the field configuration of this record type.
    public static Set<Id> allowedAccountRecordTypes(WizardConfig.RecordTypeOption recordType) {
        Set<Id> ids = new Set<Id>();
        for (WizardConfig.FieldConfig config : WizardConfig.fields(Contact.SObjectType.getDescribe(), recordType.developerName)) {
            if (config.fieldApiName == 'AccountId') ids.addAll(config.lookupRecordTypeIds);
        }
        return ids;
    }

    @TestVisible
    private static List<String> variants(String value) {
        Set<String> result = new Set<String>{ value, value.toUpperCase(), value.toLowerCase() };
        List<String> words = new List<String>();
        for (String word : value.toLowerCase().split(' ')) {
            words.add(word.capitalize());
        }
        result.add(String.join(words, ' '));
        return new List<String>(result);
    }

    @TestVisible
    private static Boolean sameValue(String expected, Object actual) {
        if (expected == null || actual == null) return false;
        String a = expected.trim().toLowerCase();
        String b = String.valueOf(actual).trim().toLowerCase();
        if (a == b) return true;
        // Phone numbers: compare digits only ("+351 912 000 001" = "351912000001").
        String da = a.replaceAll('[^0-9]', '');
        String db = b.replaceAll('[^0-9]', '');
        return da.length() >= 6 && da == db;
    }

    private static MatchCandidate score(
        SObject record, List<WizardConfig.MatchRule> rules, Map<String, Object> inputs, Boolean isLead,
        String inputAccountName, Map<String, Schema.SObjectField> fieldMap
    ) {
        MatchCandidate candidate = new MatchCandidate();
        candidate.recordId = record.Id;
        candidate.score = 0;
        candidate.matched = new List<String>();
        candidate.notMatched = new List<String>();
        for (WizardConfig.MatchRule rule : rules) {
            String input = inputValue(inputs, rule.fieldApiName);
            if (input == null) {
                continue;
            }
            String label = WizardConfig.displayLabel(fieldMap.get(rule.fieldApiName.toLowerCase()).getDescribe());
            String expected = input;
            String fieldOnRecord = rule.fieldApiName;
            if (isLead) {
                if (rule.leadFieldApiName == null) continue;
                fieldOnRecord = rule.leadFieldApiName;
                // A Lead has no Account: its Company text is compared with the chosen Account name.
                if (rule.fieldApiName == 'AccountId') expected = inputAccountName;
            }
            if (sameValue(expected, record.get(fieldOnRecord))) {
                candidate.score += rule.weight;
                candidate.matched.add(label);
            } else {
                candidate.notMatched.add(label);
            }
        }
        candidate.score = Math.min(candidate.score, 100);
        return candidate;
    }

    private static String inputValue(Map<String, Object> inputs, String fieldApiName) {
        Object raw = inputs.get(fieldApiName.toLowerCase());
        return raw == null || String.isBlank(String.valueOf(raw)) ? null : String.valueOf(raw).trim();
    }

    private String accountName(Id accountId) {
        List<SObject> rows = dml.query('SELECT Name FROM Account WHERE Id = :accountId', new Map<String, Object>{ 'accountId' => accountId });
        return rows.isEmpty() ? null : String.valueOf(rows[0].get('Name'));
    }

    public static String joinParts(List<String> parts) {
        List<String> kept = new List<String>();
        for (String part : parts) {
            if (!String.isBlank(part)) kept.add(part);
        }
        return String.join(kept, ' · ');
    }

    private class HighestScoreFirst implements Comparator<MatchCandidate> {
        public Integer compare(MatchCandidate a, MatchCandidate b) {
            return b.score - a.score;
        }
    }
}
