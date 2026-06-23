#import "AppDelegate.h"
#import "EditorWindowController.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.controllers = [NSMutableArray array];
    [self setupMenu];
    [self newWindow:nil];
}

- (void)newWindow:(id)sender {
    (void)sender;
    EditorWindowController *controller = [[EditorWindowController alloc] init];
    [self.controllers addObject:controller];
    [controller showWindow:nil];
    [[controller window] makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Drop the controller when its window closes (so the app can quit / free it).
    __weak AppDelegate *weakSelf = self;
    __block id token = nil;
    token = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:[controller window]
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        AppDelegate *strongSelf = weakSelf;
        if (strongSelf) {
            for (EditorWindowController *c in [strongSelf.controllers copy]) {
                if ([c window] == note.object) {
                    [strongSelf.controllers removeObject:c];
                    break;
                }
            }
        }
        [[NSNotificationCenter defaultCenter] removeObserver:token];
    }];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)setupMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSString *appName = [[NSProcessInfo processInfo] processName];

    // --- Application menu ---
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appItem setSubmenu:appMenu];
    [appMenu addItemWithTitle:[@"About " stringByAppendingString:appName]
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[@"Hide " stringByAppendingString:appName]
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:appName]
                       action:@selector(terminate:)
                keyEquivalent:@"q"];

    // --- File menu ---
    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileItem setSubmenu:fileMenu];
    NSMenuItem *newItem = [fileMenu addItemWithTitle:@"New Window"
                                              action:@selector(newWindow:)
                                       keyEquivalent:@"n"];
    [newItem setTarget:self];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Open…"
                        action:@selector(openDocument:)
                 keyEquivalent:@"o"];
    [fileMenu addItemWithTitle:@"Open Folder…"
                        action:@selector(openFolder:)
                 keyEquivalent:@"O"];   // Cmd-Shift-O
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Save"
                        action:@selector(saveDocument:)
                 keyEquivalent:@"s"];

    // --- Edit menu (standard responder-chain actions) ---
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editItem setSubmenu:editMenu];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    [NSApp setMainMenu:mainMenu];
}

@end
