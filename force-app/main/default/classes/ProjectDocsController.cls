/**
 * Documentation features of the projectBoardApp: BRD & Solution Design (BRD template),
 * test scripts and file attachments.
 *
 * Sign-off: each role of the template (PM_Sign_Off__c) names a real user. "Request sign-off" locks the BRD
 * and notifies the approvers; each approver approves or rejects with their own login, so the name and the date
 * are recorded by the system, never typed. All approved -> Approved; any rejection -> Changes Requested.
 * "Reopen" unlocks the document (a new minor version when it was approved).
 * Gotchas: content can only change while the BRD is Draft or Changes Requested. Approvers may be Viewers, so their
 * decision is written through ProjectBoardSharing after the checks below.
 */
public with sharing class ProjectDocsController {

    public static final String DEFAULT_BUSINESS_AREA = 'Commercial Applications';
    public static final String DEFAULT_SYSTEM = 'Salesforce.com';

    private static final Set<String> BRD_FIELDS = new Set<String>{
        'name', 'pbi_id__c', 'business_area__c', 'business_analyst__c', 'business_requestor__c',
        'impacted_users__c', 'systems_impacted__c'
    };

    public static final String BRD_DRAFT = 'Draft';
    public static final String BRD_SENT = 'Sent for Approval';
    public static final String BRD_APPROVED = 'Approved';
    public static final String BRD_CHANGES = 'Changes Requested';
    public static final String SIGN_PENDING = 'Pending';
    public static final String SIGN_APPROVED = 'Approved';
    public static final String SIGN_REJECTED = 'Rejected';
    public static final String SIGN_NOT_REQUIRED = 'Not Required';
    /** Roles of the template, in document order: role => section. */
    public static final List<List<String>> SIGN_OFF_ROLES = new List<List<String>>{
        new List<String>{ 'Business Change Initiator', 'BRD' },
        new List<String>{ 'IT Delivery BRD Approver', 'BRD' },
        new List<String>{ 'IT Architect Approver', 'BRD' },
        new List<String>{ 'Solution Designer', 'Solution Design' },
        new List<String>{ 'Solution Reviewer', 'Solution Design' }
    };
    private static final String NOTIFICATION_TYPE = 'Project_Board_Sign_Off';
    private static final String APP_TAB = 'Project_Board';

    private static final Set<String> REQUIREMENT_FIELDS = new Set<String>{
        'requirement__c', 'acceptance_criteria__c', 'systems_impacted__c', 'additional_info__c',
        'solution__c', 'solution_systems__c'
    };

    private static final Set<String> TEST_CASE_FIELDS = new Set<String>{
        'title__c', 'requirement__c', 'preconditions__c', 'test_data__c', 'steps__c', 'status__c', 'comments__c'
    };

    private static final String BRD_SELECT =
        'SELECT Id, Name, OwnerId, Issue__c, Issue__r.Name, Issue__r.Summary__c, Issue__r.Project__c, PBI_ID__c, ' +
        'Business_Area__c, Status__c, Version__c, Business_Analyst__c, Business_Requestor__c, Impacted_Users__c, ' +
        'Systems_Impacted__c, LastModifiedDate, ' +
        '(SELECT Id, Name, Sequence__c, Requirement__c, Acceptance_Criteria__c, Systems_Impacted__c, ' +
        'Additional_Info__c, Solution__c, Solution_Systems__c FROM Requirements__r ORDER BY Sequence__c), ' +
        '(SELECT Id, Role__c, Section__c, Sequence__c, Approver__c, Approver__r.Name, Status__c, Decision_Date__c, ' +
        'Comments__c FROM Sign_Offs__r ORDER BY Sequence__c) ' +
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

    /** What the BRD editor needs besides the record: locking and the actions open to the current user. */
    public class BrdView {
        @AuraEnabled public PM_BRD__c brd;
        @AuraEnabled public Boolean locked;
        @AuraEnabled public Boolean canEdit;
        @AuraEnabled public Boolean canRequest;
        @AuraEnabled public Boolean canReopen;
        @AuraEnabled public Id currentUserId;
        @AuraEnabled public List<Id> memberUserIds;
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
     * Creates the BRD from the BRD template, pre-filled from the issue
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
                Systems_Impacted__c = DEFAULT_SYSTEM
            );
            insert as user brd;
            List<PM_Sign_Off__c> signOffs = new List<PM_Sign_Off__c>();
            Integer seq = 0;
            for (List<String> role : SIGN_OFF_ROLES) {
                signOffs.add(new PM_Sign_Off__c(
                    BRD__c = brd.Id,
                    Role__c = role[0],
                    Section__c = role[1],
                    Sequence__c = ++seq,
                    Status__c = SIGN_PENDING,
                    // The author designs the solution by default; the other approvers are chosen in the editor
                    Approver__c = role[0] == 'Solution Designer' ? UserInfo.getUserId() : null
                ));
            }
            insert as user signOffs;
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
            assertEditable(brd.Id);
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
            // BRDs belong to their author; any member who can edit the issue may remove it.
            PM_BRD__c brd = [SELECT Id, Issue__c FROM PM_BRD__c WHERE Id = :brdId WITH USER_MODE];
            UserRecordAccess ura = [
                SELECT RecordId, HasEditAccess FROM UserRecordAccess
                WHERE UserId = :UserInfo.getUserId() AND RecordId = :brd.Issue__c
            ];
            if (!ura.HasEditAccess) {
                throw new DocsException('You need edit access to the project to delete its BRD.');
            }
            ProjectBoardSharing.deleteAsSystem(new List<SObject>{ brd });
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static PM_Requirement__c addRequirement(Id brdId) {
        try {
            assertEditable(brdId);
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
            assertEditable([SELECT BRD__c FROM PM_Requirement__c WHERE Id = :req.Id WITH USER_MODE].BRD__c);
            update as user req;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void deleteRequirement(Id requirementId) {
        try {
            assertEditable([SELECT BRD__c FROM PM_Requirement__c WHERE Id = :requirementId WITH USER_MODE].BRD__c);
            delete as user new PM_Requirement__c(Id = requirementId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    // ---------------------------------------------------------------- Sign-off

    @AuraEnabled
    public static BrdView getBrdView(Id issueId) {
        try {
            BrdView view = new BrdView();
            view.brd = getBrd(issueId);
            view.currentUserId = UserInfo.getUserId();
            view.memberUserIds = new List<Id>();
            if (view.brd == null) {
                return view;
            }
            for (PM_Project_Member__c m : [
                SELECT User__c FROM PM_Project_Member__c WHERE Project__c = :view.brd.Issue__r.Project__c WITH USER_MODE
            ]) {
                view.memberUserIds.add(m.User__c);
            }
            Boolean hasEdit = [
                SELECT RecordId, HasEditAccess FROM UserRecordAccess
                WHERE UserId = :UserInfo.getUserId() AND RecordId = :view.brd.Id
            ].HasEditAccess;
            view.locked = !isOpen(view.brd.Status__c);
            view.canEdit = hasEdit && !view.locked;
            view.canRequest = view.canEdit;
            view.canReopen = hasEdit && view.locked;
            return view;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Names the approver of a role, or marks the role as not required (while the BRD is open). */
    @AuraEnabled
    public static void assignSignOff(Id signOffId, Id approverId, Boolean notRequired) {
        try {
            PM_Sign_Off__c so = [
                SELECT Id, BRD__c, BRD__r.Issue__r.Project__c FROM PM_Sign_Off__c WHERE Id = :signOffId WITH USER_MODE
            ];
            assertEditable(so.BRD__c);
            if (notRequired != true && approverId != null) {
                Integer members = [
                    SELECT COUNT() FROM PM_Project_Member__c
                    WHERE Project__c = :so.BRD__r.Issue__r.Project__c AND User__c = :approverId
                    WITH USER_MODE
                ];
                if (members == 0) {
                    throw new DocsException('The approver must be a member of the project.');
                }
            }
            update as user new PM_Sign_Off__c(
                Id = so.Id,
                Approver__c = notRequired == true ? null : approverId,
                Status__c = notRequired == true ? SIGN_NOT_REQUIRED : SIGN_PENDING,
                Decision_Date__c = null,
                Comments__c = null
            );
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Locks the BRD and asks every named approver to decide. */
    @AuraEnabled
    public static void requestSignOff(Id brdId) {
        try {
            assertEditable(brdId);
            PM_BRD__c brd = [SELECT Id, Name, PBI_ID__c FROM PM_BRD__c WHERE Id = :brdId WITH USER_MODE];
            List<PM_Sign_Off__c> rows = [
                SELECT Id, Role__c, Approver__c, Status__c FROM PM_Sign_Off__c WHERE BRD__c = :brdId WITH USER_MODE
            ];
            Set<String> approvers = new Set<String>();
            for (PM_Sign_Off__c row : rows) {
                if (row.Status__c == SIGN_NOT_REQUIRED) {
                    continue;
                }
                if (row.Approver__c == null) {
                    throw new DocsException('Choose an approver for "' + row.Role__c + '" or mark it as not required.');
                }
                row.Status__c = SIGN_PENDING;
                row.Decision_Date__c = null;
                row.Comments__c = null;
                approvers.add(row.Approver__c);
            }
            if (approvers.isEmpty()) {
                throw new DocsException('At least one approver is needed to request sign-off.');
            }
            update as user rows;
            update as user new PM_BRD__c(Id = brdId, Status__c = BRD_SENT);
            notify(approvers, brdId, 'Sign-off requested: ' + label(brd),
                UserInfo.getName() + ' asks for your sign-off. Open the issue in the project board to approve or reject.');
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** The named approver approves or rejects (a comment is required to reject). */
    @AuraEnabled
    public static void decideSignOff(Id signOffId, String decision, String comments) {
        try {
            PM_Sign_Off__c so = [
                SELECT Id, BRD__c, Approver__c, Status__c, Role__c FROM PM_Sign_Off__c WHERE Id = :signOffId WITH USER_MODE
            ];
            PM_BRD__c brd = [SELECT Id, Name, PBI_ID__c, Status__c, OwnerId FROM PM_BRD__c WHERE Id = :so.BRD__c WITH USER_MODE];
            if (so.Approver__c != UserInfo.getUserId()) {
                throw new DocsException('Only the named approver can sign off this role.');
            }
            if (brd.Status__c != BRD_SENT || so.Status__c != SIGN_PENDING) {
                throw new DocsException('This sign-off is not waiting for a decision.');
            }
            if (decision != SIGN_APPROVED && decision != SIGN_REJECTED) {
                throw new DocsException('The decision must be Approved or Rejected.');
            }
            if (decision == SIGN_REJECTED && String.isBlank(comments)) {
                throw new DocsException('Explain what needs to change when you reject.');
            }
            ProjectBoardSharing.updateAsSystem(new List<SObject>{ new PM_Sign_Off__c(
                Id = so.Id, Status__c = decision, Decision_Date__c = System.now(), Comments__c = comments
            ) });

            String outcome;
            if (decision == SIGN_REJECTED) {
                outcome = BRD_CHANGES;
            } else {
                Integer open = [
                    SELECT COUNT() FROM PM_Sign_Off__c
                    WHERE BRD__c = :brd.Id AND Status__c NOT IN (:SIGN_APPROVED, :SIGN_NOT_REQUIRED)
                ];
                outcome = open == 0 ? BRD_APPROVED : null;
            }
            if (outcome != null) {
                ProjectBoardSharing.updateAsSystem(new List<SObject>{ new PM_BRD__c(Id = brd.Id, Status__c = outcome) });
            }
            String title = (decision == SIGN_APPROVED ? 'Approved' : 'Changes requested') + ' by ' + UserInfo.getName() + ': ' + label(brd);
            String body = so.Role__c + (String.isBlank(comments) ? '.' : ' - ' + comments);
            if (outcome == BRD_APPROVED) {
                body += ' All sign-offs are complete: the BRD is approved.';
            }
            notify(new Set<String>{ brd.OwnerId }, brd.Id, title, body);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Unlocks a BRD that was sent, approved or sent back; an approved BRD gets a new minor version. */
    @AuraEnabled
    public static void reopenBrd(Id brdId) {
        try {
            PM_BRD__c brd = [SELECT Id, Status__c, Version__c FROM PM_BRD__c WHERE Id = :brdId WITH USER_MODE];
            if (isOpen(brd.Status__c)) {
                throw new DocsException('This BRD is already open for changes.');
            }
            List<PM_Sign_Off__c> rows = [
                SELECT Id, Status__c FROM PM_Sign_Off__c WHERE BRD__c = :brdId AND Status__c != :SIGN_NOT_REQUIRED WITH USER_MODE
            ];
            for (PM_Sign_Off__c row : rows) {
                row.Status__c = SIGN_PENDING;
                row.Decision_Date__c = null;
                row.Comments__c = null;
            }
            update as user rows;
            PM_BRD__c changes = new PM_BRD__c(Id = brdId, Status__c = BRD_DRAFT);
            if (brd.Status__c == BRD_APPROVED) {
                changes.Version__c = nextVersion(brd.Version__c);
            }
            update as user changes;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public static String nextVersion(String version) {
        List<String> parts = String.isBlank(version) ? new List<String>() : version.split('\\.');
        Integer major = parts.size() > 0 && parts[0].isNumeric() ? Integer.valueOf(parts[0]) : 1;
        Integer minor = parts.size() > 1 && parts[1].isNumeric() ? Integer.valueOf(parts[1]) : 0;
        return major + '.' + (minor + 1);
    }

    private static Boolean isOpen(String status) {
        return status == null || status == BRD_DRAFT || status == BRD_CHANGES;
    }

    private static void assertEditable(Id brdId) {
        PM_BRD__c brd = [SELECT Status__c FROM PM_BRD__c WHERE Id = :brdId WITH USER_MODE];
        if (!isOpen(brd.Status__c)) {
            throw new DocsException('This BRD is locked while it is ' + brd.Status__c.toLowerCase() + '. Reopen it to make changes.');
        }
    }

    private static String label(PM_BRD__c brd) {
        return (String.isBlank(brd.PBI_ID__c) ? '' : brd.PBI_ID__c + ' ') + brd.Name;
    }

    /** Bell notification that opens the project board app. Never blocks the business action. */
    private static void notify(Set<String> userIds, Id targetId, String title, String body) {
        userIds.remove(null);
        if (userIds.isEmpty()) {
            return;
        }
        try {
            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIFICATION_TYPE LIMIT 1
            ];
            if (types.isEmpty()) {
                return;
            }
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(types[0].Id);
            n.setTitle(title.left(250));
            n.setBody(body.left(750));
            n.setTargetPageRef('{"type":"standard__navItemPage","attributes":{"apiName":"' + APP_TAB + '"}}');
            n.send(userIds);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Sign-off notification not sent: ' + e.getMessage());
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
