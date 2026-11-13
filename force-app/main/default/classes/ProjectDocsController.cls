/**
 * Documentation features of the projectBoardApp: BRD & Solution Design (Contoso template),
 * test scripts and file attachments.
 */
public with sharing class ProjectDocsController {

    public static final String DEFAULT_BUSINESS_AREA = 'Commercial Applications';
    public static final String DEFAULT_SYSTEM = 'Salesforce.com';

    private static final Set<String> BRD_FIELDS = new Set<String>{
        'name', 'pbi_id__c', 'business_area__c', 'status__c', 'version__c', 'business_analyst__c',
        'business_requestor__c', 'impacted_users__c', 'systems_impacted__c',
        'initiator_name__c', 'initiator_date__c', 'it_approver_name__c', 'it_approver_date__c',
        'architect_approver_name__c', 'architect_approver_date__c', 'solution_designer_name__c',
        'solution_designer_date__c', 'solution_reviewer_name__c', 'solution_reviewer_date__c'
    };

    private static final Set<String> REQUIREMENT_FIELDS = new Set<String>{
        'requirement__c', 'acceptance_criteria__c', 'systems_impacted__c', 'additional_info__c',
        'solution__c', 'solution_systems__c'
    };

    private static final Set<String> TEST_CASE_FIELDS = new Set<String>{
        'title__c', 'requirement__c', 'preconditions__c', 'test_data__c', 'steps__c', 'status__c', 'comments__c'
    };

    private static final String BRD_SELECT =
        'SELECT Id, Name, Issue__c, Issue__r.Name, Issue__r.Summary__c, PBI_ID__c, Business_Area__c, Status__c, Version__c, ' +
        'Business_Analyst__c, Business_Requestor__c, Impacted_Users__c, Systems_Impacted__c, ' +
        'Initiator_Name__c, Initiator_Date__c, IT_Approver_Name__c, IT_Approver_Date__c, ' +
        'Architect_Approver_Name__c, Architect_Approver_Date__c, Solution_Designer_Name__c, Solution_Designer_Date__c, ' +
        'Solution_Reviewer_Name__c, Solution_Reviewer_Date__c, LastModifiedDate, ' +
        '(SELECT Id, Name, Sequence__c, Requirement__c, Acceptance_Criteria__c, Systems_Impacted__c, ' +
        'Additional_Info__c, Solution__c, Solution_Systems__c FROM Requirements__r ORDER BY Sequence__c) ' +
        'FROM PM_BRD__c';

    private static final String TEST_CASE_SELECT =
        'SELECT Id, Name, Issue__c, Sequence__c, Title__c, Requirement__c, Requirement__r.Name, Preconditions__c, ' +
        'Test_Data__c, Steps__c, Status__c, Tested_By__c, Tested_By__r.Name, Tested_Date__c, Comments__c ' +
        'FROM PM_Test_Case__c';

    public class DocsException extends Exception {}

    public class FileInfo {
        @AuraEnabled public Id documentId;
        @AuraEnabled public Id versionId;
        @AuraEnabled public String title;
        @AuraEnabled public String extension;
        @AuraEnabled public Integer size;
        @AuraEnabled public String createdBy;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Boolean canDelete;
    }

    // ---------------------------------------------------------------- BRD

    @AuraEnabled
    public static PM_BRD__c getBrd(Id issueId) {
        try {
            List<PM_BRD__c> brds = Database.query(BRD_SELECT + ' WHERE Issue__c = :issueId WITH USER_MODE LIMIT 1');
            return brds.isEmpty() ? null : brds[0];
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /**
     * Creates the BRD from the Contoso template, pre-filled from the issue
     * (PBI = issue key, first requirement = issue description).
     */
    @AuraEnabled
    public static PM_BRD__c createBrd(Id issueId) {
        try {
            if (![SELECT Id FROM PM_BRD__c WHERE Issue__c = :issueId WITH USER_MODE LIMIT 1].isEmpty()) {
                throw new DocsException('This issue already has a BRD.');
            }
            PM_Issue__c issue = [
                SELECT Id, Name, Summary__c, Description__c, Reporter__r.Name
                FROM PM_Issue__c
                WHERE Id = :issueId
                WITH USER_MODE
            ];
            PM_BRD__c brd = new PM_BRD__c(
                Name = issue.Summary__c.left(80),
                Issue__c = issue.Id,
                PBI_ID__c = issue.Name,
                Business_Area__c = DEFAULT_BUSINESS_AREA,
                Status__c = 'Draft',
                Version__c = '1.0',
                Business_Requestor__c = issue.Reporter__r == null ? null : issue.Reporter__r.Name,
                Impacted_Users__c = 'Salesforce users',
                Systems_Impacted__c = DEFAULT_SYSTEM,
                Solution_Designer_Name__c = UserInfo.getName(),
                Solution_Designer_Date__c = Date.today()
            );
            insert as user brd;
            insert as user new PM_Requirement__c(
                BRD__c = brd.Id,
                Name = 'BRD0001',
                Sequence__c = 1,
                Requirement__c = htmlToLines(issue.Description__c),
                Systems_Impacted__c = DEFAULT_SYSTEM,
                Solution_Systems__c = DEFAULT_SYSTEM
            );
            return getBrd(issueId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void saveBrd(Map<String, Object> fields) {
        try {
            PM_BRD__c brd = (PM_BRD__c) applyFields(new PM_BRD__c(), fields, BRD_FIELDS);
            brd.Id = Id.valueOf(String.valueOf(fields.get('Id')));
            if (fields.containsKey('Name') && String.isBlank(brd.Name)) {
                throw new DocsException('Document name is required.');
            }
            update as user brd;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void deleteBrd(Id brdId) {
        try {
            delete as user new PM_BRD__c(Id = brdId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static PM_Requirement__c addRequirement(Id brdId) {
        try {
            AggregateResult[] agg = [SELECT MAX(Sequence__c) maxSeq FROM PM_Requirement__c WHERE BRD__c = :brdId];
            Decimal maxSeq = (Decimal) agg[0].get('maxSeq');
            Integer seq = (maxSeq == null ? 0 : maxSeq.intValue()) + 1;
            PM_Requirement__c req = new PM_Requirement__c(
                BRD__c = brdId,
                Name = 'BRD' + String.valueOf(seq).leftPad(4, '0'),
                Sequence__c = seq,
                Systems_Impacted__c = DEFAULT_SYSTEM,
                Solution_Systems__c = DEFAULT_SYSTEM
            );
            insert as user req;
            return req;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void saveRequirement(Map<String, Object> fields) {
        try {
            PM_Requirement__c req = (PM_Requirement__c) applyFields(
                new PM_Requirement__c(), fields, REQUIREMENT_FIELDS
            );
            req.Id = Id.valueOf(String.valueOf(fields.get('Id')));
            update as user req;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void deleteRequirement(Id requirementId) {
        try {
            delete as user new PM_Requirement__c(Id = requirementId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    // ---------------------------------------------------------------- Test scripts

    @AuraEnabled
    public static List<PM_Test_Case__c> getTestCases(Id issueId) {
        try {
            return Database.query(TEST_CASE_SELECT + ' WHERE Issue__c = :issueId WITH USER_MODE ORDER BY Sequence__c');
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static PM_Test_Case__c saveTestCase(Map<String, Object> fields) {
        try {
            PM_Test_Case__c tc = (PM_Test_Case__c) applyFields(
                new PM_Test_Case__c(), fields, TEST_CASE_FIELDS
            );
            String recordId = fields.get('Id') == null ? null : String.valueOf(fields.get('Id'));
            if (fields.containsKey('Status__c')) {
                Boolean executed = tc.Status__c != null && tc.Status__c != 'Not Run';
                tc.Tested_By__c = executed ? UserInfo.getUserId() : null;
                tc.Tested_Date__c = executed ? Date.today() : null;
            }
            if (String.isNotBlank(recordId)) {
                tc.Id = Id.valueOf(recordId);
                update as user tc;
            } else {
                Id issueId = Id.valueOf(String.valueOf(fields.get('Issue__c')));
                insertTestCases(issueId, new List<PM_Test_Case__c>{ tc });
            }
            Id tcId = tc.Id;
            return Database.query(TEST_CASE_SELECT + ' WHERE Id = :tcId WITH USER_MODE');
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void deleteTestCase(Id testCaseId) {
        try {
            delete as user new PM_Test_Case__c(Id = testCaseId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /**
     * Automation: creates one test case per acceptance criterion of the issue's BRD
     * (criteria already covered by a test case with the same title are skipped).
     */
    @AuraEnabled
    public static Integer generateTestCasesFromBrd(Id issueId) {
        try {
            PM_BRD__c brd = getBrd(issueId);
            if (brd == null) {
                throw new DocsException('Create the BRD first - test cases are generated from its acceptance criteria.');
            }
            Set<String> existing = new Set<String>();
            for (PM_Test_Case__c tc : [SELECT Title__c FROM PM_Test_Case__c WHERE Issue__c = :issueId WITH USER_MODE]) {
                existing.add(tc.Title__c == null ? '' : tc.Title__c.toLowerCase());
            }
            List<PM_Test_Case__c> toCreate = new List<PM_Test_Case__c>();
            for (PM_Requirement__c req : brd.Requirements__r) {
                for (String criterion : splitLines(req.Acceptance_Criteria__c)) {
                    String title = criterion.left(255);
                    if (existing.contains(title.toLowerCase())) {
                        continue;
                    }
                    existing.add(title.toLowerCase());
                    toCreate.add(new PM_Test_Case__c(
                        Title__c = title,
                        Requirement__c = req.Id,
                        Status__c = 'Not Run',
                        Steps__c = JSON.serialize(new List<Map<String, String>>{
                            new Map<String, String>{ 'action' => '', 'expected' => criterion, 'actual' => '' }
                        })
                    ));
                }
            }
            if (toCreate.isEmpty()) {
                throw new DocsException('No new acceptance criteria to generate test cases from.');
            }
            insertTestCases(issueId, toCreate);
            return toCreate.size();
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    // ---------------------------------------------------------------- Files

    @AuraEnabled
    public static List<FileInfo> getFiles(Id recordId) {
        try {
            List<FileInfo> files = new List<FileInfo>();
            Id me = UserInfo.getUserId();
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension,
                    ContentDocument.ContentSize, ContentDocument.LatestPublishedVersionId,
                    ContentDocument.CreatedBy.Name, ContentDocument.CreatedById, ContentDocument.CreatedDate
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :recordId
                ORDER BY ContentDocument.CreatedDate DESC
            ]) {
                FileInfo f = new FileInfo();
                f.documentId = link.ContentDocumentId;
                f.versionId = link.ContentDocument.LatestPublishedVersionId;
                f.title = link.ContentDocument.Title;
                f.extension = link.ContentDocument.FileExtension;
                f.size = link.ContentDocument.ContentSize;
                f.createdBy = link.ContentDocument.CreatedBy.Name;
                f.createdDate = link.ContentDocument.CreatedDate;
                f.canDelete = link.ContentDocument.CreatedById == me;
                files.add(f);
            }
            return files;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void deleteFile(Id documentId) {
        try {
            ContentDocument doc = [SELECT Id, CreatedById FROM ContentDocument WHERE Id = :documentId];
            if (doc.CreatedById != UserInfo.getUserId()) {
                throw new DocsException('You can only delete files you uploaded.');
            }
            delete as user doc;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    // ---------------------------------------------------------------- Helpers

    private static void insertTestCases(Id issueId, List<PM_Test_Case__c> testCases) {
        AggregateResult[] agg = [SELECT MAX(Sequence__c) maxSeq FROM PM_Test_Case__c WHERE Issue__c = :issueId];
        Decimal maxSeq = (Decimal) agg[0].get('maxSeq');
        Integer seq = maxSeq == null ? 0 : maxSeq.intValue();
        for (PM_Test_Case__c tc : testCases) {
            seq++;
            tc.Issue__c = issueId;
            tc.Sequence__c = seq;
            tc.Name = 'TC-' + String.valueOf(seq).leftPad(3, '0');
            if (String.isBlank(tc.Title__c)) {
                tc.Title__c = 'New test case';
            }
            if (tc.Status__c == null) {
                tc.Status__c = 'Not Run';
            }
        }
        insert as user testCases;
    }

    private static SObject applyFields(SObject record, Map<String, Object> fields, Set<String> allowed) {
        Map<String, Schema.SObjectField> fieldMap = record.getSObjectType().getDescribe().fields.getMap();
        for (String key : fields.keySet()) {
            if (!allowed.contains(key.toLowerCase())) {
                continue;
            }
            Schema.SObjectField f = fieldMap.get(key);
            Object value = fields.get(key);
            String s = value == null ? null : String.valueOf(value);
            if (String.isBlank(s)) {
                record.put(f, null);
                continue;
            }
            Schema.DisplayType t = f.getDescribe().getType();
            if (t == Schema.DisplayType.DATE) {
                record.put(f, Date.valueOf(s.left(10)));
            } else if (t == Schema.DisplayType.REFERENCE) {
                record.put(f, Id.valueOf(s));
            } else {
                record.put(f, s);
            }
        }
        return record;
    }

    /** Splits a multi-line text into trimmed, non-empty lines (bullets are stripped). */
    public static List<String> splitLines(String text) {
        List<String> lines = new List<String>();
        if (String.isBlank(text)) {
            return lines;
        }
        for (String line : text.split('\n')) {
            String clean = line.trim().removeStart('•').removeStart('-').removeStart('*').trim();
            if (String.isNotBlank(clean)) {
                lines.add(clean);
            }
        }
        return lines;
    }

    /** Converts simple rich text (paragraphs / list items) to one line per block. */
    public static String htmlToLines(String html) {
        if (String.isBlank(html)) {
            return null;
        }
        String text = html.replaceAll('(?i)<br\\s*/?>', '\n').replaceAll('(?i)</(p|li|div|h[1-6])>', '\n');
        text = text.replaceAll('<[^>]*>', '');
        List<String> lines = splitLines(text.unescapeHtml4());
        return lines.isEmpty() ? null : String.join(lines, '\n');
    }

    private static AuraHandledException auraError(Exception e) {
        String message = e instanceof DmlException ? ((DmlException) e).getDmlMessage(0) : e.getMessage();
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
