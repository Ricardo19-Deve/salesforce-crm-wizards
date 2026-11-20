// Demo data for the Project Board (fictitious companies and people).
// Run after assigning the Project_Board_User permission set to yourself:
//   sf apex run -o <org> -f scripts/apex/seed-project-board.apex
// Creates the project "Northwind CRM Rollout" (NW) with a completed sprint, an active sprint, a planned sprint,
// epics, issues in every status, comments, a BRD waiting for sign-off, test scripts, timeline dates with a
// milestone and dependencies, an incoming request and a few sample notifications. You become the project lead
// (the only member): add colleagues from the Members dialog. Safe to re-run: it stops if NW already exists.

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
// Issues are inserted in bulk (one DML) so the whole seed stays well inside the governor limits
Integer counter = Integer.valueOf([SELECT Issue_Counter__c FROM PM_Project__c WHERE Id = :project.Id].Issue_Counter__c);
List<PM_Issue__c> issues = new List<PM_Issue__c>();
for (List<Object> r : rows) {
    counter++;
    Integer sprintNo = (Integer) r[5];
    issues.add(new PM_Issue__c(
        Project__c = project.Id, Name = 'NW-' + counter, Rank__c = counter, Reporter__c = me,
        Summary__c = (String) r[0], Type__c = (String) r[1], Status__c = (String) r[2], Priority__c = (String) r[3],
        Story_Points__c = (Decimal) r[4], Labels__c = (String) r[8],
        Description__c = '<p>Demo issue for the <b>Northwind CRM Rollout</b> project.</p>',
        Sprint__c = sprintIds.get(sprintNo),
        Epic__c = r[6] == null ? null : epics.get((String) r[6]),
        Assignee__c = (Boolean) r[7] ? me : null,
        Resolved_Date__c = r[2] == 'Done' ? System.now() : null
    ));
}
insert issues;
update new PM_Project__c(Id = project.Id, Issue_Counter__c = counter);
Map<String, Id> issueIds = new Map<String, Id>();
for (PM_Issue__c i : issues) {
    issueIds.put(i.Summary__c, i.Id);
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
    'Business_Requestor__c' => 'Tomas Novak'
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

// Sign-off: you approve two roles, the others are not required; one approval is already recorded
for (PM_Sign_Off__c so : ProjectDocsController.getBrd(offline).Sign_Offs__r) {
    Boolean skip = so.Role__c == 'IT Architect Approver' || so.Role__c == 'Solution Reviewer';
    ProjectDocsController.assignSignOff(so.Id, skip ? null : me, skip);
}
ProjectDocsController.requestSignOff(brd.Id);
for (PM_Sign_Off__c so : ProjectDocsController.getBrd(offline).Sign_Offs__r) {
    if (so.Role__c == 'Business Change Initiator') {
        ProjectDocsController.decideSignOff(so.Id, 'Approved', 'Scope matches the sales operations request.');
    }
}
// Timeline: start and due dates around today, a milestone and dependencies (one of them a conflict to resolve)
Map<String, List<Integer>> plan = new Map<String, List<Integer>>{
    'Deduplicate contacts before load' => new List<Integer>{ -20, -3 },
    'Validate opportunity currency conversion' => new List<Integer>{ 1, 6 },
    'Login fails with SSO on iOS' => new List<Integer>{ -4, 1 },
    'Offline mode for visit reports' => new List<Integer>{ -6, 5 },
    'Push notifications for approvals' => new List<Integer>{ 2, 8 },
    'Partner self-registration flow' => new List<Integer>{ 10, 20 },
    'Deal registration approval' => new List<Integer>{ 21, 28 }
};
List<PM_Issue__c> dated = new List<PM_Issue__c>();
for (String summary : plan.keySet()) {
    dated.add(new PM_Issue__c(
        Id = issueIds.get(summary),
        Start_Date__c = Date.today().addDays(plan.get(summary)[0]),
        Due_Date__c = Date.today().addDays(plan.get(summary)[1])
    ));
}
update dated;
Id goLive = ProjectBoardController.saveIssue(new Map<String, Object>{
    'Project__c' => project.Id, 'Summary__c' => 'Partner portal pilot go-live', 'Type__c' => 'Task',
    'Epic__c' => epics.get('Partner portal'), 'Sprint__c' => sprint3.Id, 'Milestone__c' => true,
    'Due_Date__c' => String.valueOf(Date.today().addDays(30))
}).Id;
// blocked issue => issue it waits for
Map<Id, Id> waits = new Map<Id, Id>{
    issueIds.get('Validate opportunity currency conversion') => issueIds.get('Deduplicate contacts before load'),
    issueIds.get('Push notifications for approvals') => issueIds.get('Offline mode for visit reports'),
    issueIds.get('Deal registration approval') => issueIds.get('Partner self-registration flow'),
    goLive => issueIds.get('Deal registration approval')
};
List<PM_Dependency__c> links = new List<PM_Dependency__c>();
for (Id blocked : waits.keySet()) {
    links.add(new PM_Dependency__c(
        Blocked_Issue__c = blocked, Blocking_Issue__c = waits.get(blocked),
        Dependency_Key__c = String.valueOf(blocked) + String.valueOf(waits.get(blocked))
    ));
}
insert links;

// Requests: the project accepts them, and one is waiting in the backlog
ProjectPlanController.setAcceptsRequests(project.Id, true);
ProjectPlanController.submitRequest(project.Id, 'Add a region filter to the visit report list',
    '<p>Regional managers only want to see the visits of their region.</p>', 'Story', 'High');

// Followers and sample notifications: in a one-person demo org nobody else acts, so these show what the inbox
// looks like when teammates mention you or move your work (no author: the inbox shows the event icon)
ProjectActivityController.addFollowers(new Map<Id, Set<Id>>{ offline => new Set<Id>{ me } });
Map<Id, PM_Issue__c> byId = new Map<Id, PM_Issue__c>([SELECT Id, Name, Summary__c FROM PM_Issue__c WHERE Project__c = :project.Id]);
PM_Issue__c push = byId.get(issueIds.get('Push notifications for approvals'));
PM_Issue__c sso = byId.get(issueIds.get('Login fails with SSO on iOS'));
insert new List<PM_Notification__c>{
    new PM_Notification__c(OwnerId = me, Type__c = 'Mentioned', Issue__c = offline, Project__c = project.Id,
        Issue_Key__c = byId.get(offline).Name,
        Message__c = 'Maria Santos mentioned you in ' + byId.get(offline).Name + ': ' + byId.get(offline).Summary__c),
    new PM_Notification__c(OwnerId = me, Type__c = 'Status', Issue__c = sso.Id, Project__c = project.Id,
        Issue_Key__c = sso.Name, Message__c = 'Tomas Novak moved ' + sso.Name + ': ' + sso.Summary__c + ' to In Review'),
    new PM_Notification__c(OwnerId = me, Type__c = 'Assigned', Issue__c = push.Id, Project__c = project.Id,
        Issue_Key__c = push.Name, Message__c = 'Maria Santos assigned you ' + push.Name + ': ' + push.Summary__c)
};
System.debug('Project Board demo data created: ' + project.Id);
