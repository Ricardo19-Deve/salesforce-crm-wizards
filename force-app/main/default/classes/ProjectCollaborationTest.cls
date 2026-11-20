/**
 * Followers, mentions and the inbox; dependencies; the request form; the portfolio.
 */
@IsTest
private class ProjectCollaborationTest {


    private static Map<String, User> users() {
        Id standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
        Map<String, User> byRole = new Map<String, User>();
        for (String alias : new List<String>{ 'lead', 'member', 'viewer', 'outsider' }) {
            byRole.put(alias, new User(
                Alias = 'cb' + alias.left(6),
                Email = alias + '@example.com',
                EmailEncodingKey = 'UTF-8',
                FirstName = 'Collab',
                LastName = alias.capitalize(),
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = standardProfile,
                TimeZoneSidKey = 'Europe/Lisbon',
                Username = 'collab.' + alias + '.' + System.currentTimeMillis() + '@example.com.test'
            ));
        }
        insert byRole.values();
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Project_Board_User'];
        List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
        for (User u : byRole.values()) {
            psas.add(new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id));
        }
        insert psas;
        return byRole;
    }

    /** Project led by `lead`, with `member` (Member) and `viewer` (Viewer). */
    private static PM_Project__c project(Map<String, User> u, String key) {
        PM_Project__c p;
        System.runAs(u.get('lead')) {
            p = ProjectBoardController.createProject('Collab ' + key, key, null);
            ProjectBoardController.addMember(p.Id, u.get('member').Id, 'Member');
            ProjectBoardController.addMember(p.Id, u.get('viewer').Id, 'Viewer');
        }
        return p;
    }

    private static PM_Issue__c issue(Id projectId, String summary) {
        return ProjectBoardController.saveIssue(new Map<String, Object>{ 'Project__c' => projectId, 'Summary__c' => summary });
    }

    private static Integer unread(User u) {
        Integer count;
        System.runAs(u) {
            count = ProjectActivityController.getInbox().unread;
        }
        return count;
    }

    @IsTest
    static void mentionsFollowersAndInbox() {
        Map<String, User> u = users();
        PM_Project__c p = project(u, 'CLB');
        PM_Issue__c i;
        Test.startTest();
        System.runAs(u.get('lead')) {
            i = issue(p.Id, 'Offline sync');
            // Assigning notifies the member and makes them a follower
            ProjectBoardController.saveIssue(new Map<String, Object>{ 'Id' => i.Id, 'Assignee__c' => u.get('member').Id });
        }
        System.assertEquals(1, unread(u.get('member')), 'The assignee is told');

        System.runAs(u.get('viewer')) {
            ProjectActivityController.Followers f = ProjectActivityController.setFollowing(i.Id, true);
            System.assert(f.following, 'A Viewer can follow');
        }
        System.runAs(u.get('lead')) {
            ProjectBoardController.addComment(i.Id, '<p>Can you check this, <b>@Collab Viewer</b>?</p>');
        }
        System.runAs(u.get('viewer')) {
            ProjectActivityController.Inbox inbox = ProjectActivityController.getInbox();
            System.assertEquals(1, inbox.unread, 'One notification per person and action');
            System.assertEquals('Mentioned', inbox.items[0].type, 'A mention beats the follower notification');
            ProjectActivityController.markIssueRead(i.Id);
            System.assertEquals(0, ProjectActivityController.getInbox().unread);
        }
        System.assertEquals(2, unread(u.get('member')), 'The follower hears about the comment');
        System.assertEquals(0, unread(u.get('lead')), 'Nobody is told about their own actions');

        System.runAs(u.get('member')) {
            ProjectBoardController.moveIssue(i.Id, 'In Review', false, null, 3);
            System.assertEquals(3, ProjectActivityController.getFollowers(i.Id).people.size(),
                'Reporter, assignee and viewer follow');
            ProjectActivityController.markRead(new List<Id>());
            System.assertEquals(0, ProjectActivityController.getInbox().unread);
        }
        System.runAs(u.get('viewer')) {
            System.assertEquals(1, ProjectActivityController.getInbox().unread, 'Followers hear about status changes');
            ProjectActivityController.setFollowing(i.Id, false);
            System.assert(!ProjectActivityController.getFollowers(i.Id).following);
        }
        Test.stopTest();
    }

    @IsTest
    static void mentionMatchingPrefersLongerNames() {
        Id a = UserInfo.getUserId();
        Id b = [SELECT Id FROM User WHERE Id != :a AND IsActive = true LIMIT 1].Id;
        Map<Id, String> members = new Map<Id, String>{ a => 'Ana', b => 'Ana Silva' };
        System.assertEquals(new Set<Id>{ b }, ProjectActivityController.mentionedIn('Thanks @Ana Silva!', members));
        System.assertEquals(new Set<Id>{ a, b }, ProjectActivityController.mentionedIn('@ana and @Ana Silva', members));
        System.assert(ProjectActivityController.mentionedIn('email ana@x.com, @Anabela', members).isEmpty());
    }

    @IsTest
    static void dependenciesAndTimelineDates() {
        Map<String, User> u = users();
        PM_Project__c p = project(u, 'DEP');
        PM_Project__c other = project(u, 'OTH');
        System.runAs(u.get('lead')) {
            PM_Issue__c a = issue(p.Id, 'Design');
            PM_Issue__c b = issue(p.Id, 'Build');
            PM_Issue__c c = issue(p.Id, 'Release');
            PM_Issue__c x = issue(other.Id, 'Elsewhere');
            Test.startTest();
            ProjectPlanController.addDependency(b.Id, a.Id);
            ProjectPlanController.DependencyInfo bc = ProjectPlanController.addDependency(c.Id, b.Id);
            System.assert(fails(new LinkDeps(a.Id, c.Id)), 'A loop is refused');
            System.assert(fails(new LinkDeps(a.Id, a.Id)), 'An issue cannot wait for itself');
            System.assert(fails(new LinkDeps(a.Id, x.Id)), 'Dependencies stay inside a project');
            System.assert(fails(new LinkDeps(b.Id, a.Id)), 'No duplicates');
            System.assertEquals(2, ProjectBoardController.getBoardData(p.Id).dependencies.size());

            ProjectBoardController.saveIssue(new Map<String, Object>{
                'Id' => c.Id, 'Start_Date__c' => '2026-12-01', 'Due_Date__c' => '2026-12-10', 'Milestone__c' => true
            });
            System.assert(fails(new SaveFields(new Map<String, Object>{ 'Id' => c.Id, 'Start_Date__c' => '2026-12-20' })),
                'The start date cannot be after the due date');
            PM_Issue__c saved = [SELECT Milestone__c, Start_Date__c FROM PM_Issue__c WHERE Id = :c.Id];
            System.assert(saved.Milestone__c);

            ProjectPlanController.removeDependency(bc.id);
            ProjectBoardController.deleteIssue(a.Id);
            System.assertEquals(0, [SELECT COUNT() FROM PM_Dependency__c], 'Links go with the deleted issue');
            Test.stopTest();
        }
        System.runAs(u.get('viewer')) {
            PM_Issue__c b = [SELECT Id FROM PM_Issue__c WHERE Summary__c = 'Build'];
            PM_Issue__c c = [SELECT Id FROM PM_Issue__c WHERE Summary__c = 'Release'];
            System.assert(fails(new LinkDeps(c.Id, b.Id)), 'Viewers cannot link issues');
        }
    }

    @IsTest
    static void requestsFromOutsideTheProject() {
        Map<String, User> u = users();
        PM_Project__c p = project(u, 'REQ');
        System.runAs(u.get('member')) {
            System.assert(fails(new AcceptRequests(p.Id)), 'Only leads open a project to requests');
        }
        System.runAs(u.get('outsider')) {
            System.assert(ProjectPlanController.getRequestContext().projects.isEmpty(), 'Closed projects are not offered');
        }
        System.runAs(u.get('lead')) {
            ProjectPlanController.setAcceptsRequests(p.Id, true);
        }
        ProjectPlanController.RequestInfo filed;
        Test.startTest();
        System.runAs(u.get('outsider')) {
            ProjectPlanController.RequestContext ctx = ProjectPlanController.getRequestContext();
            System.assertEquals(1, ctx.projects.size());
            System.assert(fails(new SubmitRequest(p.Id, ' ')), 'A summary is required');
            filed = ProjectPlanController.submitRequest(p.Id, 'New regional sales report', 'Details', 'Story', 'High');
            System.assertEquals('REQ-1', filed.key);
            System.assertEquals('To Do', filed.status);
            System.assertEquals(0, [SELECT COUNT() FROM PM_Issue__c WITH USER_MODE], 'The requester still cannot open the project');
        }
        System.assertEquals(1, unread(u.get('lead')), 'The lead is told about the request');
        System.runAs(u.get('lead')) {
            ProjectBoardController.moveIssue(filed.id, 'In Progress', false, null, 1);
            System.assertEquals(0, ProjectPlanController.getPortfolio()[0].requests,
                'A request in progress is no longer waiting for triage');
        }
        System.runAs(u.get('outsider')) {
            ProjectActivityController.Inbox inbox = ProjectActivityController.getInbox();
            System.assertEquals(1, inbox.unread, 'The requester hears about the status');
            System.assertEquals('Request', inbox.items[0].type);
            System.assertEquals('In Progress', ProjectPlanController.getRequestContext().mine[0].status);
        }
        Test.stopTest();
    }

    @IsTest
    static void portfolioHealth() {
        Map<String, User> u = users();
        PM_Project__c p = project(u, 'PRT');
        System.runAs(u.get('lead')) {
            PM_Sprint__c sprint = [SELECT Id FROM PM_Sprint__c WHERE Project__c = :p.Id];
            PM_Issue__c done = issue(p.Id, 'Done work');
            PM_Issue__c late = issue(p.Id, 'Late work');
            ProjectBoardController.saveIssue(new Map<String, Object>{ 'Id' => done.Id, 'Sprint__c' => sprint.Id, 'Story_Points__c' => 3 });
            ProjectBoardController.saveIssue(new Map<String, Object>{
                'Id' => late.Id, 'Sprint__c' => sprint.Id, 'Story_Points__c' => 5,
                'Due_Date__c' => String.valueOf(Date.today().addDays(-2)), 'Milestone__c' => true
            });
            ProjectBoardController.startSprint(sprint.Id, null, Date.today().addDays(-7), Date.today().addDays(7), 'Goal');
            ProjectBoardController.moveIssue(done.Id, 'Done', false, null, 1);
            ProjectPlanController.addDependency(late.Id, issue(p.Id, 'Blocker').Id);
            Test.startTest();
            List<ProjectPlanController.PortfolioRow> rows = ProjectPlanController.getPortfolio();
            Test.stopTest();
            System.assertEquals(1, rows.size());
            ProjectPlanController.PortfolioRow r = rows[0];
            System.assertEquals('Lead', r.myRole);
            System.assertEquals(3, r.members);
            System.assertEquals(38, r.progress, '3 of 8 points');
            System.assertEquals(1, r.overdue);
            System.assertEquals(1, r.blocked);
            System.assert(r.milestoneLate);
            System.assertEquals(ProjectPlanController.HEALTH_OFF_TRACK, r.health);
            System.assert(!r.reasons.isEmpty());
        }
        System.runAs(u.get('outsider')) {
            System.assert(ProjectPlanController.getPortfolio().isEmpty(), 'Only projects the user can see');
        }
    }

    @IsTest
    static void searchPeopleToAdd() {
        Map<String, User> u = users();
        PM_Project__c p = project(u, 'SRC');
        System.runAs(u.get('lead')) {
            System.assert(ProjectBoardController.searchUsers(p.Id, 'C').isEmpty(), 'Two letters at least');
            Set<Id> found = new Set<Id>();
            for (ProjectBoardController.UserOption o : ProjectBoardController.searchUsers(p.Id, 'Collab')) {
                found.add(o.id);
            }
            System.assert(found.contains(u.get('outsider').Id), 'Non-members are offered');
            System.assert(!found.contains(u.get('member').Id), 'Members are not offered again');
        }
    }

    @IsTest
    static void healthRules() {
        ProjectPlanController.PortfolioRow r = new ProjectPlanController.PortfolioRow();
        ProjectPlanController.assess(r, Date.today());
        System.assertEquals(ProjectPlanController.HEALTH_ON_TRACK, r.health, 'Nothing late, no sprint');
        r = new ProjectPlanController.PortfolioRow();
        r.sprintName = 'S';
        r.sprintStart = Date.today().addDays(-5);
        r.sprintEnd = Date.today().addDays(5);
        r.sprintPoints = 10;
        r.sprintDone = 2;
        ProjectPlanController.assess(r, Date.today());
        System.assertEquals(ProjectPlanController.HEALTH_AT_RISK, r.health, '50% of the time, 20% of the work');
    }

    // ---------------------------------------------------------------- Helpers

    private static Boolean fails(Callable action) {
        try {
            action.call(null, null);
            return false;
        } catch (AuraHandledException e) {
            return true;
        }
    }

    private class LinkDeps implements Callable {
        Id blocked; Id blocking;
        LinkDeps(Id blocked, Id blocking) { this.blocked = blocked; this.blocking = blocking; }
        public Object call(String action, Map<String, Object> args) {
            return ProjectPlanController.addDependency(blocked, blocking);
        }
    }

    private class SaveFields implements Callable {
        Map<String, Object> fields;
        SaveFields(Map<String, Object> fields) { this.fields = fields; }
        public Object call(String action, Map<String, Object> args) {
            return ProjectBoardController.saveIssue(fields);
        }
    }

    private class AcceptRequests implements Callable {
        Id projectId;
        AcceptRequests(Id projectId) { this.projectId = projectId; }
        public Object call(String action, Map<String, Object> args) {
            ProjectPlanController.setAcceptsRequests(projectId, true);
            return null;
        }
    }

    private class SubmitRequest implements Callable {
        Id projectId; String summary;
        SubmitRequest(Id projectId, String summary) { this.projectId = projectId; this.summary = summary; }
        public Object call(String action, Map<String, Object> args) {
            return ProjectPlanController.submitRequest(projectId, summary, null, 'Task', 'Medium');
        }
    }
}
