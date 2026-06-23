#import <Cocoa/Cocoa.h>

@protocol ClaudeChatDelegate <NSObject>
- (void)claudeChatDidModifyFiles;   // the CLI may have changed files on disk
@end

// A self-contained Claude chat panel. It builds its own view and drives the
// `claude` CLI in print mode, so it uses the user's Claude subscription (their
// `claude login` session) rather than a pay-per-use API key. The CLI runs its
// own read/write/edit tool loop, scoped to the project root folder.
@interface ClaudeChat : NSObject

@property (nonatomic, strong, readonly) NSView *view;
@property (nonatomic, strong) NSURL *rootURL;          // project root (CLI cwd)
@property (nonatomic, weak) id<ClaudeChatDelegate> delegate;

- (instancetype)init;

@end
