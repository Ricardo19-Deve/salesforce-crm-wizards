/**
 * Record access and governed sign-off of the project board: projects are visible to members only, roles limit
 * what members can do, and BRD sign-offs are recorded by the named approver.
 */
@IsTest
private class ProjectBoardAccessTest {


    private static Map<String, User> users() {
        // A profile without "View All Data", so record access comes only from sharing
        Id standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
        Map<String, User> byRole = new Map<String, User>();
        for (String alias : new List<String>{ 'lead', 'member', 'outsider' }) {
            byRole.put(alias, new User(
                Alias = 'pb' + alias.left(6),
                Email = alias + '@example.com',
                EmailEncodingKey = 'UTF-8',
                LastName = 'Board ' + alias,
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = standardProfile,
                TimeZoneSidKey = 'Europe/Lisbon',
                Username = 'board.' + alias + '.' + System.currentTimeMillis() + '@example.com.test'
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

    private static Boolean fails(Callable action) {
        try {
            action.call(null, null);
            return false;
        } catch (AuraHandledException e) {
            return true;
        }
    }

    private class Move implements Callable {
        Id issueId;
        Move(Id issueId) { this.issueId = issueId; }
        public Object call(String action, Map<String, Object> args) {
            ProjectBoardController.moveIssue(issueId, 'In Progress', false, null, 5);
            return null;
        }
    }

    private class AddMember implements Callable {
        Id projectId; Id userId;
        AddMember(Id projectId, Id userId) { this.projectId = projectId; this.userId = userId; }
        public Object call(String action, Map<String, Object> args) {
            return ProjectBoardController.addMember(projectId, userId, 'Member');
        }
    }

    private class Assign implements Callable {
        Id issueId; Id userId;
        Assign(Id issueId, Id userId) { this.issueId = issueId; this.userId = userId; }
        public Object call(String action, Map<String, Object> args) {
            return ProjectBoardController.saveIssue(new Map<String, Object>{ 'Id' => issueId, 'Assignee__c' => userId });
        }
    }

    @IsTest
    static void projectsAreVisibleToMembersOnly() {
        Map<String, User> u = users();
        PM_Project__c project;
        PM_Issue__c issue;
        System.runAs(u.get('lead')) {
            project = ProjectBoardController.createProject('Private project', 'PRV', null);
            issue = ProjectBoardController.saveIssue(new Map<String, Object>{ 'Project__c' => project.Id, 'Summary__c' => 'Secret work' });
            ProjectBoardController.BoardData data = ProjectBoardController.getBoardData(project.Id);
            System.assertEquals('Lead', data.myRole);
            System.assertEquals(true, data.canManageMembers);
            System.assertEquals(1, data.members.size(), 'The creator becomes the first lead');
        }
        System.runAs(u.get('outsider')) {
            System.assertEquals(0, ProjectBoardController.getProjects().size(), 'Non-members do not see the project');
            System.assert(fails(new Move(issue.Id)), 'Non-members cannot change issues');
        }

        Test.startTest();
        System.runAs(u.get('lead')) {
            ProjectBoardController.addMember(project.Id, u.get('member').Id, 'Viewer');
            System.assert(fails(new AddMember(project.Id, u.get('member').Id)), 'One membership per user');
        }
        System.runAs(u.get('member')) {
            System.assertEquals(1, ProjectBoardController.getProjects().size());
            ProjectBoardController.BoardData data = ProjectBoardController.getBoardData(project.Id);
            System.assertEquals('Viewer', data.myRole);
            System.assertEquals(false, data.canEdit);
            System.assert(fails(new Move(issue.Id)), 'Viewers are read only');
            System.assert(fails(new AddMember(project.Id, u.get('outsider').Id)), 'Only leads manage members');
        }
        Id memberRow = [SELECT Id FROM PM_Project_Member__c WHERE User__c = :u.get('member').Id].Id;
        System.runAs(u.get('lead')) {
            ProjectBoardController.updateMemberRole(memberRow, 'Member');
            System.assert(fails(new Assign(issue.Id, u.get('outsider').Id)), 'Only members can be assignees');
        }
        System.runAs(u.get('member')) {
            ProjectBoardController.moveIssue(issue.Id, 'In Progress', false, null, 5);
            ProjectBoardController.saveIssue(new Map<String, Object>{ 'Id' => issue.Id, 'Assignee__c' => u.get('member').Id });
        }
        System.runAs(u.get('lead')) {
            Id leadRow = [SELECT Id FROM PM_Project_Member__c WHERE User__c = :u.get('lead').Id].Id;
            Boolean blocked = false;
            try {
                ProjectBoardController.removeMember(leadRow);
            } catch (AuraHandledException e) {
                blocked = true;
            }
            System.assert(blocked, 'The last lead cannot leave');
            ProjectBoardController.removeMember(memberRow);
        }
        Test.stopTest();
        System.runAs(u.get('member')) {
            System.assertEquals(0, ProjectBoardController.getProjects().size(), 'Removed members lose access');
        }
    }

    @IsTest
    static void brdSignOffIsRecordedByTheNamedApprover() {
        Map<String, User> u = users();
        PM_Issue__c issue;
        PM_BRD__c brd;
        Map<String, Id> signOff = new Map<String, Id>();
        System.runAs(u.get('lead')) {
            PM_Project__c project = ProjectBoardController.createProject('Docs', 'DOC', null);
            ProjectBoardController.addMember(project.Id, u.get('member').Id, 'Viewer');
            issue = ProjectBoardController.saveIssue(new Map<String, Object>{ 'Project__c' => project.Id, 'Summary__c' => 'Case reopening' });
            brd = ProjectDocsController.createBrd(issue.Id);
            for (PM_Sign_Off__c so : brd.Sign_Offs__r) {
                signOff.put(so.Role__c, so.Id);
            }
            System.assertEquals(5, signOff.size());
            ProjectDocsController.assignSignOff(signOff.get('Business Change Initiator'), u.get('member').Id, false);
            ProjectDocsController.assignSignOff(signOff.get('IT Delivery BRD Approver'), u.get('lead').Id, false);
            ProjectDocsController.assignSignOff(signOff.get('IT Architect Approver'), null, true);
            ProjectDocsController.assignSignOff(signOff.get('Solution Reviewer'), null, true);
            Boolean outsiderRejected = false;
            try {
                ProjectDocsController.assignSignOff(signOff.get('Solution Reviewer'), u.get('outsider').Id, false);
            } catch (AuraHandledException e) {
                outsiderRejected = true;
            }
            System.assert(outsiderRejected, 'Approvers must be project members');
            ProjectDocsController.requestSignOff(brd.Id);
            ProjectDocsController.BrdView view = ProjectDocsController.getBrdView(issue.Id);
            System.assertEquals(true, view.locked);
            System.assertEquals(true, view.canReopen);
            Boolean locked = false;
            try {
                ProjectDocsController.saveRequirement(new Map<String, Object>{
                    'Id' => brd.Requirements__r[0].Id, 'Requirement__c' => 'Changed after sending'
                });
            } catch (AuraHandledException e) {
                locked = true;
            }
            System.assert(locked, 'Content is locked while waiting for sign-off');
        }

        Test.startTest();
        System.runAs(u.get('member')) {
            Boolean notMine = false;
            try {
                ProjectDocsController.decideSignOff(signOff.get('IT Delivery BRD Approver'), 'Approved', null);
            } catch (AuraHandledException e) {
                notMine = true;
            }
            System.assert(notMine, 'Only the named approver can decide');
            // The approver is a Viewer: the decision is still recorded
            ProjectDocsController.decideSignOff(signOff.get('Business Change Initiator'), 'Approved', null);
        }
        System.runAs(u.get('lead')) {
            ProjectDocsController.decideSignOff(signOff.get('IT Delivery BRD Approver'), 'Approved', 'Fine');
            ProjectDocsController.decideSignOff(signOff.get('Solution Designer'), 'Approved', null);
        }
        PM_BRD__c approved = [SELECT Status__c, Version__c FROM PM_BRD__c WHERE Id = :brd.Id];
        System.assertEquals('Approved', approved.Status__c);
        PM_Sign_Off__c initiator = [SELECT Status__c, Decision_Date__c FROM PM_Sign_Off__c WHERE Id = :signOff.get('Business Change Initiator')];
        System.assertEquals('Approved', initiator.Status__c);
        System.assertNotEquals(null, initiator.Decision_Date__c, 'The date is recorded by the system');

        System.runAs(u.get('lead')) {
            Test.setCurrentPage(Page.ProjectBrdExport);
            ApexPages.currentPage().getParameters().put('id', brd.Id);
            ProjectExportController exportCtrl = new ProjectExportController();
            exportCtrl.initBrd();
            System.assertEquals(3, exportCtrl.brdSignOffs.size());
            System.assertEquals(2, exportCtrl.solutionSignOffs.size());
            System.assertEquals('N/A', exportCtrl.brdSignOffs[2].approver);

            ProjectDocsController.reopenBrd(brd.Id);
            System.assertEquals('1.1', [SELECT Version__c FROM PM_BRD__c WHERE Id = :brd.Id].Version__c);
            ProjectDocsController.requestSignOff(brd.Id);
        }
        System.runAs(u.get('member')) {
            Boolean needsComment = false;
            try {
                ProjectDocsController.decideSignOff(signOff.get('Business Change Initiator'), 'Rejected', ' ');
            } catch (AuraHandledException e) {
                needsComment = true;
            }
            System.assert(needsComment, 'A rejection needs a comment');
            ProjectDocsController.decideSignOff(signOff.get('Business Change Initiator'), 'Rejected', 'Add the UK scope');
        }
        Test.stopTest();
        System.assertEquals('Changes Requested', [SELECT Status__c FROM PM_BRD__c WHERE Id = :brd.Id].Status__c);
        System.assertEquals('1.2', ProjectDocsController.nextVersion('1.1'));
    }

    @IsTest
    static void membersCanCleanUpDocumentsWrittenByOthers() {
        Map<String, User> u = users();
        PM_Issue__c issue;
        System.runAs(u.get('lead')) {
            PM_Project__c project = ProjectBoardController.createProject('Cleanup', 'CLN', null);
            ProjectBoardController.addMember(project.Id, u.get('member').Id, 'Member');
            issue = ProjectBoardController.saveIssue(new Map<String, Object>{ 'Project__c' => project.Id, 'Summary__c' => 'Obsolete' });
            ProjectDocsController.createBrd(issue.Id);
        }
        Test.startTest();
        System.runAs(u.get('member')) {
            System.assertNotEquals(null, ProjectDocsController.getBrd(issue.Id), 'BRDs are shared with members');
            ProjectBoardController.deleteIssue(issue.Id);
        }
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM PM_BRD__c]);
    }
}
