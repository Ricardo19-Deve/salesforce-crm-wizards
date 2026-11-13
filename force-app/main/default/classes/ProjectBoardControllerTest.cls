@IsTest
private class ProjectBoardControllerTest {


    private static User boardUser() {
        User u = new User(
            Alias = 'pbtest',
            Email = 'board.test@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Board Tester',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'Europe/Lisbon',
            Username = 'board.tester.' + System.currentTimeMillis() + '@example.com.test'
        );
        insert u;
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Project_Board_User'];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    private static Map<String, Object> issueFields(Id projectId, String summary) {
        return new Map<String, Object>{
            'Project__c' => projectId,
            'Summary__c' => summary,
            'Type__c' => 'Story',
            'Story_Points__c' => 3,
            'Due_Date__c' => '2030-01-15'
        };
    }

    @IsTest
    static void projectAndIssueLifecycle() {
        System.runAs(boardUser()) {
            Test.startTest();
            PM_Project__c project = ProjectBoardController.createProject('Test Project', 'tp', 'desc');
            System.assertEquals('TP', project.Key__c);
            System.assertEquals(1, ProjectBoardController.getProjects().size());

            PM_Issue__c first = ProjectBoardController.saveIssue(issueFields(project.Id, 'First'));
            PM_Issue__c second = ProjectBoardController.saveIssue(issueFields(project.Id, 'Second'));
            System.assertEquals('TP-1', first.Name);
            System.assertEquals('TP-2', second.Name);
            System.assertEquals('To Do', first.Status__c);
            System.assert(second.Rank__c > first.Rank__c);

            PM_Issue__c updated = ProjectBoardController.saveIssue(new Map<String, Object>{
                'Id' => first.Id, 'Status__c' => 'Done', 'Epic__c' => second.Id
            });
            System.assertEquals('Done', updated.Status__c);
            System.assertNotEquals(null, updated.Resolved_Date__c);

            ProjectBoardController.moveIssue(second.Id, 'In Progress', false, null, 0.5);

            ProjectBoardController.BoardData data = ProjectBoardController.getBoardData(project.Id);
            System.assertEquals(2, data.issues.size());
            System.assertEquals(second.Id, data.issues[0].Id, 'Lowest rank first');
            System.assertEquals(1, data.sprints.size());

            PM_Comment__c comment = ProjectBoardController.addComment(first.Id, '<p>Hello</p>');
            ProjectBoardController.IssueDetail detail = ProjectBoardController.getIssueDetail(first.Id);
            System.assertEquals(1, detail.comments.size());
            ProjectBoardController.deleteComment(comment.Id);

            ProjectBoardController.deleteIssue(second.Id);
            Test.stopTest();
            System.assertEquals(1, [SELECT COUNT() FROM PM_Issue__c]);
        }
    }

    @IsTest
    static void sprintLifecycle() {
        System.runAs(boardUser()) {
            PM_Project__c project = ProjectBoardController.createProject('Sprint Project', 'SP', null);
            PM_Sprint__c sprint1 = [SELECT Id FROM PM_Sprint__c WHERE Project__c = :project.Id];
            PM_Sprint__c sprint2 = ProjectBoardController.createSprint(project.Id);
            System.assertEquals('SP Sprint 2', sprint2.Name);

            Map<String, Object> f1 = issueFields(project.Id, 'Open');
            f1.put('Sprint__c', sprint1.Id);
            Map<String, Object> f2 = issueFields(project.Id, 'Closed');
            f2.put('Sprint__c', sprint1.Id);
            f2.put('Status__c', 'Done');
            PM_Issue__c open = ProjectBoardController.saveIssue(f1);
            ProjectBoardController.saveIssue(f2);

            Test.startTest();
            ProjectBoardController.startSprint(sprint1.Id, 'Kick-off', Date.today(), Date.today().addDays(14), 'Goal');
            Integer moved = ProjectBoardController.completeSprint(sprint1.Id, sprint2.Id);
            Test.stopTest();

            System.assertEquals(1, moved);
            System.assertEquals(sprint2.Id, [SELECT Sprint__c FROM PM_Issue__c WHERE Id = :open.Id].Sprint__c);
            System.assertEquals('Completed', [SELECT Status__c FROM PM_Sprint__c WHERE Id = :sprint1.Id].Status__c);

            ProjectBoardController.deleteSprint(sprint2.Id);
            System.assertEquals(null, [SELECT Sprint__c FROM PM_Issue__c WHERE Id = :open.Id].Sprint__c);
        }
    }

    @IsTest
    static void validationErrors() {
        System.runAs(boardUser()) {
            PM_Project__c project = ProjectBoardController.createProject('Valid', 'VAL', null);
            Integer errors = 0;
            try { ProjectBoardController.createProject('Dup', 'VAL', null); } catch (AuraHandledException e) { errors++; }
            try { ProjectBoardController.createProject('Bad', '1X', null); } catch (AuraHandledException e) { errors++; }
            try { ProjectBoardController.createProject('', 'OK', null); } catch (AuraHandledException e) { errors++; }
            try { ProjectBoardController.saveIssue(issueFields(project.Id, ' ')); } catch (AuraHandledException e) { errors++; }
            try { ProjectBoardController.saveIssue(new Map<String, Object>{ 'Summary__c' => 'x' }); } catch (AuraHandledException e) { errors++; }
            try { ProjectBoardController.addComment(null, '<p></p>'); } catch (AuraHandledException e) { errors++; }

            PM_Sprint__c sprint = [SELECT Id FROM PM_Sprint__c WHERE Project__c = :project.Id];
            try { ProjectBoardController.completeSprint(sprint.Id, null); } catch (AuraHandledException e) { errors++; }
            try { ProjectBoardController.startSprint(sprint.Id, null, Date.today(), Date.today().addDays(-1), null); } catch (AuraHandledException e) { errors++; }
            ProjectBoardController.startSprint(sprint.Id, null, Date.today(), Date.today().addDays(7), null);
            try { ProjectBoardController.deleteSprint(sprint.Id); } catch (AuraHandledException e) { errors++; }
            PM_Sprint__c other = ProjectBoardController.createSprint(project.Id);
            try { ProjectBoardController.startSprint(other.Id, null, Date.today(), Date.today().addDays(7), null); } catch (AuraHandledException e) { errors++; }
            System.assertEquals(10, errors);
        }
    }
}
