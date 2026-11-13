// Demo data for the Project Board (fictitious companies and people).
// Run after assigning the Project_Board_User permission set to yourself:
//   sf apex run -o <org> -f scripts/apex/seed-project-board.apex
// Creates the project "Northwind CRM Rollout" (NW) with a completed sprint, an active sprint, a planned sprint,
// epics, issues in every status, comments, a BRD and test scripts. Safe to re-run: it stops if NW already exists.

if (![SELECT Id FROM PM_Project__c WHERE Key__c = 'NW' LIMIT 1].isEmpty()) {
    System.debug('Project NW already exists - nothing to do.');
    return;
}
Id me = UserInfo.getUserId();

PM_Project__c project = ProjectBoardController.createProject(
    'Northwind CRM Rollout', 'NW', 'Roll-out of the new sales and service capabilities for Northwind Traders.'
);
PM_Sprint__c sprint1 = [SELECT Id FROM PM_Sprint__c WHERE Project__c = :project.Id LIMIT 1];
PM_Sprint__c sprint2 = ProjectBoardController.createSprint(project.Id);
PM_Sprint__c sprint3 = ProjectBoardController.createSprint(project.Id);

Map<String, Id> epics = new Map<String, Id>();
for (String name : new List<String>{ 'Mobile sales app', 'Data migration', 'Partner portal' }) {
    epics.put(name, ProjectBoardController.saveIssue(new Map<String, Object>{
        'Project__c' => project.Id, 'Summary__c' => name, 'Type__c' => 'Epic', 'Priority__c' => 'High'
    }).Id);
}

// summary, type, status, priority, points, sprint (1/2/3/0 = backlog), epic, assigned to me, labels
List<List<Object>> rows = new List<List<Object>>{
    // Sprint 1 (will be completed)
    new List<Object>{ 'Map legacy account hierarchy', 'Task', 'Done', 'High', 5, 1, 'Data migration', true, 'data' },
    new List<Object>{ 'Dashboard for regional managers', 'Story', 'Done', 'Medium', 5, 1, null, true, 'analytics' },
    new List<Object>{ 'Duplicate leads from web forms', 'Bug', 'Done', 'Highest', 3, 1, null, true, 'leads' },
    new List<Object>{ 'Deduplicate contacts before load', 'Task', 'In Progress', 'Medium', 3, 1, 'Data migration', false, 'data' },
    // Sprint 2 (active)
    new List<Object>{ 'Offline mode for visit reports', 'Story', 'In Progress', 'High', 8, 2, 'Mobile sales app', true, 'mobile' },
    new List<Object>{ 'Push notifications for approvals', 'Story', 'To Do', 'Medium', 5, 2, 'Mobile sales app', false, 'mobile' },
    new List<Object>{ 'Login fails with SSO on iOS', 'Bug', 'In Review', 'Highest', 3, 2, 'Mobile sales app', true, 'mobile, sso' },
    new List<Object>{ 'Validate opportunity currency conversion', 'Bug', 'To Do', 'High', 2, 2, 'Data migration', true, 'finance' },
    new List<Object>{ 'Account plan template', 'Story', 'Done', 'Medium', 5, 2, null, true, 'sales' },
    new List<Object>{ 'Case auto-close rules', 'Task', 'Done', 'Low', 2, 2, null, false, 'service' },
    // Sprint 3 (planned)
    new List<Object>{ 'Partner self-registration flow', 'Story', 'To Do', 'Medium', 8, 3, 'Partner portal', false, 'portal' },
    new List<Object>{ 'Deal registration approval', 'Story', 'To Do', 'Low', 5, 3, 'Partner portal', false, 'portal' },
    // Backlog
    new List<Object>{ 'Consent capture on contact forms', 'Story', 'To Do', 'High', 5, 0, null, false, 'compliance' },
    new List<Object>{ 'Archive inactive accounts', 'Task', 'To Do', 'Lowest', 1, 0, 'Data migration', false, 'data' },
    new List<Object>{ 'Slow list views on Cases', 'Bug', 'To Do', 'Medium', null, 0, null, false, 'performance' }
};
Map<Integer, Id> sprintIds = new Map<Integer, Id>{ 1 => sprint1.Id, 2 => sprint2.Id, 3 => sprint3.Id };
Map<String, Id> issueIds = new Map<String, Id>();
for (List<Object> r : rows) {
    Map<String, Object> f = new Map<String, Object>{
        'Project__c' => project.Id, 'Summary__c' => r[0], 'Type__c' => r[1], 'Status__c' => r[2],
        'Priority__c' => r[3], 'Story_Points__c' => r[4], 'Labels__c' => r[8],
        'Description__c' => '<p>Demo issue for the <b>Northwind CRM Rollout</b> project.</p>'
    };
    Integer sprintNo = (Integer) r[5];
    if (sprintIds.containsKey(sprintNo)) {
        f.put('Sprint__c', sprintIds.get(sprintNo));
    }
    if (r[6] != null) {
        f.put('Epic__c', epics.get((String) r[6]));
    }
    if ((Boolean) r[7]) {
        f.put('Assignee__c', me);
    }
    issueIds.put((String) r[0], ProjectBoardController.saveIssue(f).Id);
}

