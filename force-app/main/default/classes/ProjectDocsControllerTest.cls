@IsTest
private class ProjectDocsControllerTest {


    private static User boardUser() {
        User u = new User(
            Alias = 'pbdocs',
            Email = 'board.docs@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Board Docs',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'Europe/Lisbon',
            Username = 'board.docs.' + System.currentTimeMillis() + '@example.com.test'
        );
        insert u;
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Project_Board_User'];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    private static PM_Issue__c newIssue(Id projectId, Id sprintId, String status) {
        return ProjectBoardController.saveIssue(new Map<String, Object>{
            'Project__c' => projectId,
            'Summary__c' => 'Case automation small enhancements',
            'Description__c' => '<p>Pocket CX new order emails are not auto closed</p><p>UK bookings reopen</p>',
            'Status__c' => status,
            'Sprint__c' => sprintId,
            'Story_Points__c' => 3
        });
    }

    @IsTest
    static void brdTestScriptsAndExports() {
        System.runAs(boardUser()) {
            PM_Project__c project = ProjectBoardController.createProject('Docs', 'DOC', null);
            PM_Sprint__c sprint = [SELECT Id FROM PM_Sprint__c WHERE Project__c = :project.Id];
            PM_Issue__c issue = newIssue(project.Id, sprint.Id, 'To Do');
            newIssue(project.Id, sprint.Id, 'Done');

            Test.startTest();
            // BRD pre-filled from the issue
            PM_BRD__c brd = ProjectDocsController.createBrd(issue.Id);
            System.assertEquals('DOC-1', brd.PBI_ID__c);
            System.assertEquals(1, brd.Requirements__r.size());
            System.assert(brd.Requirements__r[0].Requirement__c.contains('UK bookings reopen'));

            ProjectDocsController.saveBrd(new Map<String, Object>{
                'Id' => brd.Id, 'Business_Analyst__c' => 'Ana', 'Initiator_Date__c' => '2025-04-11'
            });
            PM_Requirement__c req2 = ProjectDocsController.addRequirement(brd.Id);
            System.assertEquals('BRD0002', req2.Name);
            ProjectDocsController.saveRequirement(new Map<String, Object>{
                'Id' => brd.Requirements__r[0].Id,
                'Acceptance_Criteria__c' => '• Cases update with the correct values\n• UK cases are reopened',
                'Solution__c' => 'Update flow Automatic Case Reopening'
            });

            // Test scripts generated from acceptance criteria
            System.assertEquals(2, ProjectDocsController.generateTestCasesFromBrd(issue.Id));
            PM_Test_Case__c manual = ProjectDocsController.saveTestCase(new Map<String, Object>{
                'Issue__c' => issue.Id, 'Title__c' => 'Manual test'
            });
            System.assertEquals('TC-003', manual.Name);
            PM_Test_Case__c passed = ProjectDocsController.saveTestCase(new Map<String, Object>{
                'Id' => manual.Id, 'Status__c' => 'Pass'
            });
            System.assertEquals(UserInfo.getUserId(), passed.Tested_By__c);
            System.assertEquals(3, ProjectDocsController.getTestCases(issue.Id).size());

            // Exports
            Test.setCurrentPage(Page.ProjectBrdExport);
            ApexPages.currentPage().getParameters().put('id', brd.Id);
            ProjectExportController brdExport = new ProjectExportController();
            brdExport.initBrd();
            System.assertEquals(2, brdExport.requirements.size());
            System.assertEquals('pdf', brdExport.renderAs);

            Test.setCurrentPage(Page.ProjectTestScriptExport);
            ApexPages.currentPage().getParameters().put('id', issue.Id);
            ApexPages.currentPage().getParameters().put('format', 'word');
            ProjectExportController testExport = new ProjectExportController();
            testExport.initTestScripts();
            System.assertEquals(3, testExport.testCounts.get('Total'));
            System.assert(testExport.contentType.startsWith('application/msword'));

            ProjectBoardController.startSprint(sprint.Id, null, Date.today(), Date.today().addDays(14), 'Goal');
            ProjectBoardController.completeSprint(sprint.Id, null);
            Test.setCurrentPage(Page.ProjectSprintReport);
            ApexPages.currentPage().getParameters().put('id', sprint.Id);
            ProjectExportController report = new ProjectExportController();
            report.initSprintReport();
            System.assertEquals(1, report.deliveredIssues);
            System.assertEquals(1, report.notDelivered.size(), 'Carried-over snapshot is used');
            System.assertEquals(2, report.committedIssues);
            System.assertEquals(50, report.completionPct);

            // Board stats
            ProjectBoardController.BoardData data = ProjectBoardController.getBoardData(project.Id);
            System.assertEquals(true, data.stats.get(issue.Id).hasBrd);
            System.assertEquals(3, data.stats.get(issue.Id).tests);

            ProjectDocsController.deleteTestCase(manual.Id);
            ProjectDocsController.deleteRequirement(req2.Id);
            ProjectBoardController.deleteIssue(issue.Id);
            Test.stopTest();
            System.assertEquals(0, [SELECT COUNT() FROM PM_BRD__c]);
        }
    }

    @IsTest
    static void filesAndValidation() {
        System.runAs(boardUser()) {
            PM_Project__c project = ProjectBoardController.createProject('Files', 'FIL', null);
            PM_Issue__c issue = newIssue(project.Id, null, 'To Do');

            ContentVersion cv = new ContentVersion(
                Title = 'Screenshot', PathOnClient = 'shot.png', VersionData = Blob.valueOf('png'),
                FirstPublishLocationId = issue.Id
            );
            insert cv;
            List<ProjectDocsController.FileInfo> files = ProjectDocsController.getFiles(issue.Id);
            System.assertEquals(1, files.size());
            System.assertEquals(true, files[0].canDelete);
            ProjectDocsController.deleteFile(files[0].documentId);
            System.assertEquals(0, ProjectDocsController.getFiles(issue.Id).size());

            Integer errors = 0;
            try { ProjectDocsController.generateTestCasesFromBrd(issue.Id); } catch (AuraHandledException e) { errors++; }
            PM_BRD__c brd = ProjectDocsController.createBrd(issue.Id);
            try { ProjectDocsController.createBrd(issue.Id); } catch (AuraHandledException e) { errors++; }
            try { ProjectDocsController.generateTestCasesFromBrd(issue.Id); } catch (AuraHandledException e) { errors++; }
            try { ProjectDocsController.saveBrd(new Map<String, Object>{ 'Id' => brd.Id, 'Name' => '' }); } catch (AuraHandledException e) { errors++; }
            System.assertEquals(4, errors);
            ProjectDocsController.deleteBrd(brd.Id);
            System.assertEquals(null, ProjectDocsController.getBrd(issue.Id));
            System.assertEquals('a\nb', ProjectDocsController.htmlToLines('<ul><li>a</li><li>b</li></ul>'));
        }
    }
}
