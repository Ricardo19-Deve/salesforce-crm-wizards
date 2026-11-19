/**
 * Keeps one membership per user and project (Member_Key__c) and rebuilds the project's member shares.
 */
trigger ProjectMemberTrigger on PM_Project_Member__c (before insert, before update, after insert, after update, after delete, after undelete) {
    if (Trigger.isBefore) {
        for (PM_Project_Member__c m : Trigger.new) {
            m.Member_Key__c = String.valueOf(m.Project__c) + String.valueOf(m.User__c);
        }
        return;
    }
    Set<Id> projectIds = new Set<Id>();
    for (PM_Project_Member__c m : Trigger.isDelete ? Trigger.old : Trigger.new) {
        projectIds.add(m.Project__c);
    }
    ProjectBoardSharing.syncProjects(projectIds);
}
