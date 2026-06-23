#import "EditorWindowController.h"

@implementation EditorWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 1040, 680);
    NSUInteger style = NSWindowStyleMaskTitled
                     | NSWindowStyleMaskClosable
                     | NSWindowStyleMaskMiniaturizable
                     | NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        [window setDelegate:self];
        [self setupSplitLayout];
        [self updateWindowTitle];
        [window makeFirstResponder:self.textView];
    }
    return self;
}

#pragma mark - Layout

- (void)setupSplitLayout {
    NSView *content = [[self window] contentView];
    NSSplitView *split = [[NSSplitView alloc] initWithFrame:[content bounds]];
    [split setVertical:YES];
    [split setDividerStyle:NSSplitViewDividerStyleThin];
    [split setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [split setDelegate:self];

    self.claude = [[ClaudeChat alloc] init];
    self.claude.delegate = self;

    [split addSubview:[self buildSidebar]];
    [split addSubview:[self buildEditor]];
    [split addSubview:self.claude.view];

    [content addSubview:split];
    self.splitView = split;

    [split adjustSubviews];
    CGFloat w = [content bounds].size.width;
    [split setPosition:220.0 ofDividerAtIndex:0];          // sidebar width
    [split setPosition:(w - 330.0) ofDividerAtIndex:1];    // Claude panel ~330
}

- (NSScrollView *)buildSidebar {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 220, 600)];
    [scroll setHasVerticalScroller:YES];
    [scroll setHasHorizontalScroller:NO];
    [scroll setBorderType:NSNoBorder];

    NSOutlineView *outline = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [col setEditable:NO];
    [col setResizingMask:NSTableColumnAutoresizingMask];
    [outline addTableColumn:col];
    [outline setOutlineTableColumn:col];
    [outline setHeaderView:nil];
    [outline setColumnAutoresizingStyle:NSTableViewUniformColumnAutoresizingStyle];
    [outline setFocusRingType:NSFocusRingTypeNone];
    [outline setRowSizeStyle:NSTableViewRowSizeStyleDefault];

    [scroll setDocumentView:outline];

    self.fileBrowser = [[FileBrowser alloc] initWithOutlineView:outline];
    self.fileBrowser.delegate = self;
    return scroll;
}

- (NSScrollView *)buildEditor {
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 580, 600)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSNoBorder];

    NSSize contentSize = [scrollView contentSize];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    [tv setMinSize:NSMakeSize(0, contentSize.height)];
    [tv setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    [tv setVerticallyResizable:YES];
    [tv setHorizontallyResizable:NO];
    [tv setAutoresizingMask:NSViewWidthSizable];
    [[tv textContainer] setContainerSize:NSMakeSize(contentSize.width, FLT_MAX)];
    [[tv textContainer] setWidthTracksTextView:YES];
    [tv setTextContainerInset:NSMakeSize(8.0, 8.0)];   // margin around the code

    // Code-appropriate behavior: plain text, no "smart" substitutions.
    [tv setRichText:NO];
    [tv setImportsGraphics:NO];
    [tv setAutomaticQuoteSubstitutionEnabled:NO];
    [tv setAutomaticDashSubstitutionEnabled:NO];
    [tv setAutomaticTextReplacementEnabled:NO];
    [tv setAutomaticSpellingCorrectionEnabled:NO];
    [tv setSmartInsertDeleteEnabled:NO];
    [tv setAllowsUndo:YES];
    [tv setDelegate:self];

    NSFont *font = [self editorFont];
    [tv setFont:font];

    // 4-space-wide soft tabs feel.
    NSMutableParagraphStyle *pstyle = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    CGFloat charWidth = [@" " sizeWithAttributes:@{NSFontAttributeName: font}].width;
    [pstyle setTabStops:@[]];
    [pstyle setDefaultTabInterval:charWidth * 4.0];
    [tv setDefaultParagraphStyle:pstyle];
    [tv setTypingAttributes:@{NSFontAttributeName: font,
                              NSParagraphStyleAttributeName: pstyle}];

    [scrollView setDocumentView:tv];
    self.textView = tv;
    return scrollView;
}

- (NSFont *)editorFont {
    NSFont *font = [NSFont fontWithName:@"Menlo" size:13.0];
    if (!font) {
        font = [NSFont userFixedPitchFontOfSize:13.0];
    }
    return font;
}

