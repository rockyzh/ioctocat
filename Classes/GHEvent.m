#import "GHEvent.h"
#import "GHRepository.h"
#import "GHBranch.h"
#import "GHTag.h"
#import "GHCommits.h"
#import "GHCommit.h"
#import "GHIssue.h"
#import "GHGist.h"
#import "GHIssue.h"
#import "GHUser.h"
#import "GHOrganization.h"
#import "GHPullRequest.h"
#import "GHRepoComment.h"
#import "GHIssueComment.h"
#import "iOctocat.h"
#import "NSString+Extensions.h"
#import "NSDictionary+Extensions.h"


@interface GHEvent ()
@property(nonatomic,readwrite)BOOL read;
@end


@implementation GHEvent

- (id)initWithDict:(NSDictionary *)dict {
	self = [super init];
	if (self) {
		self.read = NO;
		[self setValues:dict];
	}
	return self;
}

- (NSString *)extendedEventType {
	NSString *action = [self.payload safeStringForKey:@"action"];
	if ([self.eventType isEqualToString:@"IssuesEvent"]) {
		return [action isEqualToString:@"closed"] ? @"IssuesClosedEvent" : @"IssuesOpenedEvent";
	} else if ([self.eventType isEqualToString:@"PullRequestEvent"]) {
		if ([action isEqualToString:@"synchronize"]) {
			return @"PullRequestSynchronizeEvent";
		}
		return [action isEqualToString:@"closed"] ? @"PullRequestClosedEvent" : @"PullRequestOpenedEvent";
	}
	return self.eventType;
}

- (void)markAsRead {
	self.read = YES;
}

- (BOOL)isCommentEvent {
	return [self.eventType hasSuffix:@"CommentEvent"];
}

