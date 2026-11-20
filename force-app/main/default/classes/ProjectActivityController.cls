/**
 * Followers, @mentions and notifications of the project board.
 *
 * Who is told what:
 *  - Assigned:   the new assignee (unless they assigned themselves).
 *  - Mentioned:  members named as "@Full Name" in a comment.
 *  - Commented:  followers of the issue.
 *  - Status:     followers of the issue, and the requester when the issue came in through the request form.
 *  - Request:    the Leads of the project when a request arrives.
 *  - Sign-off:   approvers and BRD owners (sent by ProjectDocsController).
 * The person who did the action is never notified, and each person gets one notification per issue and action.
 * Every notification lands in the in-app inbox (PM_Notification__c, owned by the recipient) and in the
 * Salesforce bell.
 *
 * Followers: the reporter, the assignee, commenters and mentioned members follow automatically; anyone who can
 * see the issue can follow or unfollow it.
 * Where: called by ProjectBoardController (issues, comments), ProjectPlanController (requests) and
 * ProjectDocsController (sign-off); the inbox and the follow button call the @AuraEnabled methods.
 * Gotchas: only project members are notified about an issue (people removed from a project stop hearing about
 * it), except the requester of a request. Notifications never block the action that caused them.
 */
public with sharing class ProjectActivityController {

    public static final String TYPE_ASSIGNED = 'Assigned';
    public static final String TYPE_MENTIONED = 'Mentioned';
    public static final String TYPE_COMMENTED = 'Commented';
    public static final String TYPE_STATUS = 'Status';
    public static final String TYPE_REQUEST = 'Request';
    public static final String TYPE_SIGN_OFF = 'Sign-off';

    private static final String BELL_ACTIVITY = 'Project_Board_Activity';
    private static final String BELL_SIGN_OFF = 'Project_Board_Sign_Off';
    private static final String APP_TAB = 'Project_Board';
    private static final Integer INBOX_SIZE = 40;

    /** When the same person is concerned twice by one action, the most specific reason wins. */
    private static final Map<String, Integer> PRIORITY = new Map<String, Integer>{
        TYPE_MENTIONED => 5, TYPE_ASSIGNED => 4, TYPE_SIGN_OFF => 3, TYPE_REQUEST => 3, TYPE_STATUS => 2, TYPE_COMMENTED => 1
    };

    public class ActivityException extends Exception {}

    /** One notification to deliver. `detail` only goes to the bell. */
    public class Item {
        public Id recipientId;
        public String type;
        public Id issueId;
        public Id projectId;
        public String issueKey;
        public String message;
        public String detail;

        public Item(Id recipientId, String type, PM_Issue__c issue, String message) {
            this.recipientId = recipientId;
            this.type = type;
            this.message = message;
            if (issue != null) {
                this.issueId = issue.Id;
                this.projectId = issue.Project__c;
                this.issueKey = issue.Name;
            }
        }
    }

    public class InboxItem {
        @AuraEnabled public Id id;
        @AuraEnabled public String type;
        @AuraEnabled public String message;
        @AuraEnabled public Id issueId;
        @AuraEnabled public Id projectId;
        @AuraEnabled public String issueKey;
        @AuraEnabled public Id actorId;
        @AuraEnabled public String actorName;
        @AuraEnabled public Boolean read;
        @AuraEnabled public Datetime createdDate;
    }

    public class Inbox {
        @AuraEnabled public Integer unread = 0;
        @AuraEnabled public List<InboxItem> items = new List<InboxItem>();
    }

    public class Followers {
        @AuraEnabled public Boolean following = false;
        @AuraEnabled public List<Person> people = new List<Person>();
    }

    public class Person {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
    }

    // ---------------------------------------------------------------- Inbox

    @AuraEnabled
    public static Inbox getInbox() {
        try {
            Inbox inbox = new Inbox();
            Id me = UserInfo.getUserId();
            inbox.unread = [SELECT COUNT() FROM PM_Notification__c WHERE OwnerId = :me AND Read__c = false WITH USER_MODE];
            for (PM_Notification__c n : [
                SELECT Id, Type__c, Message__c, Issue__c, Project__c, Issue_Key__c, Actor__c, Actor__r.Name, Read__c, CreatedDate
                FROM PM_Notification__c
                WHERE OwnerId = :me
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT :INBOX_SIZE
            ]) {
                InboxItem item = new InboxItem();
                item.id = n.Id;
                item.type = n.Type__c;
                item.message = n.Message__c;
                item.issueId = n.Issue__c;
                item.projectId = n.Project__c;
                item.issueKey = n.Issue_Key__c;
                item.actorId = n.Actor__c;
                item.actorName = n.Actor__r == null ? null : n.Actor__r.Name;
                item.read = n.Read__c;
                item.createdDate = n.CreatedDate;
                inbox.items.add(item);
            }
            return inbox;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Marks some notifications as read, or all of them when ids is empty. */
    @AuraEnabled
    public static void markRead(List<Id> notificationIds) {
        try {
            Id me = UserInfo.getUserId();
            List<PM_Notification__c> rows = notificationIds == null || notificationIds.isEmpty()
                ? [SELECT Id FROM PM_Notification__c WHERE OwnerId = :me AND Read__c = false WITH USER_MODE LIMIT 1000]
                : [SELECT Id FROM PM_Notification__c WHERE OwnerId = :me AND Id IN :notificationIds AND Read__c = false WITH USER_MODE];
            markAsRead(rows);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Opening an issue clears its notifications. */
    @AuraEnabled
    public static void markIssueRead(Id issueId) {
        try {
            markAsRead([
                SELECT Id FROM PM_Notification__c
                WHERE OwnerId = :UserInfo.getUserId() AND Issue__c = :issueId AND Read__c = false
                WITH USER_MODE
            ]);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    private static void markAsRead(List<PM_Notification__c> rows) {
        for (PM_Notification__c n : rows) {
            n.Read__c = true;
        }
        update as user rows;
    }

    // ---------------------------------------------------------------- Followers

    @AuraEnabled
    public static Followers getFollowers(Id issueId) {
        try {
            Followers result = new Followers();
            for (PM_Follower__c f : [
                SELECT User__c, User__r.Name FROM PM_Follower__c
                WHERE Issue__c = :issueId AND User__c != null
                WITH USER_MODE
                ORDER BY User__r.Name
            ]) {
                Person p = new Person();
                p.id = f.User__c;
                p.name = f.User__r.Name;
                result.people.add(p);
                if (f.User__c == UserInfo.getUserId()) {
                    result.following = true;
                }
            }
            return result;
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** Follows or unfollows an issue the current user can see (Viewers too). */
    @AuraEnabled
    public static Followers setFollowing(Id issueId, Boolean follow) {
        try {
            // Read access check: throws when the user cannot see the issue
            PM_Issue__c issue = [SELECT Id FROM PM_Issue__c WHERE Id = :issueId WITH USER_MODE];
            Id me = UserInfo.getUserId();
            if (follow == true) {
                addFollowers(new Map<Id, Set<Id>>{ issue.Id => new Set<Id>{ me } });
            } else {
                List<PM_Follower__c> mine = [
                    SELECT Id FROM PM_Follower__c WHERE Issue__c = :issue.Id AND User__c = :me WITH USER_MODE
                ];
                if (!mine.isEmpty()) {
                    ProjectBoardSharing.deleteAsSystem(mine);
                }
            }
            return getFollowers(issue.Id);
        } catch (Exception e) {
            throw auraError(e);
        }
    }

    /** issueId -> users who start following. Existing follows are kept (the unique key skips duplicates). */
    public static void addFollowers(Map<Id, Set<Id>> byIssue) {
        List<PM_Follower__c> rows = new List<PM_Follower__c>();
        for (Id issueId : byIssue.keySet()) {
            for (Id userId : byIssue.get(issueId)) {
                if (userId != null) {
                    rows.add(new PM_Follower__c(
                        Issue__c = issueId, User__c = userId, Follower_Key__c = String.valueOf(issueId) + String.valueOf(userId)
                    ));
                }
            }
        }
        if (!rows.isEmpty()) {
            ProjectBoardSharing.insertAsSystem(rows, false);
        }
    }

    private static Map<Id, Set<Id>> followersOf(Set<Id> issueIds) {
        Map<Id, Set<Id>> result = new Map<Id, Set<Id>>();
        for (PM_Follower__c f : [
            SELECT Issue__c, User__c FROM PM_Follower__c WHERE Issue__c IN :issueIds AND User__c != null
        ]) {
            if (!result.containsKey(f.Issue__c)) {
                result.put(f.Issue__c, new Set<Id>());
            }
            result.get(f.Issue__c).add(f.User__c);
        }
        return result;
    }

    // ---------------------------------------------------------------- Events (called by the controllers)

    /** New issues: reporter and assignee follow; the assignee is told. */
    public static void issuesCreated(List<PM_Issue__c> issues) {
        try {
            Map<Id, Set<Id>> follows = new Map<Id, Set<Id>>();
            List<Item> items = new List<Item>();
            for (PM_Issue__c i : issues) {
                follows.put(i.Id, new Set<Id>{ i.Reporter__c, i.Assignee__c });
                if (i.Assignee__c != null) {
                    items.add(new Item(i.Assignee__c, TYPE_ASSIGNED, i, actor() + ' assigned you ' + label(i)));
                }
            }
            addFollowers(follows);
            deliver(items);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Activity not recorded: ' + e.getMessage());
        }
    }

    /** An issue changed: a new assignee follows and is told; a new status goes to followers and the requester. */
    public static void issueChanged(PM_Issue__c before, PM_Issue__c after) {
        try {
            List<Item> items = new List<Item>();
            Boolean newAssignee = after.Assignee__c != null && after.Assignee__c != before.Assignee__c;
            Boolean newStatus = String.isNotBlank(after.Status__c) && after.Status__c != before.Status__c;
            if (newAssignee) {
                addFollowers(new Map<Id, Set<Id>>{ after.Id => new Set<Id>{ after.Assignee__c } });
                items.add(new Item(after.Assignee__c, TYPE_ASSIGNED, after, actor() + ' assigned you ' + label(after)));
            }
            if (newStatus) {
                String text = actor() + ' moved ' + label(after) + ' to ' + after.Status__c;
                Map<Id, Set<Id>> followers = followersOf(new Set<Id>{ after.Id });
                for (Id userId : followers.containsKey(after.Id) ? followers.get(after.Id) : new Set<Id>()) {
                    items.add(new Item(userId, TYPE_STATUS, after, text));
                }
                if (after.Requested_By__c != null) {
                    items.add(new Item(after.Requested_By__c, TYPE_REQUEST, after,
                        'Your request ' + label(after) + ' is now ' + after.Status__c));
                }
            }
            deliver(items);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Activity not recorded: ' + e.getMessage());
        }
    }

    /** A comment: mentioned members and followers are told; the author and the mentioned members follow. */
    public static void commentAdded(PM_Issue__c issue, String body) {
        try {
            Map<Id, String> members = new Map<Id, String>();
            for (PM_Project_Member__c m : [
                SELECT User__c, User__r.Name FROM PM_Project_Member__c WHERE Project__c = :issue.Project__c AND User__c != null
            ]) {
                members.put(m.User__c, m.User__r.Name);
            }
            Set<Id> mentioned = mentionedIn(body, members);
            Set<Id> follow = new Set<Id>(mentioned);
            follow.add(UserInfo.getUserId());
            Map<Id, Set<Id>> followers = followersOf(new Set<Id>{ issue.Id });
            addFollowers(new Map<Id, Set<Id>>{ issue.Id => follow });

            List<Item> items = new List<Item>();
            for (Id userId : mentioned) {
                items.add(new Item(userId, TYPE_MENTIONED, issue, actor() + ' mentioned you in ' + label(issue)));
            }
            for (Id userId : followers.containsKey(issue.Id) ? followers.get(issue.Id) : new Set<Id>()) {
                items.add(new Item(userId, TYPE_COMMENTED, issue, actor() + ' commented on ' + label(issue)));
            }
            deliver(items);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Activity not recorded: ' + e.getMessage());
        }
    }

    /**
     * Members named as "@Full Name" in the comment (HTML is stripped first). Longer names are matched first, so
     * "@Ana Silva" never also counts as "@Ana".
     */
    public static Set<Id> mentionedIn(String body, Map<Id, String> members) {
        Set<Id> result = new Set<Id>();
        if (String.isBlank(body)) {
            return result;
        }
        String text = ' ' + body.replace('&nbsp;', ' ').stripHtmlTags().toLowerCase() + ' ';
        List<NameEntry> names = new List<NameEntry>();
        for (Id userId : members.keySet()) {
            if (String.isNotBlank(members.get(userId))) {
                names.add(new NameEntry(userId, members.get(userId).toLowerCase()));
            }
        }
        names.sort();
        for (NameEntry entry : names) {
            String token = '@' + entry.name;
            Integer at = text.indexOf(token);
            while (at >= 0) {
                String after = text.substring(at + token.length(), at + token.length() + 1);
                if (!after.isAlphanumeric()) {
                    result.add(entry.userId);
                    // Blank the match so a shorter name inside it is not matched again
                    text = text.substring(0, at) + ' '.repeat(token.length()) + text.substring(at + token.length());
                    break;
                }
                at = text.indexOf(token, at + 1);
            }
        }
        return result;
    }

    private class NameEntry implements Comparable {
        Id userId;
        String name;
        NameEntry(Id userId, String name) {
            this.userId = userId;
            this.name = name;
        }
        public Integer compareTo(Object other) {
            return ((NameEntry) other).name.length() - this.name.length();
        }
    }

    // ---------------------------------------------------------------- Delivery

    /**
     * Writes the inbox rows and sends the bell. Drops the actor and people who are no longer members (except a
     * requester hearing about their own request) and keeps one notification per person and issue.
     */
    public static void deliver(List<Item> items) {
        if (items == null || items.isEmpty()) {
            return;
        }
        Id me = UserInfo.getUserId();
        Set<Id> projectIds = new Set<Id>();
        for (Item i : items) {
            projectIds.add(i.projectId);
        }
        projectIds.remove(null);
        Map<Id, Map<Id, String>> roles = ProjectBoardSharing.memberRoles(projectIds);

        Map<String, Item> chosen = new Map<String, Item>();
        for (Item i : items) {
            if (i.recipientId == null || i.recipientId == me) {
                continue;
            }
            Boolean member = i.projectId != null && roles.containsKey(i.projectId) && roles.get(i.projectId).containsKey(i.recipientId);
            if (!member && i.type != TYPE_REQUEST) {
                continue;
            }
            String key = String.valueOf(i.recipientId) + '|' + String.valueOf(i.issueId);
            Item current = chosen.get(key);
            if (current == null || PRIORITY.get(i.type) > PRIORITY.get(current.type)) {
                chosen.put(key, i);
            }
        }
        if (chosen.isEmpty()) {
            return;
        }

        List<PM_Notification__c> rows = new List<PM_Notification__c>();
        for (Item i : chosen.values()) {
            rows.add(new PM_Notification__c(
                OwnerId = i.recipientId, Type__c = i.type, Message__c = i.message.left(255), Issue__c = i.issueId,
                Project__c = i.projectId, Issue_Key__c = i.issueKey, Actor__c = me
            ));
        }
        ProjectBoardSharing.insertAsSystem(rows, false);
        sendBell(chosen.values());
    }

    private static void sendBell(List<Item> items) {
        try {
            Map<String, Id> types = new Map<String, Id>();
            for (CustomNotificationType t : [
                SELECT Id, DeveloperName FROM CustomNotificationType WHERE DeveloperName IN (:BELL_ACTIVITY, :BELL_SIGN_OFF)
            ]) {
                types.put(t.DeveloperName, t.Id);
            }
            // One send per distinct message
            Map<String, Set<String>> recipients = new Map<String, Set<String>>();
            Map<String, Item> samples = new Map<String, Item>();
            for (Item i : items) {
                String key = i.type + '|' + i.message + '|' + i.detail;
                if (!recipients.containsKey(key)) {
                    recipients.put(key, new Set<String>());
                    samples.put(key, i);
                }
                recipients.get(key).add(i.recipientId);
            }
            for (String key : recipients.keySet()) {
                Item sample = samples.get(key);
                Id typeId = types.get(sample.type == TYPE_SIGN_OFF ? BELL_SIGN_OFF : BELL_ACTIVITY);
                if (typeId == null) {
                    continue;
                }
                Messaging.CustomNotification n = new Messaging.CustomNotification();
                n.setNotificationTypeId(typeId);
                n.setTitle(sample.message.left(250));
                n.setBody((String.isBlank(sample.detail) ? 'Open the project board to see it.' : sample.detail).left(750));
                n.setTargetPageRef('{"type":"standard__navItemPage","attributes":{"apiName":"' + APP_TAB + '"}}');
                n.send(recipients.get(key));
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Bell notification not sent: ' + e.getMessage());
        }
    }

    // ---------------------------------------------------------------- Helpers

    public static String label(PM_Issue__c issue) {
        String summary = String.isBlank(issue.Summary__c) ? '' : ': ' + issue.Summary__c;
        return (issue.Name + summary).abbreviate(180);
    }

    private static String actor() {
        return UserInfo.getName();
    }

    private static AuraHandledException auraError(Exception e) {
        String message = e instanceof DmlException ? ((DmlException) e).getDmlMessage(0) : e.getMessage();
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }
}
