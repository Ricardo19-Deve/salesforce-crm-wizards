/**
 * Backs the printable exports of the projectBoardApp (PDF via renderAs, Word via an HTML .doc):
 *   ProjectBrdExport?id=<BRD Id>&format=pdf|word
 *   ProjectTestScriptExport?id=<Issue Id>&format=pdf|word
 *   ProjectSprintReport?id=<Sprint Id>&format=pdf|word
 */
public with sharing class ProjectExportController {

    /** Optional logo: upload an image as a Static Resource with this name to show it on every export. */
    public static final String LOGO_RESOURCE = 'Project_Board_Logo';
    private static final Set<String> IMAGE_TYPES = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif' };
    private static final Integer MAX_IMAGE_BYTES = 3000000;

    public String format { get; private set; }
    public String fileName { get; private set; }
    public String logoUrl { get; private set; }
    public String generatedOn { get; private set; }
    public String generatedBy { get; private set; }

    public Boolean isWord {
        get { return format == 'word'; }
    }
    public String renderAs {
        get { return isWord ? null : 'pdf'; }
    }
    public String contentType {
        get { return isWord ? 'application/msword#' + fileName + '.doc' : 'text/html'; }
    }

    // ---- BRD
    public PM_BRD__c brd { get; private set; }
    public List<RequirementView> requirements { get; private set; }
    public List<String> systems { get; private set; }
    public List<ImageView> images { get; private set; }

    // ---- Test scripts
    public PM_Issue__c issue { get; private set; }
    public String pbiId { get; private set; }
    public List<TestView> tests { get; private set; }
    public Map<String, Integer> testCounts { get; private set; }

    // ---- Sprint report
    public PM_Sprint__c sprint { get; private set; }
    public PM_Project__c project { get; private set; }
    public List<EpicGroup> deliveredGroups { get; private set; }
    public List<IssueRow> notDelivered { get; private set; }
    public List<PM_BRD__c> sprintBrds { get; private set; }
    public Integer committedIssues { get; private set; }
    public Decimal committedPoints { get; private set; }
    public Integer deliveredIssues { get; private set; }
    public Decimal deliveredPoints { get; private set; }
    public Integer completionPct { get; private set; }
    public Integer bugsFixed { get; private set; }
    public Integer testsTotal { get; private set; }
    public Integer testsPassed { get; private set; }
    public Integer testPassPct { get; private set; }
    public String sprintDates { get; private set; }
    public Boolean hasNotDelivered {
        get { return notDelivered != null && !notDelivered.isEmpty(); }
    }
    public Boolean hasBrds {
        get { return sprintBrds != null && !sprintBrds.isEmpty(); }
    }

    public class RequirementView {
        public String num { get; set; }
        public List<String> requirementLines { get; set; }
        public List<String> criteriaLines { get; set; }
        public String systems { get; set; }
        public List<String> infoLines { get; set; }
        public List<String> solutionLines { get; set; }
        public String solutionSystems { get; set; }
    }

    public class ImageView {
        public String title { get; set; }
        public String dataUri { get; set; }
    }

    public class StepView {
        public Integer num { get; set; }
        public String action { get; set; }
        public String expected { get; set; }
        public String actual { get; set; }
    }

    public class TestView {
        public PM_Test_Case__c record { get; set; }
        public List<StepView> steps { get; set; }
        public List<String> preconditionLines { get; set; }
        public List<String> testDataLines { get; set; }
        public String statusClass { get; set; }
        public String testedOn { get; set; }
    }

    public class IssueRow {
        public String key { get; set; }
        public String summary { get; set; }
        public String type { get; set; }
        public String status { get; set; }
        public String assignee { get; set; }
        public Decimal points { get; set; }
        public String tests { get; set; }
    }

    public class EpicGroup {
        public String name { get; set; }
        public Decimal points { get; set; }
        public List<IssueRow> rows { get; set; }
    }

    public ProjectExportController() {
        format = ApexPages.currentPage().getParameters().get('format') == 'word' ? 'word' : 'pdf';
        generatedOn = Datetime.now().format('dd/MM/yyyy HH:mm');
        generatedBy = UserInfo.getName();
        List<StaticResource> logo = [
            SELECT Name, SystemModstamp FROM StaticResource WHERE Name = :LOGO_RESOURCE LIMIT 1
        ];
        if (!logo.isEmpty()) {
            logoUrl = sitePrefix() + '/resource/' + logo[0].SystemModstamp.getTime() + '/' + LOGO_RESOURCE;
        }
    }

    private Id recordIdParam() {
        return Id.valueOf(ApexPages.currentPage().getParameters().get('id'));
    }

    private void setFileName(String name) {
        fileName = name.replaceAll('[^A-Za-z0-9_\\- ]', '').trim().replace(' ', '_');
        if (!isWord) {
            ApexPages.currentPage().getHeaders().put('Content-Disposition', 'inline; filename="' + fileName + '.pdf"');
        }
    }

    // ---------------------------------------------------------------- BRD

    public PageReference initBrd() {
        Id brdId = recordIdParam();
        brd = [
            SELECT Id, Name, PBI_ID__c, Business_Area__c, Status__c, Version__c, Business_Analyst__c,
                Business_Requestor__c, Impacted_Users__c, Systems_Impacted__c, Initiator_Name__c, Initiator_Date__c,
                IT_Approver_Name__c, IT_Approver_Date__c, Architect_Approver_Name__c, Architect_Approver_Date__c,
                Solution_Designer_Name__c, Solution_Designer_Date__c, Solution_Reviewer_Name__c, Solution_Reviewer_Date__c,
                (SELECT Name, Requirement__c, Acceptance_Criteria__c, Systems_Impacted__c, Additional_Info__c,
                    Solution__c, Solution_Systems__c
                 FROM Requirements__r ORDER BY Sequence__c)
            FROM PM_BRD__c
            WHERE Id = :brdId
            WITH USER_MODE
        ];
        systems = ProjectDocsController.splitLines(String.isBlank(brd.Systems_Impacted__c) ? null : brd.Systems_Impacted__c.replace(',', '\n'));
        requirements = new List<RequirementView>();
        for (PM_Requirement__c r : brd.Requirements__r) {
            RequirementView v = new RequirementView();
            v.num = r.Name;
            v.requirementLines = ProjectDocsController.splitLines(r.Requirement__c);
            v.criteriaLines = ProjectDocsController.splitLines(r.Acceptance_Criteria__c);
            v.systems = r.Systems_Impacted__c;
            v.infoLines = ProjectDocsController.splitLines(r.Additional_Info__c);
            v.solutionLines = ProjectDocsController.splitLines(r.Solution__c);
            v.solutionSystems = r.Solution_Systems__c;
            requirements.add(v);
        }
        images = isWord ? new List<ImageView>() : loadImages(brd.Id);
        setFileName('BRD ' + (String.isBlank(brd.PBI_ID__c) ? '' : brd.PBI_ID__c + ' ') + brd.Name);
        return null;
    }

    private List<ImageView> loadImages(Id recordId) {
        List<ImageView> result = new List<ImageView>();
        Set<Id> versionIds = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocument.LatestPublishedVersionId, ContentDocument.FileExtension
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
        ]) {
            String ext = link.ContentDocument.FileExtension == null ? '' : link.ContentDocument.FileExtension.toLowerCase();
            if (IMAGE_TYPES.contains(ext)) {
                versionIds.add(link.ContentDocument.LatestPublishedVersionId);
            }
        }
        Integer budget = MAX_IMAGE_BYTES;
        for (ContentVersion v : [
            SELECT Title, FileExtension, ContentSize, VersionData
            FROM ContentVersion
            WHERE Id IN :versionIds
            ORDER BY CreatedDate
        ]) {
            if (v.ContentSize > budget) {
                continue;
            }
            budget -= v.ContentSize;
            ImageView img = new ImageView();
            img.title = v.Title;
            String mime = v.FileExtension.toLowerCase() == 'jpg' ? 'jpeg' : v.FileExtension.toLowerCase();
            img.dataUri = 'data:image/' + mime + ';base64,' + EncodingUtil.base64Encode(v.VersionData);
            result.add(img);
        }
        return result;
    }

    // ---------------------------------------------------------------- Test scripts

    public PageReference initTestScripts() {
        Id issueId = recordIdParam();
        issue = [
            SELECT Id, Name, Summary__c, Project__r.Name, Assignee__r.Name
            FROM PM_Issue__c
            WHERE Id = :issueId
            WITH USER_MODE
        ];
        List<PM_BRD__c> brds = [SELECT PBI_ID__c FROM PM_BRD__c WHERE Issue__c = :issueId WITH USER_MODE LIMIT 1];
        pbiId = brds.isEmpty() || String.isBlank(brds[0].PBI_ID__c) ? issue.Name : brds[0].PBI_ID__c;

        testCounts = new Map<String, Integer>{ 'Pass' => 0, 'Fail' => 0, 'Blocked' => 0, 'Not Run' => 0, 'Total' => 0 };
        tests = new List<TestView>();
        for (PM_Test_Case__c tc : [
            SELECT Name, Title__c, Requirement__r.Name, Preconditions__c, Test_Data__c, Steps__c, Status__c,
                Tested_By__r.Name, Tested_Date__c, Comments__c
            FROM PM_Test_Case__c
            WHERE Issue__c = :issueId
            WITH USER_MODE
            ORDER BY Sequence__c
        ]) {
            TestView v = new TestView();
            v.record = tc;
            v.steps = parseSteps(tc.Steps__c);
            v.preconditionLines = ProjectDocsController.splitLines(tc.Preconditions__c);
            v.testDataLines = ProjectDocsController.splitLines(tc.Test_Data__c);
            String status = tc.Status__c == null ? 'Not Run' : tc.Status__c;
            v.statusClass = 'status status-' + status.toLowerCase().replace(' ', '-');
            v.testedOn = tc.Tested_Date__c == null ? '' : Datetime.newInstance(tc.Tested_Date__c, Time.newInstance(0, 0, 0, 0)).format('dd/MM/yyyy');
            tests.add(v);
            testCounts.put(status, testCounts.get(status) + 1);
            testCounts.put('Total', testCounts.get('Total') + 1);
        }
        setFileName('Test Scripts ' + issue.Name);
        return null;
    }

    public static List<StepView> parseSteps(String stepsJson) {
        List<StepView> steps = new List<StepView>();
        if (String.isBlank(stepsJson)) {
            return steps;
        }
        Integer num = 0;
        for (Object o : (List<Object>) System.JSON.deserializeUntyped(stepsJson)) {
            Map<String, Object> m = (Map<String, Object>) o;
            StepView s = new StepView();
            s.num = ++num;
            s.action = (String) m.get('action');
            s.expected = (String) m.get('expected');
            s.actual = (String) m.get('actual');
            steps.add(s);
        }
        return steps;
    }

    // ---------------------------------------------------------------- Sprint report

    public PageReference initSprintReport() {
        Id sprintId = recordIdParam();
        sprint = [
            SELECT Id, Name, Status__c, Start_Date__c, End_Date__c, Completed_Date__c, Goal__c, Project__c,
                Committed_Issues__c, Committed_Points__c, Carried_Over__c
            FROM PM_Sprint__c
            WHERE Id = :sprintId
            WITH USER_MODE
        ];
        project = [SELECT Id, Name, Key__c FROM PM_Project__c WHERE Id = :sprint.Project__c WITH USER_MODE];
        sprintDates = formatDate(sprint.Start_Date__c) + ' – ' + formatDate(sprint.End_Date__c);

        List<PM_Issue__c> sprintIssues = [
            SELECT Id, Name, Summary__c, Type__c, Status__c, Story_Points__c, Assignee__r.Name,
                Epic__c, Epic__r.Name, Epic__r.Summary__c
            FROM PM_Issue__c
            WHERE Sprint__c = :sprintId AND Type__c != 'Epic'
            WITH USER_MODE
            ORDER BY Rank__c
        ];
        Map<Id, ProjectBoardController.IssueStats> stats = ProjectBoardController.buildStats(
            new Map<Id, PM_Issue__c>(sprintIssues).keySet()
        );

        Map<String, EpicGroup> groups = new Map<String, EpicGroup>();
        notDelivered = new List<IssueRow>();
        deliveredIssues = 0;
        deliveredPoints = 0;
        bugsFixed = 0;
        testsTotal = 0;
        testsPassed = 0;
        Decimal openPoints = 0;
        for (PM_Issue__c i : sprintIssues) {
            ProjectBoardController.IssueStats st = stats.get(i.Id);
            testsTotal += st.tests;
            testsPassed += st.testsPassed;
            IssueRow row = toRow(i, st);
            if (i.Status__c == 'Done') {
                deliveredIssues++;
                deliveredPoints += row.points == null ? 0 : row.points;
                if (i.Type__c == 'Bug') {
                    bugsFixed++;
                }
                String groupName = i.Epic__c == null ? 'No epic' : i.Epic__r.Name + ' · ' + i.Epic__r.Summary__c;
                if (!groups.containsKey(groupName)) {
                    EpicGroup g = new EpicGroup();
                    g.name = groupName;
                    g.points = 0;
                    g.rows = new List<IssueRow>();
                    groups.put(groupName, g);
                }
                groups.get(groupName).rows.add(row);
                groups.get(groupName).points += row.points == null ? 0 : row.points;
            } else {
                notDelivered.add(row);
                openPoints += row.points == null ? 0 : row.points;
            }
        }
        // Completed sprints: open issues already moved out - use the snapshot taken at completion
        if (sprint.Status__c == 'Completed' && String.isNotBlank(sprint.Carried_Over__c)) {
            for (Object o : (List<Object>) System.JSON.deserializeUntyped(sprint.Carried_Over__c)) {
                Map<String, Object> m = (Map<String, Object>) o;
                IssueRow row = new IssueRow();
                row.key = (String) m.get('key');
                row.summary = (String) m.get('summary');
                row.type = (String) m.get('type');
                row.status = (String) m.get('status');
                row.assignee = (String) m.get('assignee');
                row.points = m.get('points') == null ? null : Decimal.valueOf(String.valueOf(m.get('points')));
                notDelivered.add(row);
                openPoints += row.points == null ? 0 : row.points;
            }
        }
        deliveredGroups = groups.values();

        committedIssues = sprint.Committed_Issues__c != null
            ? sprint.Committed_Issues__c.intValue()
            : deliveredIssues + notDelivered.size();
        committedPoints = sprint.Committed_Points__c != null ? sprint.Committed_Points__c : deliveredPoints + openPoints;
        if (committedPoints > 0) {
            completionPct = Math.min(100, (deliveredPoints * 100 / committedPoints).round(System.RoundingMode.HALF_UP).intValue());
        } else {
            completionPct = committedIssues > 0 ? Math.min(100, deliveredIssues * 100 / committedIssues) : 0;
        }
        testPassPct = testsTotal > 0 ? testsPassed * 100 / testsTotal : 0;

        sprintBrds = [
            SELECT Name, PBI_ID__c, Status__c, Version__c, Issue__r.Name
            FROM PM_BRD__c
            WHERE Issue__c IN :sprintIssues
            WITH USER_MODE
            ORDER BY PBI_ID__c
        ];
        setFileName('Sprint Report ' + sprint.Name);
        return null;
    }

    private static IssueRow toRow(PM_Issue__c i, ProjectBoardController.IssueStats st) {
        IssueRow row = new IssueRow();
        row.key = i.Name;
        row.summary = i.Summary__c;
        row.type = i.Type__c;
        row.status = i.Status__c;
        row.assignee = i.Assignee__r == null ? '' : i.Assignee__r.Name;
        row.points = i.Story_Points__c;
        row.tests = st == null || st.tests == 0 ? '—' : st.testsPassed + '/' + st.tests;
        return row;
    }

    private static String formatDate(Date d) {
        return d == null ? '—' : Datetime.newInstance(d, Time.newInstance(0, 0, 0, 0)).format('dd MMM yyyy');
    }

    private static String sitePrefix() {
        String prefix = Site.getPathPrefix();
        return prefix == null ? '' : prefix;
    }
}