// Sprint 1 completed (open work carried over to sprint 2), sprint 2 active
ProjectBoardController.startSprint(sprint1.Id, 'NW Sprint 1', Date.today().addDays(-24), Date.today().addDays(-10), 'Migrate the account hierarchy');
ProjectBoardController.completeSprint(sprint1.Id, sprint2.Id);
ProjectBoardController.startSprint(sprint2.Id, 'NW Sprint 2', Date.today().addDays(-6), Date.today().addDays(8),
    'Ship offline visit reports and finish the data checks');

// Comments
Id offline = issueIds.get('Offline mode for visit reports');
ProjectBoardController.addComment(offline, '<p>Offline sync works for accounts; still testing attachments.</p>');
ProjectBoardController.addComment(offline, '<p>Let us demo this in the sprint review.</p>');

// BRD + test scripts on the offline story
PM_BRD__c brd = ProjectDocsController.createBrd(offline);
ProjectDocsController.saveBrd(new Map<String, Object>{
    'Id' => brd.Id, 'PBI_ID__c' => 'PBI-0042', 'Business_Analyst__c' => 'Maria Santos',
    'Business_Requestor__c' => 'Tomas Novak', 'Initiator_Name__c' => 'Northwind Sales Operations',
    'Initiator_Date__c' => String.valueOf(Date.today().addDays(-12)), 'IT_Approver_Name__c' => 'Alex Morgan',
    'IT_Approver_Date__c' => String.valueOf(Date.today().addDays(-11))
});
ProjectDocsController.saveRequirement(new Map<String, Object>{
    'Id' => brd.Requirements__r[0].Id,
    'Requirement__c' => 'Sales reps can create visit reports without network coverage\nReports sync automatically when the device is back online',
    'Acceptance_Criteria__c' => 'A visit report can be saved offline\nOffline reports sync within 5 minutes of reconnecting\nSync conflicts are shown to the rep',
    'Solution__c' => 'Prime Account and Visit Report records for offline use\nAdd an offline-capable quick action for visit reports'
});
ProjectDocsController.generateTestCasesFromBrd(offline);
List<PM_Test_Case__c> cases = ProjectDocsController.getTestCases(offline);
ProjectDocsController.saveTestCase(new Map<String, Object>{
    'Id' => cases[0].Id, 'Status__c' => 'Pass', 'Preconditions__c' => 'Rep with the mobile app installed\nDevice in airplane mode',
    'Steps__c' => '[{"action":"Open an Account and create a visit report","expected":"The report is saved on the device","actual":"Saved, shown with a pending-sync icon"}]'
});
ProjectDocsController.saveTestCase(new Map<String, Object>{ 'Id' => cases[1].Id, 'Status__c' => 'Fail',
    'Comments__c' => 'Sync took 9 minutes on a slow network.' });
System.debug('Project Board demo data created: ' + project.Id);
