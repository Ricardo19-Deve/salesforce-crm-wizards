/**
 * System-mode boundary of the project board. Three jobs only:
 *  1. Apex managed sharing: projects and BRDs are Private; members get access through shares with the
 *     RowCause Project_Member__c (Lead / Member = Edit, Viewer = Read). Sprints, issues, test cases, requirements,
 *     sign-offs, followers and dependencies follow their master record automatically.
 *  2. Writes that must succeed for a user with read-only access: an approver recording a sign-off decision, the
 *     clean-up of a BRD when its issue is deleted, a Viewer following an issue, inbox notifications for other
 *     users, and a request filed by someone who is not a member of the project.
 *  3. Reads across projects the caller cannot see: unique project keys, the projects that accept requests, the
 *     requester's own requests and project membership (to decide who is notified).
 *
 * Where: called by the triggers and by ProjectBoardController, ProjectDocsController, ProjectActivityController
 * and ProjectPlanController.
 * Gotchas: the callers check the business rules (who may approve, who may delete) before calling in here. Owner
 * shares and manual shares are never touched: only rows with RowCause Project_Member__c are rebuilt.
 */
public without sharing class ProjectBoardSharing {

    public static final String ROLE_LEAD = 'Lead';
    public static final String ROLE_MEMBER = 'Member';
    public static final String ROLE_VIEWER = 'Viewer';

    /** Rebuilds the member shares of these projects and of the BRDs of their issues. */
    public static void syncProjects(Set<Id> projectIds) {
        projectIds.remove(null);
        if (projectIds.isEmpty()) {
            return;
        }
        Map<Id, Map<Id, String>> access = memberAccess(projectIds);
        Map<Id, Id> owners = new Map<Id, Id>();
        for (PM_Project__c p : [SELECT Id, OwnerId FROM PM_Project__c WHERE Id IN :projectIds]) {
            owners.put(p.Id, p.OwnerId);
        }

        String rowCause = Schema.PM_Project__Share.RowCause.Project_Member__c;
        delete [SELECT Id FROM PM_Project__Share WHERE ParentId IN :projectIds AND RowCause = :rowCause];
        List<PM_Project__Share> shares = new List<PM_Project__Share>();
        for (Id projectId : owners.keySet()) {
            Map<Id, String> users = access.containsKey(projectId) ? access.get(projectId) : new Map<Id, String>();
            for (Id userId : users.keySet()) {
                if (userId != owners.get(projectId)) {
                    shares.add(new PM_Project__Share(
                        ParentId = projectId, UserOrGroupId = userId, AccessLevel = users.get(userId), RowCause = rowCause
                    ));
                }
            }
        }
        insert shares;

        Map<Id, Id> brdToProject = new Map<Id, Id>();
        for (PM_BRD__c brd : [SELECT Id, Issue__r.Project__c FROM PM_BRD__c WHERE Issue__r.Project__c IN :projectIds]) {
            brdToProject.put(brd.Id, brd.Issue__r.Project__c);
        }
        syncBrdShares(brdToProject, access, owners);
    }

    /** Shares new BRDs with the members of their project. */
    public static void syncBrds(Set<Id> brdIds) {
        Map<Id, Id> brdToProject = new Map<Id, Id>();
        for (PM_BRD__c brd : [SELECT Id, Issue__r.Project__c FROM PM_BRD__c WHERE Id IN :brdIds]) {
            if (brd.Issue__r != null && brd.Issue__r.Project__c != null) {
                brdToProject.put(brd.Id, brd.Issue__r.Project__c);
            }
        }
        if (brdToProject.isEmpty()) {
            return;
        }
        Set<Id> projectIds = new Set<Id>(brdToProject.values());
        Map<Id, Id> owners = new Map<Id, Id>();
        for (PM_Project__c p : [SELECT Id, OwnerId FROM PM_Project__c WHERE Id IN :projectIds]) {
            owners.put(p.Id, p.OwnerId);
        }
        syncBrdShares(brdToProject, memberAccess(projectIds), owners);
    }

    /** Updates records the current user may only read (callers enforce who is allowed to do it). */
    public static void updateAsSystem(List<SObject> records) {
        update records;
    }

    /** Deletes records the current user may not delete directly (callers enforce who is allowed to do it). */
    public static void deleteAsSystem(List<SObject> records) {
        delete records;
    }

    /** Inserts records for other users or on read-only parents (callers enforce who is allowed to do it). */
    public static void insertAsSystem(List<SObject> records, Boolean allOrNone) {
        Database.insert(records, allOrNone);
    }

    /** Next issue key and rank of a project. Locks the project row so concurrent creations never share a key. */
    public static IssueKey allocateIssueKey(Id projectId) {
        PM_Project__c project = [SELECT Id, Key__c, Issue_Counter__c FROM PM_Project__c WHERE Id = :projectId FOR UPDATE];
        Integer next = (project.Issue_Counter__c == null ? 0 : project.Issue_Counter__c.intValue()) + 1;
        update new PM_Project__c(Id = project.Id, Issue_Counter__c = next);
        AggregateResult[] agg = [SELECT MAX(Rank__c) maxRank FROM PM_Issue__c WHERE Project__c = :projectId];
        Decimal maxRank = (Decimal) agg[0].get('maxRank');
        IssueKey result = new IssueKey();
        result.name = project.Key__c + '-' + next;
        result.rank = (maxRank == null ? 0 : maxRank.round(System.RoundingMode.FLOOR)) + 1;
        return result;
    }

    public class IssueKey {
        public String name;
        public Decimal rank;
    }

    /** Projects that accept requests, for the request form (the requester is usually not a member). */
    public static List<PM_Project__c> requestableProjects() {
        return [SELECT Id, Name, Key__c FROM PM_Project__c WHERE Accepts_Requests__c = true ORDER BY Name LIMIT 200];
    }

    /** Files a request in a project that accepts them. The caller validated the fields. */
    public static void insertRequest(PM_Issue__c rec, Id projectId) {
        if ([SELECT COUNT() FROM PM_Project__c WHERE Id = :projectId AND Accepts_Requests__c = true] == 0) {
            throw new IllegalArgumentException('This project does not accept requests.');
        }
        IssueKey key = allocateIssueKey(projectId);
        rec.Project__c = projectId;
        rec.Name = key.name;
        rec.Rank__c = key.rank;
        insert rec;
    }

    /** The requests filed by a user, with their current status, in any project. */
    public static List<PM_Issue__c> requestsOf(Id userId) {
        return [
            SELECT Id, Name, Summary__c, Status__c, Type__c, Priority__c, CreatedDate, LastModifiedDate,
                Project__c, Project__r.Name, Assignee__r.Name, Sprint__r.Name
            FROM PM_Issue__c
            WHERE Requested_By__c = :userId
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    /** projectId -> userId -> role, for active members. */
    public static Map<Id, Map<Id, String>> memberRoles(Set<Id> projectIds) {
        Map<Id, Map<Id, String>> roles = new Map<Id, Map<Id, String>>();
        for (PM_Project_Member__c m : [
            SELECT Project__c, User__c, Role__c
            FROM PM_Project_Member__c
            WHERE Project__c IN :projectIds AND User__c != null AND User__r.IsActive = true
        ]) {
            if (!roles.containsKey(m.Project__c)) {
                roles.put(m.Project__c, new Map<Id, String>());
            }
            roles.get(m.Project__c).put(m.User__c, m.Role__c);
        }
        return roles;
    }

    /** Project keys are unique across all projects, including the ones the current user cannot see. */
    public static Boolean projectKeyExists(String key) {
        return ![SELECT Id FROM PM_Project__c WHERE Key__c = :key LIMIT 1].isEmpty();
    }

    // ---------------------------------------------------------------- Helpers

    /** projectId -> userId -> 'Edit' | 'Read' for active members. */
    private static Map<Id, Map<Id, String>> memberAccess(Set<Id> projectIds) {
        Map<Id, Map<Id, String>> access = new Map<Id, Map<Id, String>>();
        for (PM_Project_Member__c m : [
            SELECT Project__c, User__c, Role__c
            FROM PM_Project_Member__c
            WHERE Project__c IN :projectIds AND User__c != null AND User__r.IsActive = true
        ]) {
            if (!access.containsKey(m.Project__c)) {
                access.put(m.Project__c, new Map<Id, String>());
            }
            access.get(m.Project__c).put(m.User__c, m.Role__c == ROLE_VIEWER ? 'Read' : 'Edit');
        }
        return access;
    }

    private static void syncBrdShares(Map<Id, Id> brdToProject, Map<Id, Map<Id, String>> access, Map<Id, Id> projectOwners) {
        if (brdToProject.isEmpty()) {
            return;
        }
        String rowCause = Schema.PM_BRD__Share.RowCause.Project_Member__c;
        Set<Id> brdIds = brdToProject.keySet();
        delete [SELECT Id FROM PM_BRD__Share WHERE ParentId IN :brdIds AND RowCause = :rowCause];
        List<PM_BRD__Share> shares = new List<PM_BRD__Share>();
        for (PM_BRD__c brd : [SELECT Id, OwnerId FROM PM_BRD__c WHERE Id IN :brdIds]) {
            Id projectId = brdToProject.get(brd.Id);
            Map<Id, String> users = access.containsKey(projectId) ? access.get(projectId).clone() : new Map<Id, String>();
            // The project owner always works on the project's documents
            if (projectOwners.containsKey(projectId)) {
                users.put(projectOwners.get(projectId), 'Edit');
            }
            for (Id userId : users.keySet()) {
                if (userId != brd.OwnerId) {
                    shares.add(new PM_BRD__Share(
                        ParentId = brd.Id, UserOrGroupId = userId, AccessLevel = users.get(userId), RowCause = rowCause
                    ));
                }
            }
        }
        insert shares;
    }
}
