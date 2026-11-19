/**
 * System-mode boundary of the project board. Two jobs only:
 *  1. Apex managed sharing: projects and BRDs are Private; members get access through shares with the
 *     RowCause Project_Member__c (Lead / Member = Edit, Viewer = Read). Sprints, issues, test cases, requirements
 *     and sign-offs follow their master record automatically.
 *  2. Writes that must succeed for a user with read-only access: an approver recording a sign-off decision, and
 *     the clean-up of a BRD when its issue is deleted.
 *
 * Where: called by ProjectMemberTrigger, ProjectBrdTrigger, ProjectBoardController and ProjectDocsController.
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