- (void)setValues:(id)dict {
	self.eventID = [dict safeStringForKey:@"id"];
	self.eventType = [dict safeStringForKey:@"type"];
	self.payload = [dict safeDictForKey:@"payload"];
	self.date = [dict safeDateForKey:@"created_at"];

	NSString *actorLogin = [dict safeStringForKeyPath:@"actor.login"];
	NSString *orgLogin = [dict safeStringForKeyPath:@"org.login"];

	// User
	if (!actorLogin.isEmpty) {
		self.user = [iOctocat.sharedInstance userWithLogin:actorLogin];
		if (!self.user.gravatarURL) {
			self.user.gravatarURL = [dict safeURLForKeyPath:@"actor.avatar_url"];
		}
	}

	// Organization
	if (!orgLogin.isEmpty) {
		self.organization = [iOctocat.sharedInstance organizationWithLogin:orgLogin];
		if (!self.organization.gravatarURL) {
			self.organization.gravatarURL = [dict safeURLForKeyPath:@"org.avatar_url"];
		}
	}

	// Other user
	NSString *otherUserLogin = nil;
	NSDictionary *otherUserDict = [self.payload safeDictForKey:@"target"];
	if (!otherUserDict) otherUserDict = [self.payload safeDictForKey:@"member"];
	if (!otherUserDict) otherUserDict = [self.payload safeDictForKey:@"user"];
	if (!otherUserDict && !self.organization && [self.eventType isEqualToString:@"WatchEvent"]) {
		// use repo owner as fallback
		otherUserLogin = [[dict safeStringForKeyPath:@"repo.name"] componentsSeparatedByString:@"/"][0];
	} else if (otherUserDict) {
		otherUserLogin = [otherUserDict safeStringForKey:@"login"];
	}
	if (!otherUserLogin.isEmpty) {
		self.otherUser = [iOctocat.sharedInstance userWithLogin:otherUserLogin];
		if (!self.otherUser.gravatarURL) {
			self.otherUser.gravatarURL = [otherUserDict safeURLForKeyPath:@"avatar_url"];
		}
	}

	// Repository
	self.repoName = [dict safeStringForKeyPath:@"repo.name"];
	NSArray *repoParts = [self.repoName componentsSeparatedByString:@"/"];
	if (repoParts.count == 2) {
		NSString *rOwner = repoParts[0];
		NSString *rName = repoParts[1];
		if (!!rOwner && !!rName && ![rOwner isEmpty] && ![rName isEmpty]) {
			self.repository = [[GHRepository alloc] initWithOwner:rOwner andName:rName];
			self.repository.descriptionText = [self.payload safeStringForKey:@"description"];
            // Branches and Tags
            self.ref = [self.payload safeStringOrNilForKey:@"ref"];
            self.refType = [self.payload safeStringOrNilForKey:@"ref_type"];
            if ([self.refType isEqualToString:@"branch"]) {
                self.branch = [[GHBranch alloc] initWithRepository:self.repository andName:self.ref];
            } else if ([self.refType isEqualToString:@"tag"]) {
                self.tag = [[GHTag alloc] initWithRepo:self.repository sha:self.ref];
            } else if ([self.eventType isEqualToString:@"PushEvent"] && self.ref) {
                self.ref = [self shortenRef:self.ref];
                self.branch = [[GHBranch alloc] initWithRepository:self.repository andName:self.ref];
            }
		}
	}

	// Other Repository
	NSDictionary *otherRepoDict = [self.payload safeDictForKey:@"forkee"];
	if (otherRepoDict) {
		NSString *otherRepoName = [otherRepoDict safeStringForKey:@"name"];
		NSString *otherRepoOwner = [otherRepoDict safeStringForKeyPath:@"owner.login"];
		if (![otherRepoOwner isEmpty] && ![otherRepoName isEmpty]) {
			self.otherRepository = [[GHRepository alloc] initWithOwner:otherRepoOwner andName:otherRepoName];
			self.otherRepository.descriptionText = [otherRepoDict safeStringForKey:@"description"];
		}
	}

	// Issue
	NSDictionary *issueDict = [self.payload safeDictForKey:@"issue"];
	NSInteger issueNumber = [issueDict safeIntegerForKey:@"number"];
	if (issueDict && issueNumber) {
		self.issue = [[GHIssue alloc] initWithRepository:self.repository];
		self.issue.number = issueNumber;
		[self.issue setValues:issueDict];
	}

	// Pull Request
	NSDictionary *pullDict = [self.payload safeDictForKey:@"pull_request"];
	if (!pullDict) pullDict = [issueDict safeDictForKey:@"pull_request"];
	// this check is somehow hacky, but the API provides empty pull_request
	// urls in case there is no pull request associated with an issue.
	// an IssueCommentEvent with an associated pull request has the urls
	// set, but it does not contain the pull request number in the payload
	// for issue.pull_request, so we have to use the issue number then
	if (pullDict && [pullDict safeURLForKey:@"html_url"]) {
		self.pullRequest = [[GHPullRequest alloc] initWithRepository:self.repository];
		NSDictionary *pullPayload = [self.payload safeDictForKey:@"pull_request"];
		if (pullPayload) {
			[self.pullRequest setValues:pullPayload];
		}
		if (!self.pullRequest.number) {
			self.pullRequest.number = self.issue.number;
		}
	} else if ([self.eventType isEqualToString:@"PullRequestReviewCommentEvent"]) {
		// currently there is no separate number for a PullRequestReviewCommentEvent,
		// so we have to hack around like this, by parsing it out of the URL.
		NSURL *pullURL = [self.payload safeURLForKeyPath:@"comment._links.pull_request.href"];
		NSInteger pullNumber = [[pullURL lastPathComponent] intValue];
		if (!!pullNumber) {
			self.pullRequest = [[GHPullRequest alloc] initWithRepository:self.repository];
			self.pullRequest.number = pullNumber;
		}
	}

	// Issue Comment (which might also be a pull request comment)
	if ([self.eventType isEqualToString:@"IssueCommentEvent"] || [self.eventType isEqualToString:@"PullRequestReviewCommentEvent"]) {
		id issueCommentParent = self.pullRequest ? self.pullRequest : self.issue;
		self.comment = [[GHIssueComment alloc] initWithParent:issueCommentParent];
		[self.comment setValues:[self.payload safeDictForKey:@"comment"]];
	}

	// Gist
	NSDictionary *gistDict = [self.payload safeDictForKey:@"gist"];
	if (gistDict) {
		NSString *gistId = [gistDict safeStringForKey:@"id"];
		self.gist = [[GHGist alloc] initWithId:gistId];
		[self.gist setValues:gistDict];
	}

	// Commits
	NSArray *commits = [self.payload safeArrayForKey:@"commits"];
	if (commits) {
		self.commits = [[GHCommits alloc] initWithRepository:self.repository];
		self.commits.resourcePath = @""; // empty out resourcePath, because it's a custom list of commits
		[self.commits setValues:commits];
		[self.commits markAsLoaded];
	}

	// Commit Comment
	if ([self.eventType isEqualToString:@"CommitCommentEvent"]) {
		self.comment = [[GHRepoComment alloc] initWithRepo:self.repository];
		[self.comment setValues:[self.payload safeDictForKey:@"comment"]];
		if (!self.commits) {
			NSString *sha = [self.payload safeStringForKeyPath:@"comment.commit_id"];
			self.commits = [[GHCommits alloc] initWithRepository:self.repository];
			self.commits.resourcePath = @""; // empty out resourcePath, because it's a custom list of commits
			[self.commits setValues:@[@{@"sha": sha}]];
			[self.commits markAsLoaded];
		}
	}

	// Wiki
	NSArray *pages = [self.payload safeArrayForKey:@"pages"];
	if (pages) {
		self.pages = [NSMutableArray arrayWithCapacity:pages.count];
		for (NSDictionary *pageDict in pages) {
			[self.pages addObject:pageDict];
		}
	}
}