#pragma mark - File operations

- (void)openDocument:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:NO];
    [panel setCanChooseDirectories:NO];
    [panel setCanChooseFiles:YES];
    if ([panel runModal] == NSModalResponseOK) {
        NSURL *url = [[panel URLs] firstObject];
        if (url) {
            [self loadFileAtURL:url];
        }
    }
}

- (void)openFolder:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:NO];
    [panel setCanChooseDirectories:YES];
    [panel setAllowsMultipleSelection:NO];
    if ([panel runModal] == NSModalResponseOK) {
        NSURL *url = [[panel URLs] firstObject];
        if (url) {
            self.rootFolderURL = url;
            [self.fileBrowser setRootURL:url];
            self.claude.rootURL = url;
            [self updateWindowTitle];
        }
    }
}

- (void)loadFileAtURL:(NSURL *)url {
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfURL:url
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    if (!contents) {
        [[NSAlert alertWithError:error] runModal];
        return;
    }
    [self.textView setString:contents];
    [self.textView setFont:[self editorFont]];     // setString resets to typing font; reassert across full text
    self.currentPath = [url path];
    [self updateWindowTitle];
    [[self window] setDocumentEdited:NO];
}

- (void)saveDocument:(id)sender {
    (void)sender;
    if (self.currentPath) {
        [self writeToPath:self.currentPath];
        return;
    }
    // Untitled: fall back to a save panel so Cmd-S never silently fails.
    NSSavePanel *panel = [NSSavePanel savePanel];
    if ([panel runModal] == NSModalResponseOK) {
        NSString *path = [[panel URL] path];
        if (path) {
            self.currentPath = path;
            [self writeToPath:path];
            [self updateWindowTitle];
        }
    }
}

- (void)writeToPath:(NSString *)path {
    NSError *error = nil;
    BOOL ok = [[self.textView string] writeToFile:path
                                       atomically:YES
                                         encoding:NSUTF8StringEncoding
                                            error:&error];
    if (ok) {
        [[self window] setDocumentEdited:NO];
    } else {
        [[NSAlert alertWithError:error] runModal];
    }
}

#pragma mark - Title / dirty state

- (void)updateWindowTitle {
    if (self.currentPath) {
        [[self window] setTitle:[self.currentPath lastPathComponent]];
        [[self window] setRepresentedFilename:self.currentPath];
    } else if (self.rootFolderURL) {
        [[self window] setTitle:[self.rootFolderURL lastPathComponent]];
        [[self window] setRepresentedFilename:@""];
    } else {
        [[self window] setTitle:@"Untitled"];
        [[self window] setRepresentedFilename:@""];
    }
}

#pragma mark - NSTextViewDelegate

- (void)textDidChange:(NSNotification *)notification {
    (void)notification;
    [[self window] setDocumentEdited:YES];
}

#pragma mark - FileBrowserDelegate

- (void)fileBrowserDidSelectFile:(NSURL *)url {
    [self loadFileAtURL:url];
}

#pragma mark - ClaudeChatDelegate

- (void)claudeChatDidModifyFiles {
    if (self.rootFolderURL) {
        [self.fileBrowser setRootURL:self.rootFolderURL];   // rebuild tree from disk
    }
    [self reloadCurrentFileFromDisk];
}

- (void)reloadCurrentFileFromDisk {
    if (!self.currentPath) {
        return;
    }
    NSString *contents = [NSString stringWithContentsOfFile:self.currentPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (contents) {
        [self.textView setString:contents];
        [self.textView setFont:[self editorFont]];
        [[self window] setDocumentEdited:NO];
    }
}

#pragma mark - NSSplitViewDelegate

- (CGFloat)splitView:(NSSplitView *)splitView
constrainMinCoordinate:(CGFloat)proposedMin
         ofSubviewAt:(NSInteger)dividerIndex {
    if (dividerIndex == 0) {
        return 150.0;                 // sidebar minimum width
    }
    return proposedMin + 200.0;       // keep the editor at least ~200pt wide
}

- (CGFloat)splitView:(NSSplitView *)splitView
constrainMaxCoordinate:(CGFloat)proposedMax
         ofSubviewAt:(NSInteger)dividerIndex {
    if (dividerIndex == 1) {
        return splitView.bounds.size.width - 220.0;   // Claude panel minimum width
    }
    return proposedMax;
}

@end
