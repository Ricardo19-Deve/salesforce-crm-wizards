/**
 * Controller for the Scrum-style project management app (projectBoardApp LWC).
 * Data model: PM_Project__c -> PM_Sprint__c / PM_Issue__c -> PM_Comment__c,
 * PM_Project__c -> PM_Project_Member__c (who can see the project and with which role).
 *
 * Where to configure: roles are Lead (manages members), Member (edits) and Viewer (read only). Projects are Private;
 * ProjectBoardSharing turns memberships into shares. The Project_Board_Admin permission set sees every project.
 * Gotchas: all queries and DML run in user mode, so record access always comes from membership. Only the issue
 * assignee rule and the member rules are checked here; the platform enforces the rest. Assignments, status changes
 * and comments are reported to ProjectActivityController, which decides who is notified.
 */
public with sharing class ProjectBoardController {

    private static final String STATUS_TODO = 'To Do';
    private static final String STATUS_DONE = 'Done';
    private static final String SPRINT_PLANNED = 'Planned';
    private static final String SPRINT_ACTIVE = 'Active';
    private static final String SPRINT_COMPLETED = 'Completed';

    private static final Set<String> EDITABLE_FIELDS = new Set<String>{
        'summary__c', 'description__c', 'type__c', 'status__c', 'priority__c', 'assignee__c',
        'story_points__c', 'sprint__c', 'epic__c', 'due_date__c', 'labels__c', 'start_date__c', 'milestone__c'
    };

    private static final Set<String> REFERENCE_FIELDS = new Set<String>{ 'Assignee__c', 'Sprint__c', 'Epic__c' };

    private static final String ISSUE_FIELDS =
        'Id, Name, Project__c, Summary__c, Description__c, Type__c, Status__c, Priority__c, Story_Points__c, ' +
        'Rank__c, Sprint__c, Sprint__r.Name, Sprint__r.Status__c, Epic__c, Epic__r.Name, Epic__r.Summary__c, ' +
        'Assignee__c, Assignee__r.Name, Reporter__c, Reporter__r.Name, Due_Date__c, Labels__c, ' +
        'Resolved_Date__c, Start_Date__c, Milestone__c, Requested_By__c, Requested_By__r.Name, CreatedDate, LastModifiedDate';

    public class ProjectBoardException extends Exception {}

    public class BoardData {
        @AuraEnabled public PM_Project__c project;
        @AuraEnabled public List<PM_Sprint__c> sprints;
        @AuraEnabled public List<PM_Issue__c> issues;
        @AuraEnabled public Id currentUserId;
        @AuraEnabled public String currentUserName;
        @AuraEnabled public Map<Id, IssueStats> stats;
        @AuraEnabled public List<MemberInfo> members;
        @AuraEnabled public String myRole;
        @AuraEnabled public Boolean canEdit;
        @AuraEnabled public Boolean canManageMembers;
        @AuraEnabled public List<ProjectPlanController.DependencyInfo> dependencies;
    }

    public class MemberInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public Id userId;
        @AuraEnabled public String name;
        @AuraEnabled public String role;
        @AuraEnabled public Boolean isOwner;
        @AuraEnabled public Boolean hasPermission;
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
            // Keys are unique across all projects, including the ones this user cannot see
            if (ProjectBoardSharing.projectKeyExists(key)) {
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
            insert as user new PM_Project_Member__c(
                Project__c = project.Id,
                User__c = UserInfo.getUserId(),
                Role__c = ProjectBoardSharing.ROLE_LEAD
            );
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
                SELECT Id, Name, Key__c, Description__c, Lead__c, Lead__r.Name, Accepts_Requests__c
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
            data.members = members(projectId);
            data.dependencies = ProjectPlanController.forProject(projectId);
            ProjectAccess access = accessFor(projectId);
            data.myRole = access.role;
            data.canEdit = access.canEdit;
            data.canManageMembers = access.canManage;
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
                PM_Issue__c before = queryIssue(rec.Id);
                if (rec.Assignee__c != null) {
                    assertAssignable(before.Project__c, rec.Assignee__c);
                }
                assertDates(
                    fields.containsKey('Start_Date__c') ? rec.Start_Date__c : before.Start_Date__c,
                    fields.containsKey('Due_Date__c') ? rec.Due_Date__c : before.Due_Date__c
                );
                update as user rec;
                PM_Issue__c after = queryIssue(rec.Id);
                ProjectActivityController.issueChanged(before, after);
                return after;
            }
            String projectId = asString(fields.get('Project__c'));
            if (rec.Assignee__c != null && String.isNotBlank(projectId)) {
                assertAssignable(Id.valueOf(projectId), rec.Assignee__c);
            }
            assertDates(rec.Start_Date__c, rec.Due_Date__c);
            insertIssue(rec, String.isBlank(projectId) ? null : Id.valueOf(projectId));
            PM_Issue__c created = queryIssue(rec.Id);
            ProjectActivityController.issuesCreated(new List<PM_Issue__c>{ created });
            return created;
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
            PM_Issue__c before = String.isNotBlank(status) ? queryIssue(issueId) : null;
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
            if (before != null && before.Status__c != status) {
                ProjectActivityController.issueChanged(before, queryIssue(issueId));
            }
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void deleteIssue(Id issueId) {
        try {
            // BRDs are linked by lookup and are owned by their author: delete the issue as the user first (this
            // checks the user may change the project), then remove its BRD even when someone else wrote it.
            List<PM_BRD__c> brds = [SELECT Id FROM PM_BRD__c WHERE Issue__c = :issueId WITH USER_MODE];
            // Links where this issue blocks others (the links where it is blocked go with it)
            delete as user [SELECT Id FROM PM_Dependency__c WHERE Blocking_Issue__c = :issueId WITH USER_MODE];
            delete as user new PM_Issue__c(Id = issueId);
            if (!brds.isEmpty()) {
                ProjectBoardSharing.deleteAsSystem(brds);
            }
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
            ProjectActivityController.commentAdded(
                [SELECT Id, Name, Summary__c, Project__c FROM PM_Issue__c WHERE Id = :issueId WITH USER_MODE], body
            );
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

    // ---------------------------------------------------------------- Members

    /** Adds a user to the project (Leads only). Lead and Member can edit, Viewer can only read. */
    @AuraEnabled
    public static MemberInfo addMember(Id projectId, Id userId, String role) {
        try {
            assertCanManage(projectId);
            assertRole(role);
            if (userId == null) {
                throw new ProjectBoardException('Choose a user.');
            }
            List<User> users = [SELECT Id, IsActive FROM User WHERE Id = :userId];
            if (users.isEmpty() || !users[0].IsActive) {
                throw new ProjectBoardException('Only active users can be added to a project.');
            }
            if (![SELECT Id FROM PM_Project_Member__c WHERE Project__c = :projectId AND User__c = :userId WITH USER_MODE].isEmpty()) {
                throw new ProjectBoardException('This user is already a member of the project.');
            }
            PM_Project_Member__c m = new PM_Project_Member__c(Project__c = projectId, User__c = userId, Role__c = role);
            insert as user m;
            for (MemberInfo info : members(projectId)) {
                if (info.id == m.Id) {
                    return info;
                }
            }
            return null;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public class UserOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String title;
    }

    /** People who can be added to the project: active internal users who are not members yet (2+ letters). */
    @AuraEnabled
    public static List<UserOption> searchUsers(Id projectId, String term) {
        try {
            List<UserOption> result = new List<UserOption>();
            String text = term == null ? '' : term.trim();
            if (text.length() < 2) {
                return result;
            }
            Set<Id> members = new Set<Id>();
            for (PM_Project_Member__c m : [
                SELECT User__c FROM PM_Project_Member__c WHERE Project__c = :projectId WITH USER_MODE
            ]) {
                members.add(m.User__c);
            }
            // Bound variable: no injection; wildcards typed by the user are dropped
            String pattern = '%' + text.replace('%', '').replace('_', '') + '%';
            for (User u : [
                SELECT Id, Name, Title FROM User
                WHERE IsActive = true AND UserType = 'Standard' AND Name LIKE :pattern AND Id NOT IN :members
                WITH USER_MODE
                ORDER BY Name
                LIMIT 8
            ]) {
                UserOption o = new UserOption();
                o.id = u.Id;
                o.name = u.Name;
                o.title = u.Title;
                result.add(o);
            }
            return result;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void updateMemberRole(Id memberId, String role) {
        try {
            assertRole(role);
            PM_Project_Member__c m = [SELECT Id, Project__c, Role__c FROM PM_Project_Member__c WHERE Id = :memberId WITH USER_MODE];
            assertCanManage(m.Project__c);
            if (m.Role__c == ProjectBoardSharing.ROLE_LEAD && role != ProjectBoardSharing.ROLE_LEAD) {
                assertAnotherLead(m.Project__c, m.Id);
            }
            update as user new PM_Project_Member__c(Id = m.Id, Role__c = role);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void removeMember(Id memberId) {
        try {
            PM_Project_Member__c m = [SELECT Id, Project__c, Role__c FROM PM_Project_Member__c WHERE Id = :memberId WITH USER_MODE];
            assertCanManage(m.Project__c);
            if (m.Role__c == ProjectBoardSharing.ROLE_LEAD) {
                assertAnotherLead(m.Project__c, m.Id);
            }
            delete as user m;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    public class ProjectAccess {
        public String role;
        public Boolean canEdit = false;
        public Boolean canManage = false;
    }

    /** Role and rights of the current user on a project (owner and admins count as Lead). */
    public static ProjectAccess accessFor(Id projectId) {
        ProjectAccess access = new ProjectAccess();
        UserRecordAccess ura = [
            SELECT RecordId, HasEditAccess, HasAllAccess FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :projectId
        ];
        List<PM_Project_Member__c> mine = [
            SELECT Role__c FROM PM_Project_Member__c
            WHERE Project__c = :projectId AND User__c = :UserInfo.getUserId()
            WITH USER_MODE LIMIT 1
        ];
        access.role = !mine.isEmpty() ? mine[0].Role__c : (ura.HasAllAccess ? ProjectBoardSharing.ROLE_LEAD : ProjectBoardSharing.ROLE_VIEWER);
        access.canEdit = ura.HasEditAccess;
        access.canManage = ura.HasAllAccess || access.role == ProjectBoardSharing.ROLE_LEAD;
        return access;
    }

    private static List<MemberInfo> members(Id projectId) {
        PM_Project__c project = [SELECT OwnerId FROM PM_Project__c WHERE Id = :projectId WITH USER_MODE];
        List<PM_Project_Member__c> rows = [
            SELECT Id, User__c, User__r.Name, Role__c
            FROM PM_Project_Member__c
            WHERE Project__c = :projectId
            WITH USER_MODE
            ORDER BY User__r.Name
        ];
        Set<Id> userIds = new Set<Id>();
        for (PM_Project_Member__c m : rows) {
            userIds.add(m.User__c);
        }
        // Flags members who were added but cannot open the app yet
        Set<Id> withPermission = new Set<Id>();
        for (PermissionSetAssignment psa : [
            SELECT AssigneeId FROM PermissionSetAssignment
            WHERE AssigneeId IN :userIds AND PermissionSet.Name IN ('Project_Board_User', 'Project_Board_Admin')
        ]) {
            withPermission.add(psa.AssigneeId);
        }
        List<MemberInfo> result = new List<MemberInfo>();
        for (PM_Project_Member__c m : rows) {
            MemberInfo info = new MemberInfo();
            info.id = m.Id;
            info.userId = m.User__c;
            info.name = m.User__r == null ? null : m.User__r.Name;
            info.role = m.Role__c;
            info.isOwner = m.User__c == project.OwnerId;
            info.hasPermission = withPermission.contains(m.User__c);
            result.add(info);
        }
        return result;
    }

    private static void assertCanManage(Id projectId) {
        if (!accessFor(projectId).canManage) {
            throw new ProjectBoardException('Only project leads can manage members.');
        }
    }

    private static void assertRole(String role) {
        if (role != ProjectBoardSharing.ROLE_LEAD && role != ProjectBoardSharing.ROLE_MEMBER && role != ProjectBoardSharing.ROLE_VIEWER) {
            throw new ProjectBoardException('Role must be Lead, Member or Viewer.');
        }
    }

    private static void assertAnotherLead(Id projectId, Id memberId) {
        Integer leads = [
            SELECT COUNT() FROM PM_Project_Member__c
            WHERE Project__c = :projectId AND Role__c = :ProjectBoardSharing.ROLE_LEAD AND Id != :memberId
            WITH USER_MODE
        ];
        if (leads == 0) {
            throw new ProjectBoardException('A project needs at least one lead.');
        }
    }

    /** Issues can only be assigned to members who can edit the project (Lead or Member). */
    private static void assertAssignable(Id projectId, Id userId) {
        Integer editors = [
            SELECT COUNT() FROM PM_Project_Member__c
            WHERE Project__c = :projectId AND User__c = :userId AND Role__c != :ProjectBoardSharing.ROLE_VIEWER
            WITH USER_MODE
        ];
        if (editors == 0) {
            throw new ProjectBoardException('The assignee must be a project member with the Lead or Member role.');
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
        // Only people who can edit the project may create issues in it (the insert below checks it again)
        if (!accessFor(projectId).canEdit) {
            throw new ProjectBoardException('You cannot create issues in this project.');
        }
        ProjectBoardSharing.IssueKey key = ProjectBoardSharing.allocateIssueKey(projectId);
        rec.Project__c = projectId;
        rec.Name = key.name;
        rec.Reporter__c = UserInfo.getUserId();
        rec.Rank__c = key.rank;
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

    private static void assertDates(Date startDate, Date dueDate) {
        if (startDate != null && dueDate != null && startDate > dueDate) {
            throw new ProjectBoardException('The start date must be on or before the due date.');
        }
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
            when BOOLEAN {
                return Boolean.valueOf(s);
            }
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
