/**
 * Controller for the Scrum-style project management app (projectBoardApp LWC).
 * Data model: PM_Project__c -> PM_Sprint__c / PM_Issue__c -> PM_Comment__c
 */
public with sharing class ProjectBoardController {

    private static final String STATUS_TODO = 'To Do';
    private static final String STATUS_DONE = 'Done';
    private static final String SPRINT_PLANNED = 'Planned';
    private static final String SPRINT_ACTIVE = 'Active';
    private static final String SPRINT_COMPLETED = 'Completed';

    private static final Set<String> EDITABLE_FIELDS = new Set<String>{
        'summary__c', 'description__c', 'type__c', 'status__c', 'priority__c', 'assignee__c',
        'story_points__c', 'sprint__c', 'epic__c', 'due_date__c', 'labels__c'
    };

    private static final Set<String> REFERENCE_FIELDS = new Set<String>{ 'Assignee__c', 'Sprint__c', 'Epic__c' };

    private static final String ISSUE_FIELDS =
        'Id, Name, Project__c, Summary__c, Description__c, Type__c, Status__c, Priority__c, Story_Points__c, ' +
        'Rank__c, Sprint__c, Sprint__r.Name, Sprint__r.Status__c, Epic__c, Epic__r.Name, Epic__r.Summary__c, ' +
        'Assignee__c, Assignee__r.Name, Reporter__c, Reporter__r.Name, Due_Date__c, Labels__c, ' +
        'Resolved_Date__c, CreatedDate, LastModifiedDate';

    public class ProjectBoardException extends Exception {}

    public class BoardData {
        @AuraEnabled public PM_Project__c project;
        @AuraEnabled public List<PM_Sprint__c> sprints;
        @AuraEnabled public List<PM_Issue__c> issues;
        @AuraEnabled public Id currentUserId;
        @AuraEnabled public String currentUserName;
        @AuraEnabled public Map<Id, IssueStats> stats;
    }

    /** Per-issue counters shown as badges on board cards. */
    public class IssueStats {
        @AuraEnabled public Integer attachments = 0;
        @AuraEnabled public Integer tests = 0;
        @AuraEnabled public Integer testsPassed = 0;
        @AuraEnabled public Integer testsFailed = 0;
        @AuraEnabled public Boolean hasBrd = false;
    }

    public class IssueDetail {
        @AuraEnabled public List<PM_Comment__c> comments = new List<PM_Comment__c>();
        @AuraEnabled public List<HistoryEntry> history = new List<HistoryEntry>();
    }

    public class HistoryEntry {
        @AuraEnabled public String id;
        @AuraEnabled public String field;
        @AuraEnabled public String oldValue;
        @AuraEnabled public String newValue;
        @AuraEnabled public String userName;
        @AuraEnabled public Datetime createdDate;
    }

    // ---------------------------------------------------------------- Projects

    @AuraEnabled
    public static List<PM_Project__c> getProjects() {
        try {
            return [
                SELECT Id, Name, Key__c, Description__c, Lead__c, Lead__r.Name, CreatedDate
                FROM PM_Project__c
                WITH USER_MODE
                ORDER BY Name
                LIMIT 500
            ];
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static PM_Project__c createProject(String name, String projectKey, String description) {
        try {
            String key = String.isBlank(projectKey) ? '' : projectKey.trim().toUpperCase();
            if (String.isBlank(name)) {
                throw new ProjectBoardException('Project name is required.');
            }
            if (!Pattern.matches('[A-Z][A-Z0-9]{1,9}', key)) {
                throw new ProjectBoardException('Project key must have 2-10 letters/digits and start with a letter.');
            }
            if (![SELECT Id FROM PM_Project__c WHERE Key__c = :key LIMIT 1].isEmpty()) {
                throw new ProjectBoardException('A project with key ' + key + ' already exists.');
            }
            PM_Project__c project = new PM_Project__c(
                Name = name.trim(),
                Key__c = key,
                Description__c = description,
                Lead__c = UserInfo.getUserId(),
                Issue_Counter__c = 0
            );
            insert as user project;
            insert as user new PM_Sprint__c(
                Name = key + ' Sprint 1',
                Project__c = project.Id,
                Status__c = SPRINT_PLANNED,
                Sequence__c = 1
            );
            return project;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static BoardData getBoardData(Id projectId) {
        try {
            BoardData data = new BoardData();
            data.currentUserId = UserInfo.getUserId();
            data.currentUserName = UserInfo.getName();
            data.project = [
                SELECT Id, Name, Key__c, Description__c, Lead__c, Lead__r.Name
                FROM PM_Project__c
                WHERE Id = :projectId
                WITH USER_MODE
            ];
            data.sprints = [
                SELECT Id, Name, Status__c, Start_Date__c, End_Date__c, Completed_Date__c, Goal__c, Sequence__c,
                    Committed_Issues__c, Committed_Points__c, Carried_Over__c
                FROM PM_Sprint__c
                WHERE Project__c = :projectId
                WITH USER_MODE
                ORDER BY Sequence__c, CreatedDate
            ];
            data.issues = Database.query(
                'SELECT ' + ISSUE_FIELDS + ' FROM PM_Issue__c WHERE Project__c = :projectId ' +
                'WITH USER_MODE ORDER BY Rank__c NULLS LAST, CreatedDate LIMIT 2000'
            );
            data.stats = buildStats(new Map<Id, PM_Issue__c>(data.issues).keySet());
            return data;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    // ---------------------------------------------------------------- Issues

    /**
     * Creates (no Id) or partially updates (Id present) an issue. Only whitelisted fields are applied.
     */
    @AuraEnabled
    public static PM_Issue__c saveIssue(Map<String, Object> fields) {
        try {
            Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.PM_Issue__c.fields.getMap();
            PM_Issue__c rec = new PM_Issue__c();
            for (String key : fields.keySet()) {
                if (EDITABLE_FIELDS.contains(key.toLowerCase())) {
                    Schema.SObjectField f = fieldMap.get(key);
                    rec.put(f, coerce(f.getDescribe().getType(), fields.get(key)));
                }
            }

            String issueId = asString(fields.get('Id'));
            if (String.isNotBlank(issueId)) {
                rec.Id = Id.valueOf(issueId);
                if (fields.containsKey('Summary__c') && String.isBlank(rec.Summary__c)) {
                    throw new ProjectBoardException('Summary is required.');
                }
                if (fields.containsKey('Epic__c') && rec.Epic__c == rec.Id) {
                    throw new ProjectBoardException('An issue cannot be its own epic.');
                }
                if (fields.containsKey('Status__c')) {
                    rec.Resolved_Date__c = rec.Status__c == STATUS_DONE ? System.now() : null;
                }
                update as user rec;
            } else {
                String projectId = asString(fields.get('Project__c'));
                insertIssue(rec, String.isBlank(projectId) ? null : Id.valueOf(projectId));
            }
            return queryIssue(rec.Id);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /**
     * Drag & drop: optionally changes status and/or sprint and sets the new rank.
     */
    @AuraEnabled
    public static void moveIssue(Id issueId, String status, Boolean changeSprint, Id sprintId, Decimal rank) {
        try {
            PM_Issue__c rec = new PM_Issue__c(Id = issueId);
            if (String.isNotBlank(status)) {
                rec.Status__c = status;
                rec.Resolved_Date__c = status == STATUS_DONE ? System.now() : null;
            }
            if (changeSprint == true) {
                rec.Sprint__c = sprintId;
            }
            if (rank != null) {
                rec.Rank__c = rank;
            }
            update as user rec;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void deleteIssue(Id issueId) {
        try {
            // BRDs are linked by lookup (Project > Issue already uses two master-detail levels)
            delete as user [SELECT Id FROM PM_BRD__c WHERE Issue__c = :issueId WITH USER_MODE];
            delete as user new PM_Issue__c(Id = issueId);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static IssueDetail getIssueDetail(Id issueId) {
        try {
            IssueDetail detail = new IssueDetail();
            detail.comments = [
                SELECT Id, Body__c, CreatedById, CreatedBy.Name, CreatedDate, LastModifiedDate
                FROM PM_Comment__c
                WHERE Issue__c = :issueId
                WITH USER_MODE
                ORDER BY CreatedDate DESC
            ];

            Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.PM_Issue__c.fields.getMap();
            for (PM_Issue__History h : [
                SELECT Id, Field, OldValue, NewValue, CreatedBy.Name, CreatedDate
                FROM PM_Issue__History
                WHERE ParentId = :issueId
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 100
            ]) {
                // Lookup changes produce two rows (Ids and names) - keep only the readable one
                if (REFERENCE_FIELDS.contains(h.Field) && (isId(h.OldValue) || isId(h.NewValue))) {
                    continue;
                }
                HistoryEntry entry = new HistoryEntry();
                entry.id = h.Id;
                entry.field = h.Field == 'created'
                    ? 'created'
                    : (fieldMap.containsKey(h.Field) ? fieldMap.get(h.Field).getDescribe().getLabel() : h.Field);
                entry.oldValue = h.OldValue == null ? null : String.valueOf(h.OldValue);
                entry.newValue = h.NewValue == null ? null : String.valueOf(h.NewValue);
                entry.userName = h.CreatedBy.Name;
                entry.createdDate = h.CreatedDate;
                detail.history.add(entry);
            }
            return detail;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static PM_Comment__c addComment(Id issueId, String body) {
        try {
            if (String.isBlank(body) || String.isBlank(body.stripHtmlTags())) {
                throw new ProjectBoardException('Comment cannot be empty.');
            }
            PM_Comment__c comment = new PM_Comment__c(Issue__c = issueId, Body__c = body);
            insert as user comment;
            return [
                SELECT Id, Body__c, CreatedById, CreatedBy.Name, CreatedDate, LastModifiedDate
                FROM PM_Comment__c
                WHERE Id = :comment.Id
                WITH USER_MODE
            ];
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void deleteComment(Id commentId) {
        try {
            PM_Comment__c comment = [SELECT Id, CreatedById FROM PM_Comment__c WHERE Id = :commentId WITH USER_MODE];
            if (comment.CreatedById != UserInfo.getUserId()) {
                throw new ProjectBoardException('You can only delete your own comments.');
            }
            delete as user comment;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    // ---------------------------------------------------------------- Sprints

    @AuraEnabled
    public static PM_Sprint__c createSprint(Id projectId) {
        try {
            PM_Project__c project = [SELECT Key__c FROM PM_Project__c WHERE Id = :projectId WITH USER_MODE];
            AggregateResult[] agg = [SELECT MAX(Sequence__c) maxSeq FROM PM_Sprint__c WHERE Project__c = :projectId];
            Decimal maxSeq = (Decimal) agg[0].get('maxSeq');
            Integer seq = (maxSeq == null ? 0 : maxSeq.intValue()) + 1;
            PM_Sprint__c sprint = new PM_Sprint__c(
                Name = project.Key__c + ' Sprint ' + seq,
                Project__c = projectId,
                Status__c = SPRINT_PLANNED,
                Sequence__c = seq
            );
            insert as user sprint;
            return sprint;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void startSprint(Id sprintId, String name, Date startDate, Date endDate, String goal) {
        try {
            PM_Sprint__c sprint = [SELECT Id, Project__c, Status__c FROM PM_Sprint__c WHERE Id = :sprintId WITH USER_MODE];
            if (sprint.Status__c != SPRINT_PLANNED) {
                throw new ProjectBoardException('Only planned sprints can be started.');
            }
            if (![SELECT Id FROM PM_Sprint__c WHERE Project__c = :sprint.Project__c AND Status__c = :SPRINT_ACTIVE LIMIT 1].isEmpty()) {
                throw new ProjectBoardException('There is already an active sprint. Complete it before starting a new one.');
            }
            if (startDate == null || endDate == null || endDate < startDate) {
                throw new ProjectBoardException('Please provide a valid start and end date.');
            }
            // Snapshot the commitment so the sprint report can compare committed vs delivered
            Decimal committedPoints = 0;
            List<PM_Issue__c> committed = [
                SELECT Story_Points__c FROM PM_Issue__c WHERE Sprint__c = :sprintId WITH USER_MODE
            ];
            for (PM_Issue__c issue : committed) {
                committedPoints += issue.Story_Points__c == null ? 0 : issue.Story_Points__c;
            }
            PM_Sprint__c changes = new PM_Sprint__c(
                Id = sprint.Id,
                Start_Date__c = startDate,
                End_Date__c = endDate,
                Goal__c = goal,
                Status__c = SPRINT_ACTIVE,
                Committed_Issues__c = committed.size(),
                Committed_Points__c = committedPoints
            );
            if (String.isNotBlank(name)) {
                changes.Name = name.trim();
            }
            update as user changes;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /**
     * Completes the sprint; open (not Done) issues move to moveToSprintId, or to the backlog when null.
     */
    @AuraEnabled
    public static Integer completeSprint(Id sprintId, Id moveToSprintId) {
        try {
            PM_Sprint__c sprint = [SELECT Id, Status__c FROM PM_Sprint__c WHERE Id = :sprintId WITH USER_MODE];
            if (sprint.Status__c != SPRINT_ACTIVE) {
                throw new ProjectBoardException('Only the active sprint can be completed.');
            }
            List<PM_Issue__c> openIssues = [
                SELECT Id, Name, Summary__c, Type__c, Status__c, Story_Points__c, Assignee__r.Name
                FROM PM_Issue__c
                WHERE Sprint__c = :sprintId AND Status__c != :STATUS_DONE
                WITH USER_MODE
            ];
            // Keep a record of what was carried over - the issues themselves leave the sprint
            List<Map<String, Object>> carried = new List<Map<String, Object>>();
            for (PM_Issue__c issue : openIssues) {
                carried.add(new Map<String, Object>{
                    'key' => issue.Name,
                    'summary' => issue.Summary__c,
                    'type' => issue.Type__c,
                    'status' => issue.Status__c,
                    'points' => issue.Story_Points__c,
                    'assignee' => issue.Assignee__r == null ? null : issue.Assignee__r.Name
                });
                issue.Sprint__c = moveToSprintId;
            }
            update as user openIssues;

            update as user new PM_Sprint__c(
                Id = sprint.Id,
                Status__c = SPRINT_COMPLETED,
                Completed_Date__c = Date.today(),
                Carried_Over__c = JSON.serialize(carried)
            );
            return openIssues.size();
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void deleteSprint(Id sprintId) {
        try {
            PM_Sprint__c sprint = [SELECT Id, Status__c FROM PM_Sprint__c WHERE Id = :sprintId WITH USER_MODE];
            if (sprint.Status__c != SPRINT_PLANNED) {
                throw new ProjectBoardException('Only planned sprints can be deleted.');
            }
            List<PM_Issue__c> issues = [SELECT Id FROM PM_Issue__c WHERE Sprint__c = :sprintId WITH USER_MODE];
            for (PM_Issue__c issue : issues) {
                issue.Sprint__c = null;
            }
            update as user issues;
            delete as user sprint;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    // ---------------------------------------------------------------- Helpers

    public static Map<Id, IssueStats> buildStats(Set<Id> issueIds) {
        Map<Id, IssueStats> stats = new Map<Id, IssueStats>();
        if (issueIds.isEmpty()) {
            return stats;
        }
        for (Id issueId : issueIds) {
            stats.put(issueId, new IssueStats());
        }
        for (ContentDocumentLink link : [
            SELECT LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId IN :issueIds
        ]) {
            stats.get(link.LinkedEntityId).attachments++;
        }
        for (PM_Test_Case__c tc : [
            SELECT Issue__c, Status__c FROM PM_Test_Case__c WHERE Issue__c IN :issueIds WITH USER_MODE
        ]) {
            IssueStats s = stats.get(tc.Issue__c);
            s.tests++;
            if (tc.Status__c == 'Pass') {
                s.testsPassed++;
            } else if (tc.Status__c == 'Fail') {
                s.testsFailed++;
            }
        }
        for (PM_BRD__c brd : [SELECT Issue__c FROM PM_BRD__c WHERE Issue__c IN :issueIds WITH USER_MODE]) {
            stats.get(brd.Issue__c).hasBrd = true;
        }
        return stats;
    }

    private static void insertIssue(PM_Issue__c rec, Id projectId) {
        if (projectId == null) {
            throw new ProjectBoardException('Project is required.');
        }
        if (String.isBlank(rec.Summary__c)) {
            throw new ProjectBoardException('Summary is required.');
        }
        // Lock the project row so concurrent creations get unique sequential keys
        PM_Project__c project = [SELECT Id, Key__c, Issue_Counter__c FROM PM_Project__c WHERE Id = :projectId FOR UPDATE];
        Integer next = (project.Issue_Counter__c == null ? 0 : project.Issue_Counter__c.intValue()) + 1;
        project.Issue_Counter__c = next;
        update project;

        AggregateResult[] agg = [SELECT MAX(Rank__c) maxRank FROM PM_Issue__c WHERE Project__c = :projectId];
        Decimal maxRank = (Decimal) agg[0].get('maxRank');

        rec.Project__c = projectId;
        rec.Name = project.Key__c + '-' + next;
        rec.Reporter__c = UserInfo.getUserId();
        rec.Rank__c = (maxRank == null ? 0 : maxRank.round(System.RoundingMode.FLOOR)) + 1;
        if (rec.Status__c == null) {
            rec.Status__c = STATUS_TODO;
        }
        if (rec.Type__c == null) {
            rec.Type__c = 'Task';
        }
        if (rec.Priority__c == null) {
            rec.Priority__c = 'Medium';
        }
        if (rec.Status__c == STATUS_DONE) {
            rec.Resolved_Date__c = System.now();
        }
        insert as user rec;
    }

    private static PM_Issue__c queryIssue(Id issueId) {
        return Database.query('SELECT ' + ISSUE_FIELDS + ' FROM PM_Issue__c WHERE Id = :issueId WITH USER_MODE');
    }

    private static Object coerce(Schema.DisplayType fieldType, Object value) {
        String s = asString(value);
        if (String.isBlank(s)) {
            return null;
        }
        switch on fieldType {
            when DATE {
                return Date.valueOf(s.left(10));
            }
            when DOUBLE, INTEGER, CURRENCY, PERCENT {
                return Decimal.valueOf(s);
            }
            when REFERENCE {
                return Id.valueOf(s);
            }
            when else {
                return s;
            }
        }
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static Boolean isId(Object value) {
        if (!(value instanceof String)) {
            return false;
        }
        String s = (String) value;
        if (s.length() != 15 && s.length() != 18) {
            return false;
        }
        try {
            Id.valueOf(s);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private static AuraHandledException auraError(Exception e) {
        String message = e instanceof DmlException ? ((DmlException) e).getDmlMessage(0) : e.getMessage();
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