- (NSString *)title {
	if (_title) return _title;

	@try {
		if ([self.eventType isEqualToString:@"CommitCommentEvent"]) {
			GHCommit *commit = self.commits[0];
			self.title = [NSString stringWithFormat:@"%@ commented on %@ at %@", self.user.login, commit.shortenedSha, self.repository.repoId];
		}

		else if ([self.eventType isEqualToString:@"CreateEvent"]) {
			if ([self.refType isEqualToString:@"repository"]) { // created repository
				self.title = [NSString stringWithFormat:@"%@ created %@ %@", self.user.login, self.refType, self.repository.repoId];
			} else { // created branch or tag
				self.title = [NSString stringWithFormat:@"%@ created %@ %@ at %@", self.user.login, self.refType, self.ref, self.repository.repoId];
			}
		}

		else if ([self.eventType isEqualToString:@"DeleteEvent"]) {
			self.title = [NSString stringWithFormat:@"%@ deleted %@ %@ at %@", self.user.login, self.refType, self.ref, self.repository.repoId];
		}

		else if ([self.eventType isEqualToString:@"DownloadEvent"]) {
			NSString *name = [self.payload safeStringForKeyPath:@"download.name"];
			self.title = [NSString stringWithFormat:@"%@ created download %@ at %@", self.user.login, name, self.repository.repoId];
		}

		else if ([self.eventType isEqualToString:@"FollowEvent"]) {
			self.title = [NSString stringWithFormat:@"%@ started following %@", self.user.login, self.otherUser.login];
		}

		else if ([self.eventType isEqualToString:@"ForkEvent"]) {
			self.title = [NSString stringWithFormat:@"%@ forked %@ to %@", self.user.login, self.repository.repoId, self.otherRepository.repoId];
		}

		else if ([self.eventType isEqualToString:@"ForkApplyEvent"]) {
			self.title = [NSString stringWithFormat:@"%@ applied a patch to %@", self.user.login, self.repository.repoId];
		}

		else if ([self.eventType isEqualToString:@"GistEvent"]) {
			NSString *action = [self.payload safeStringForKey:@"action"];
			if ([action isEqualToString:@"create"]) {
				action = @"created";
			} else if ([action isEqualToString:@"update"]) {
				action = @"updated";
			}
			self.title = [NSString stringWithFormat:@"%@ %@ gist %@", self.user.login, action, self.gist.gistId];
		}

		else if ([self.eventType isEqualToString:@"GollumEvent"]) {
			NSDictionary *firstPage = self.pages[0];
			NSString *action = [firstPage safeStringForKey:@"action"];
			NSString *pageName = [firstPage safeStringForKey:@"page_name"];
			self.title = [NSString stringWithFormat:@"%@ %@ \"%@\" in the %@ wiki", self.user.login, action, pageName, self.repository.repoId];
		}

		else if ([self.eventType isEqualToString:@"IssueCommentEvent"]) {
			id issueCommentParent = self.pullRequest ? self.pullRequest : self.issue;
			NSString *parentType = self.pullRequest ? @"pull request" : @"issue";
			self.title = [NSString stringWithFormat:@"%@ commented on %@ %@", self.user.login, parentType, [(GHIssue *)issueCommentParent repoIdWithIssueNumber]];
		}

		else if ([self.eventType isEqualToString:@"IssuesEvent"]) {
			NSString *action = [self.payload safeStringForKey:@"action"];
			self.title = [NSString stringWithFormat:@"%@ %@ issue %@", self.user.login, action, self.issue.repoIdWithIssueNumber];
		}

		else if ([self.eventType isEqualToString:@"MemberEvent"]) {
			self.title = [NSString stringWithFormat:@"%@ added %@ to %@", self.user.login, self.otherUser.login, self.repository.repoId];
		}

		else if ([self.eventType isEqualToString:@"PublicEvent"]) {
			self.title = [NSString stringWithFormat:@"%@ open sourced %@", self.user.login, self.repository.repoId];
		}

		else if ([self.eventType isEqualToString:@"PullRequestEvent"]) {
			NSString *action = [self.payload safeStringForKey:@"action"];
			if ([action isEqualToString:@"closed"] && self.pullRequest.isMerged) action = @"merged";
			self.title = [NSString stringWithFormat:@"%@ %@ pull request %@", self.user.login, action, self.pullRequest.repoIdWithIssueNumber];
		}

		else if ([self.eventType isEqualToString:@"PullRequestReviewCommentEvent"]) {
			self.title = [NSString stringWithFormat:@"%@ commented on pull request %@", self.user.login, self.pullRequest.repoIdWithIssueNumber];
		}

		else if ([self.eventType isEqualToString:@"PushEvent"]) {
			self.title = [NSString stringWithFormat:@"%@ pushed to %@ at %@", self.user.login, self.ref, self.repository.repoId];
		}

		else if ([self.eventType isEqualToString:@"TeamAddEvent"]) {
			NSString *teamName = [self.payload safeStringForKeyPath:@"team.name"];
			// for older events the team may not be set, so leave out to which team the user was added
			NSString *teamInfo = teamName ? [NSString stringWithFormat:@" to %@", teamName] : @"";
			self.title = [NSString stringWithFormat:@"%@ added %@%@", self.user.login, self.otherUser.login, teamInfo];
		}

		else if ([self.eventType isEqualToString:@"WatchEvent"]) {
			self.title = [NSString stringWithFormat:@"%@ starred %@", self.user.login, self.repository.repoId];
		}

	}

	@catch (NSException *e) {
		self.title = @"";

	}

	return _title;
}

