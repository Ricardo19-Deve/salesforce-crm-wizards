/**
 * Shares a new BRD with the members of its project (BRDs are Private and linked to the issue by lookup).
 */
trigger ProjectBrdTrigger on PM_BRD__c (after insert) {
    ProjectBoardSharing.syncBrds(Trigger.newMap.keySet());
}
