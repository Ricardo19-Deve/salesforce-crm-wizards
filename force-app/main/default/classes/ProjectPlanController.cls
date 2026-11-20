/**
 * Planning across issues and projects: dependencies (timeline), the request form and the portfolio.
 *
 * Dependencies: "A is blocked by B" is an PM_Dependency__c row with A as master. Both issues must be in the
 * same project, and a link that would close a loop (A waits for B, B waits for A) is refused.
 * Requests: a Lead opens a project to requests (Accepts_Requests__c). Anyone with the app can then file a request
 * in it, even without being a member; it lands in the backlog with Requested_By__c set and the Leads are told.
 * Portfolio: one row per project the user can see, with sprint progress, overdue and blocked work, the next
 * milestone, pending sign-offs, requests to triage and a health status.
 * Where to configure: the health rules are the constants at the top.
 * Gotchas: everything runs in user mode except filing a request and listing the requester's own requests, which go
 * through ProjectBoardSharing because the requester is usually not a member of the project.
 */
public with sharing class ProjectPlanController {

    private static final String STATUS_DONE = 'Done';
    private static final String STATUS_TODO = 'To Do';
    private static final Set<String> REQUEST_TYPES = new Set<String>{ 'Story', 'Task', 'Bug' };
    private static final Set<String> PRIORITIES = new Set<String>{ 'Highest', 'High', 'Medium', 'Low', 'Lowest' };

    /** Health: points done lagging behind time elapsed by more than these percentages. */
    private static final Integer LAG_AT_RISK = 20;
    private static final Integer LAG_OFF_TRACK = 40;

    public static final String HEALTH_ON_TRACK = 'On track';
    public static final String HEALTH_AT_RISK = 'At risk';
    public static final String HEALTH_OFF_TRACK = 'Off track';

    public class PlanException extends Exception {}

    public class DependencyInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public Id blockedId;
        @AuraEnabled public Id blockingId;
    }

    // ---------------------------------------------------------------- Dependencies

    public static List<DependencyInfo> forProject(Id projectId) {
        List<DependencyInfo> result = new List<DependencyInfo>();
        for (PM_Dependency__c d : [
            SELECT Id, Blocked_Issue__c, Blocking_Issue__c FROM PM_Dependency__c
            WHERE Blocked_Issue__r.Project__c = :projectId AND Blocking_Issue__c != null
            WITH USER_MODE
            LIMIT 5000
        ]) {
            DependencyInfo info = new DependencyInfo();
            info.id = d.Id;
            info.blockedId = d.Blocked_Issue__c;
            info.blockingId = d.Blocking_Issue__c;
            result.add(info);
        }
        return result;
    }

    @AuraEnabled
    public static DependencyInfo addDependency(Id blockedIssueId, Id blockingIssueId) {
        try {
            if (blockedIssueId == null || blockingIssueId == null) {
                throw new PlanException('Choose the issue it depends on.');
            }
            if (blockedIssueId == blockingIssueId) {
                throw new PlanException('An issue cannot depend on itself.');
            }
            Map<Id, PM_Issue__c> issues = new Map<Id, PM_Issue__c>([
                SELECT Id, Name, Project__c FROM PM_Issue__c WHERE Id IN (:blockedIssueId, :blockingIssueId) WITH USER_MODE
            ]);
            if (issues.size() != 2) {
                throw new PlanException('Issue not found.');
            }
            Id projectId = issues.get(blockedIssueId).Project__c;
            if (issues.get(blockingIssueId).Project__c != projectId) {
                throw new PlanException('Both issues must be in the same project.');
            }
            if (reaches(projectId, blockingIssueId, blockedIssueId)) {
                throw new PlanException(issues.get(blockingIssueId).Name + ' already waits for ' +
                    issues.get(blockedIssueId).Name + ': this link would create a loop.');
            }
            if ([SELECT COUNT() FROM PM_Dependency__c WHERE Blocked_Issue__c = :blockedIssueId
                    AND Blocking_Issue__c = :blockingIssueId WITH USER_MODE] > 0) {
                throw new PlanException('This dependency already exists.');
            }
            PM_Dependency__c d = new PM_Dependency__c(
                Blocked_Issue__c = blockedIssueId,
                Blocking_Issue__c = blockingIssueId,
                Dependency_Key__c = String.valueOf(blockedIssueId) + String.valueOf(blockingIssueId)
            );
            insert as user d;
            DependencyInfo info = new DependencyInfo();
            info.id = d.Id;
            info.blockedId = blockedIssueId;
            info.blockingId = blockingIssueId;
            return info;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static void removeDependency(Id dependencyId) {
        try {
            delete as user [SELECT Id FROM PM_Dependency__c WHERE Id = :dependencyId WITH USER_MODE];
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** True when `start` waits (directly or through other issues) for `target`. */
    private static Boolean reaches(Id projectId, Id start, Id target) {
        Map<Id, Set<Id>> blockers = new Map<Id, Set<Id>>();
        for (DependencyInfo d : forProject(projectId)) {
            if (!blockers.containsKey(d.blockedId)) {
                blockers.put(d.blockedId, new Set<Id>());
            }
            blockers.get(d.blockedId).add(d.blockingId);
        }
        Set<Id> seen = new Set<Id>();
        List<Id> queue = new List<Id>{ start };
        while (!queue.isEmpty()) {
            Id current = queue.remove(0);
            if (current == target) {
                return true;
            }
            if (seen.add(current) && blockers.containsKey(current)) {
                queue.addAll(blockers.get(current));
            }
        }
        return false;
    }

    // ---------------------------------------------------------------- Requests

    public class RequestContext {
        @AuraEnabled public List<ProjectOption> projects = new List<ProjectOption>();
        @AuraEnabled public List<RequestInfo> mine = new List<RequestInfo>();
    }

    public class ProjectOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String key;
    }

    public class RequestInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public String key;
        @AuraEnabled public String summary;
        @AuraEnabled public String status;
        @AuraEnabled public String type;
        @AuraEnabled public String priority;
        @AuraEnabled public Id projectId;
        @AuraEnabled public String projectName;
        @AuraEnabled public String assigneeName;
        @AuraEnabled public String sprintName;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Datetime lastModifiedDate;
    }

    @AuraEnabled
    public static RequestContext getRequestContext() {
        try {
            RequestContext ctx = new RequestContext();
            for (PM_Project__c p : ProjectBoardSharing.requestableProjects()) {
                ProjectOption o = new ProjectOption();
                o.id = p.Id;
                o.name = p.Name;
                o.key = p.Key__c;
                ctx.projects.add(o);
            }
            for (PM_Issue__c i : ProjectBoardSharing.requestsOf(UserInfo.getUserId())) {
                ctx.mine.add(toRequestInfo(i));
            }
            return ctx;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    @AuraEnabled
    public static RequestInfo submitRequest(Id projectId, String summary, String description, String type, String priority) {
        try {
            if (projectId == null) {
                throw new PlanException('Choose the project the request is for.');
            }
            if (String.isBlank(summary)) {
                throw new PlanException('Describe the request in one line.');
            }
            if (summary.trim().length() > 255) {
                throw new PlanException('Keep the summary under 255 characters; add the details in the description.');
            }
            String issueType = REQUEST_TYPES.contains(type) ? type : 'Task';
            String issuePriority = PRIORITIES.contains(priority) ? priority : 'Medium';
            PM_Issue__c rec = new PM_Issue__c(
                Summary__c = summary.trim(),
                Description__c = description,
                Type__c = issueType,
                Priority__c = issuePriority,
                Status__c = STATUS_TODO,
                Reporter__c = UserInfo.getUserId(),
                Requested_By__c = UserInfo.getUserId()
            );
            ProjectBoardSharing.insertRequest(rec, projectId);

            Map<Id, String> roles = ProjectBoardSharing.memberRoles(new Set<Id>{ projectId }).get(projectId);
            List<ProjectActivityController.Item> items = new List<ProjectActivityController.Item>();
            for (Id userId : roles == null ? new Set<Id>() : roles.keySet()) {
                if (roles.get(userId) == ProjectBoardSharing.ROLE_LEAD) {
                    items.add(new ProjectActivityController.Item(userId, ProjectActivityController.TYPE_REQUEST, rec,
                        'New request from ' + UserInfo.getName() + ': ' + ProjectActivityController.label(rec)));
                }
            }
            try {
                ProjectActivityController.deliver(items);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Request notification not sent: ' + e.getMessage());
            }
            for (PM_Issue__c i : ProjectBoardSharing.requestsOf(UserInfo.getUserId())) {
                if (i.Id == rec.Id) {
                    return toRequestInfo(i);
                }
            }
            return null;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Leads open or close their project to requests. */
    @AuraEnabled
    public static void setAcceptsRequests(Id projectId, Boolean accepts) {
        try {
            if (!ProjectBoardController.accessFor(projectId).canManage) {
                throw new PlanException('Only project leads can change this.');
            }
            update as user new PM_Project__c(Id = projectId, Accepts_Requests__c = accepts == true);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static RequestInfo toRequestInfo(PM_Issue__c i) {
        RequestInfo r = new RequestInfo();
        r.id = i.Id;
        r.key = i.Name;
        r.summary = i.Summary__c;
        r.status = i.Status__c;
        r.type = i.Type__c;
        r.priority = i.Priority__c;
        r.projectId = i.Project__c;
        r.projectName = i.Project__r == null ? null : i.Project__r.Name;
        r.assigneeName = i.Assignee__r == null ? null : i.Assignee__r.Name;
        r.sprintName = i.Sprint__r == null ? null : i.Sprint__r.Name;
        r.createdDate = i.CreatedDate;
        r.lastModifiedDate = i.LastModifiedDate;
        return r;
    }

    // ---------------------------------------------------------------- Portfolio

    public class PortfolioRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String key;
        @AuraEnabled public String myRole;
        @AuraEnabled public List<String> leads = new List<String>();
        @AuraEnabled public Integer members = 0;
        @AuraEnabled public String sprintName;
        @AuraEnabled public Date sprintStart;
        @AuraEnabled public Date sprintEnd;
        @AuraEnabled public Decimal sprintPoints = 0;
        @AuraEnabled public Decimal sprintDone = 0;
        @AuraEnabled public Integer progress;
        @AuraEnabled public Integer timeElapsed;
        @AuraEnabled public Integer open = 0;
        @AuraEnabled public Integer overdue = 0;
        @AuraEnabled public Integer blocked = 0;
        @AuraEnabled public Integer requests = 0;
        @AuraEnabled public Integer signOffsPending = 0;
        @AuraEnabled public String milestoneKey;
        @AuraEnabled public String milestoneName;
        @AuraEnabled public Date milestoneDate;
        @AuraEnabled public Boolean milestoneLate = false;
        @AuraEnabled public String health;
        @AuraEnabled public List<String> reasons = new List<String>();
    }

    @AuraEnabled
    public static List<PortfolioRow> getPortfolio() {
        try {
            Date today = Date.today();
            Id me = UserInfo.getUserId();
            Map<Id, PortfolioRow> rows = new Map<Id, PortfolioRow>();
            for (PM_Project__c p : [
                SELECT Id, Name, Key__c FROM PM_Project__c WITH USER_MODE ORDER BY Name LIMIT 200
            ]) {
                PortfolioRow r = new PortfolioRow();
                r.id = p.Id;
                r.name = p.Name;
                r.key = p.Key__c;
                rows.put(p.Id, r);
            }
            if (rows.isEmpty()) {
                return new List<PortfolioRow>();
            }
            Set<Id> ids = rows.keySet();

            for (PM_Project_Member__c m : [
                SELECT Project__c, User__c, User__r.Name, Role__c FROM PM_Project_Member__c
                WHERE Project__c IN :ids WITH USER_MODE ORDER BY User__r.Name
            ]) {
                PortfolioRow r = rows.get(m.Project__c);
                r.members++;
                if (m.Role__c == ProjectBoardSharing.ROLE_LEAD && m.User__r != null) {
                    r.leads.add(m.User__r.Name);
                }
                if (m.User__c == me) {
                    r.myRole = m.Role__c;
                }
            }

            Map<Id, Id> activeSprint = new Map<Id, Id>();
            for (PM_Sprint__c s : [
                SELECT Id, Name, Project__c, Start_Date__c, End_Date__c FROM PM_Sprint__c
                WHERE Project__c IN :ids AND Status__c = 'Active' WITH USER_MODE
            ]) {
                PortfolioRow r = rows.get(s.Project__c);
                r.sprintName = s.Name;
                r.sprintStart = s.Start_Date__c;
                r.sprintEnd = s.End_Date__c;
                activeSprint.put(s.Id, s.Project__c);
            }
            if (!activeSprint.isEmpty()) {
                for (AggregateResult ar : [
                    SELECT Sprint__c sprint, Status__c status, SUM(Story_Points__c) points FROM PM_Issue__c
                    WHERE Sprint__c IN :activeSprint.keySet() AND Type__c != 'Epic'
                    WITH USER_MODE GROUP BY Sprint__c, Status__c
                ]) {
                    PortfolioRow r = rows.get(activeSprint.get((Id) ar.get('sprint')));
                    Decimal points = ar.get('points') == null ? 0 : (Decimal) ar.get('points');
                    r.sprintPoints += points;
                    if ((String) ar.get('status') == STATUS_DONE) {
                        r.sprintDone += points;
                    }
                }
            }

            for (AggregateResult ar : [
                SELECT Project__c project, COUNT(Id) total FROM PM_Issue__c
                WHERE Project__c IN :ids AND Status__c != :STATUS_DONE AND Type__c != 'Epic'
                WITH USER_MODE GROUP BY Project__c
            ]) {
                rows.get((Id) ar.get('project')).open = (Integer) ar.get('total');
            }
            for (AggregateResult ar : [
                SELECT Project__c project, COUNT(Id) total FROM PM_Issue__c
                WHERE Project__c IN :ids AND Status__c != :STATUS_DONE AND Due_Date__c < :today
                WITH USER_MODE GROUP BY Project__c
            ]) {
                rows.get((Id) ar.get('project')).overdue = (Integer) ar.get('total');
            }
            for (AggregateResult ar : [
                SELECT Project__c project, COUNT(Id) total FROM PM_Issue__c
                WHERE Project__c IN :ids AND Requested_By__c != null AND Sprint__c = null AND Status__c = :STATUS_TODO
                WITH USER_MODE GROUP BY Project__c
            ]) {
                rows.get((Id) ar.get('project')).requests = (Integer) ar.get('total');
            }

            Map<Id, Set<Id>> blockedByProject = new Map<Id, Set<Id>>();
            for (PM_Dependency__c d : [
                SELECT Blocked_Issue__c, Blocked_Issue__r.Project__c FROM PM_Dependency__c
                WHERE Blocked_Issue__r.Project__c IN :ids AND Blocked_Issue__r.Status__c != :STATUS_DONE
                    AND Blocking_Issue__c != null AND Blocking_Issue__r.Status__c != :STATUS_DONE
                WITH USER_MODE LIMIT 5000
            ]) {
                Id projectId = d.Blocked_Issue__r.Project__c;
                if (!blockedByProject.containsKey(projectId)) {
                    blockedByProject.put(projectId, new Set<Id>());
                }
                blockedByProject.get(projectId).add(d.Blocked_Issue__c);
            }
            for (Id projectId : blockedByProject.keySet()) {
                rows.get(projectId).blocked = blockedByProject.get(projectId).size();
            }

            for (PM_Issue__c m : [
                SELECT Project__c, Name, Summary__c, Due_Date__c FROM PM_Issue__c
                WHERE Project__c IN :ids AND Milestone__c = true AND Status__c != :STATUS_DONE AND Due_Date__c != null
                WITH USER_MODE ORDER BY Due_Date__c LIMIT 2000
            ]) {
                PortfolioRow r = rows.get(m.Project__c);
                if (r.milestoneDate == null) {
                    r.milestoneKey = m.Name;
                    r.milestoneName = m.Summary__c;
                    r.milestoneDate = m.Due_Date__c;
                    r.milestoneLate = m.Due_Date__c < today;
                }
            }

            for (AggregateResult ar : [
                SELECT Issue__r.Project__c project, COUNT(Id) total FROM PM_BRD__c
                WHERE Issue__r.Project__c IN :ids AND Status__c = 'Sent for Approval'
                WITH USER_MODE GROUP BY Issue__r.Project__c
            ]) {
                rows.get((Id) ar.get('project')).signOffsPending = (Integer) ar.get('total');
            }

            for (PortfolioRow r : rows.values()) {
                assess(r, today);
            }
            return rows.values();
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Progress, time elapsed and health with the reasons behind it. */
    @TestVisible
    private static void assess(PortfolioRow r, Date today) {
        Integer lag = 0;
        if (r.sprintName != null) {
            r.progress = r.sprintPoints > 0 ? percent(r.sprintDone, r.sprintPoints) : 0;
            if (r.sprintStart != null && r.sprintEnd != null) {
                Integer total = Math.max(1, r.sprintStart.daysBetween(r.sprintEnd));
                Integer passed = Math.min(total, Math.max(0, r.sprintStart.daysBetween(today)));
                r.timeElapsed = percent(passed, total);
                lag = r.timeElapsed - r.progress;
                if (r.sprintEnd < today) {
                    r.reasons.add('The sprint ended on ' + r.sprintEnd.format() + ' and is still open');
                    lag = Math.max(lag, LAG_OFF_TRACK + 1);
                } else if (lag > LAG_AT_RISK) {
                    r.reasons.add('Work done is ' + lag + '% behind the sprint calendar');
                }
            }
        }
        if (r.milestoneLate) {
            r.reasons.add('Milestone ' + r.milestoneKey + ' is past its date');
        }
        if (r.overdue > 0) {
            r.reasons.add(r.overdue + (r.overdue == 1 ? ' issue is' : ' issues are') + ' overdue');
        }
        if (r.blocked > 0) {
            r.reasons.add(r.blocked + (r.blocked == 1 ? ' issue is' : ' issues are') + ' blocked');
        }
        if (r.milestoneLate || lag > LAG_OFF_TRACK) {
            r.health = HEALTH_OFF_TRACK;
        } else if (lag > LAG_AT_RISK || r.overdue > 0 || r.blocked > 0) {
            r.health = HEALTH_AT_RISK;
        } else {
            r.health = HEALTH_ON_TRACK;
        }
    }

    private static Integer percent(Decimal part, Decimal total) {
        return (part * 100 / total).setScale(0, System.RoundingMode.HALF_UP).intValue();
    }

    private static AuraHandledException auraError(Exception e) {
        String message = e instanceof DmlException ? ((DmlException) e).getDmlMessage(0) : e.getMessage();
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