- (NSString *)content {
	if (_content) return _content;

	@try {
		if ([self.eventType isEqualToString:@"CommitCommentEvent"]) {
			self.content = [self.payload safeStringForKeyPath:@"comment.body"];
		}

		else if ([self.eventType isEqualToString:@"CreateEvent"]) {
			NSString *refType = [self.payload safeStringForKey:@"ref_type"];
			self.content = [refType isEqualToString:@"repository"] ? self.repository.descriptionText : @"";
		}

		else if ([self.eventType isEqualToString:@"ForkEvent"]) {
			self.content = self.otherRepository.descriptionText;
		}

		else if ([self.eventType isEqualToString:@"GistEvent"]) {
			self.content = self.gist.descriptionText;
		}

		else if ([self.eventType isEqualToString:@"GollumEvent"]) {
			NSDictionary *firstPage = self.pages[0];
			self.content = [firstPage safeStringForKey:@"summary"];
		}

		else if ([self.eventType isEqualToString:@"IssueCommentEvent"]) {
			self.content = [self.payload safeStringForKeyPath:@"comment.body"];
		}

		else if ([self.eventType isEqualToString:@"IssuesEvent"]) {
			self.content = self.issue.title;
		}

		else if ([self.eventType isEqualToString:@"PullRequestEvent"]) {
			self.content = self.pullRequest.title;
		}

		else if ([self.eventType isEqualToString:@"PullRequestReviewCommentEvent"]) {
			self.content = [self.payload safeStringForKeyPath:@"comment.body"];
		}

		else if ([self.eventType isEqualToString:@"PushEvent"]) {
			NSMutableArray *messages = [NSMutableArray arrayWithCapacity:self.commits.count];
			for (GHCommit *commit in self.commits.items) {
				NSString *formatted = [NSString stringWithFormat:@"%@ %@", commit.shortenedSha, commit.shortenedMessage];
				[messages addObject:formatted];
			}
			self.content = [messages componentsJoinedByString:@"\n"];
		}

		else {
			self.content = @"";
		}
	}

	@catch (NSException *e) {
		self.content = @"";
	}

	return _content;
}

- (NSString *)shortenRef:(NSString *)longRef {
	return [longRef lastPathComponent];
}

@end
