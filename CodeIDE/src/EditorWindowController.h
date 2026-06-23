#import <Cocoa/Cocoa.h>
#import "FileBrowser.h"
#import "ClaudeChat.h"

@interface EditorWindowController : NSWindowController
    <NSTextViewDelegate, NSWindowDelegate, NSSplitViewDelegate,
     FileBrowserDelegate, ClaudeChatDelegate>

@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, strong) NSSplitView *splitView;
@property (nonatomic, strong) FileBrowser *fileBrowser;
@property (nonatomic, strong) ClaudeChat *claude;
@property (nonatomic, strong) NSURL *rootFolderURL;

- (void)openDocument:(id)sender;
- (void)saveDocument:(id)sender;
- (void)openFolder:(id)sender;

@end
