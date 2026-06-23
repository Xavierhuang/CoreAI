#import "ClaudeChat_Internal.h"

@implementation ClaudeChat

- (instancetype)init {
    self = [super init];
    if (self) {
        [self buildView];
        [self appendRole:@"Claude"
                    text:@"Open a folder, then ask me to read or change files in it. "
                         @"I run on your Claude subscription via the claude CLI."];
    }
    return self;
}

#pragma mark - View

- (void)buildView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 600)];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 44, 304, 548)];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    NSSize cs = [scroll contentSize];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, cs.width, cs.height)];
    [tv setMinSize:NSMakeSize(0, cs.height)];
    [tv setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
    [tv setVerticallyResizable:YES];
    [tv setHorizontallyResizable:NO];
    [tv setAutoresizingMask:NSViewWidthSizable];
    [[tv textContainer] setContainerSize:NSMakeSize(cs.width, FLT_MAX)];
    [[tv textContainer] setWidthTracksTextView:YES];
    [tv setTextContainerInset:NSMakeSize(6.0, 6.0)];
    [tv setEditable:NO];
    [tv setRichText:YES];
    [scroll setDocumentView:tv];
    self.transcript = tv;
    self.scroll = scroll;

    // Inline choice chips for ask_user. Hidden until a multiple-choice question
    // arrives; sits directly above the input row and scrolls horizontally so a
    // long option list never pushes the input box off-screen.
    NSScrollView *optScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 44, 304, 0)];
    [optScroll setHasHorizontalScroller:NO];
    [optScroll setHasVerticalScroller:NO];
    [optScroll setDrawsBackground:NO];
    [optScroll setBorderType:NSNoBorder];
    [optScroll setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [optScroll setHidden:YES];

    NSStackView *optStack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 304, 28)];
    [optStack setOrientation:NSUserInterfaceLayoutOrientationHorizontal];
    [optStack setAlignment:NSLayoutAttributeCenterY];
    [optStack setSpacing:6.0];
    [optStack setEdgeInsets:NSEdgeInsetsMake(0, 2, 0, 2)];
    [optScroll setDocumentView:optStack];
    self.optionsStack = optStack;
    self.optionsScroll = optScroll;

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 8, 234, 28)];
    [field setPlaceholderString:@"Ask Claude…"];
    [field setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [field setTarget:self];
    [field setAction:@selector(send:)];
    self.inputField = field;

    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(250, 8, 62, 28)];
    [button setTitle:@"Send"];
    [button setBezelStyle:NSBezelStyleRounded];
    [button setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [button setTarget:self];
    [button setAction:@selector(send:)];
    self.sendButton = button;

    [container addSubview:scroll];
    [container addSubview:optScroll];
    [container addSubview:field];
    [container addSubview:button];
    self.view = container;
}

// Lay out transcript + chip strip. When chips are visible the transcript
// shrinks to make room for the strip just above the input row.
- (void)layoutOptionsVisible:(BOOL)visible {
    CGFloat stripH = visible ? 36.0 : 0.0;
    CGFloat inputTop = 44.0;
    NSRect b = self.view.bounds;

    NSRect optFrame = NSMakeRect(8, inputTop, b.size.width - 16, stripH);
    [self.optionsScroll setFrame:optFrame];
    [self.optionsScroll setHidden:!visible];

    CGFloat scrollY = inputTop + stripH;
    NSRect scrollFrame = NSMakeRect(8, scrollY, b.size.width - 16, b.size.height - scrollY - 8);
    [self.scroll setFrame:scrollFrame];
}

#pragma mark - Transcript

- (void)appendRole:(NSString *)role text:(NSString *)text {
    NSFont *bold = [NSFont boldSystemFontOfSize:12];
    NSFont *body = [NSFont systemFontOfSize:12];
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];
    [line appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@\n", role]
            attributes:@{NSFontAttributeName: bold}]];
    [line appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@\n\n", text]
            attributes:@{NSFontAttributeName: body}]];
    [[self.transcript textStorage] appendAttributedString:line];
    [self.transcript scrollRangeToVisible:NSMakeRange([[self.transcript string] length], 0)];
}

- (void)appendNote:(NSString *)text {
    NSFont *note = [NSFont systemFontOfSize:11];
    NSDictionary *attrs = @{NSFontAttributeName: note,
                            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    NSAttributedString *line = [[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@\n\n", text] attributes:attrs];
    [[self.transcript textStorage] appendAttributedString:line];
    [self.transcript scrollRangeToVisible:NSMakeRange([[self.transcript string] length], 0)];
}

#pragma mark - Thinking indicator

// Show an animated "Claude is thinking…" line at the end of the transcript and
// tick it until the reply arrives. The text lives at thinkingLocation so each
// tick can rewrite it in place and stopThinking can delete it cleanly.
- (void)startThinking {
    [self stopThinking];   // never stack two indicators
    self.thinkingLocation = [[self.transcript string] length];
    self.thinkingTick = 0;
    [self renderThinking];
    self.thinkingTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                          target:self
                                                        selector:@selector(tickThinking:)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)tickThinking:(NSTimer *)timer {
    (void)timer;
    self.thinkingTick++;
    [self renderThinking];
}

- (void)renderThinking {
    NSUInteger total = [[self.transcript string] length];
    if (self.thinkingLocation > total) {
        return;   // transcript was reset out from under us
    }
    NSString *dots = [@"..." substringToIndex:(self.thinkingTick % 4)];
    NSUInteger seconds = (NSUInteger)(self.thinkingTick * 0.4);
    NSString *elapsed = seconds > 0 ? [NSString stringWithFormat:@" (%lus)", (unsigned long)seconds] : @"";
    NSString *text = [NSString stringWithFormat:@"Claude is thinking%@%@\n\n", dots, elapsed];

    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11],
                            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    NSAttributedString *line = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    NSRange r = NSMakeRange(self.thinkingLocation, total - self.thinkingLocation);
    [[self.transcript textStorage] replaceCharactersInRange:r withAttributedString:line];
    [self.transcript scrollRangeToVisible:NSMakeRange([[self.transcript string] length], 0)];
}

- (void)stopThinking {
    if (!self.thinkingTimer) {
        return;
    }
    [self.thinkingTimer invalidate];
    self.thinkingTimer = nil;
    NSUInteger total = [[self.transcript string] length];
    if (total > self.thinkingLocation) {
        [[self.transcript textStorage] deleteCharactersInRange:
            NSMakeRange(self.thinkingLocation, total - self.thinkingLocation)];
    }
}

#pragma mark - Send

- (void)send:(id)sender {
    (void)sender;
    NSString *text = [[self.inputField stringValue]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // A multiple-choice question is on screen: Send submits a typed custom
    // answer. If chips are showing, ignore a blank Send so a stray Enter
    // doesn't submit nothing — nudge the user to pick a chip or type.
    if (self.askPending) {
        BOOL hasChips = (self.optionsStack.arrangedSubviews.count > 0);
        if (text.length == 0 && hasChips) {
            return;
        }
        [self submitAnswer:text];
        return;
    }

    if (self.busy) {
        return;
    }
    if (text.length == 0) {
        return;
    }
    if (!self.rootURL) {
        [self appendNote:@"Open a folder first — that's where Claude will work."];
        return;
    }
    [self.inputField setStringValue:@""];
    [self appendRole:@"You" text:text];
    [self setBusy:YES];
    [self runTurnWithPrompt:text];
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    [self.sendButton setEnabled:!busy];
    [self.inputField setEnabled:!busy];
}

#pragma mark - CLI turn

// Locate the `claude` binary. A GUI app launched via Finder/`open` inherits a
// minimal PATH, so we probe the usual install locations directly.
- (NSString *)claudePath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();
    NSArray *candidates = @[
        [home stringByAppendingPathComponent:@".local/bin/claude"],
        @"/opt/homebrew/bin/claude",
        @"/usr/local/bin/claude",
        @"/usr/bin/claude",
    ];
    for (NSString *p in candidates) {
        if ([fm isExecutableFileAtPath:p]) {
            return p;
        }
    }
    return nil;
}

- (void)runTurnWithPrompt:(NSString *)prompt {
    NSString *cli = [self claudePath];
    if (!cli) {
        [self appendNote:@"Couldn't find the `claude` CLI. Install Claude Code and run "
                         @"`claude login` to sign in with your subscription, then relaunch."];
        [self setBusy:NO];
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:cli];

    NSString *systemPrompt =
        @"You are embedded in a minimal macOS IDE. Make focused changes to files "
        @"in the working directory and briefly explain what you did.\n\n"
        @"When you need the user to make a real decision or resolve an ambiguity, "
        @"ask a multiple-choice question instead of guessing. To do that, reply "
        @"with ONLY a fenced code block labeled ask_user containing JSON, and "
        @"nothing else in that turn:\n"
        @"```ask_user\n"
        @"{\"question\": \"Which database should I use?\", \"options\": [\"SQLite\", \"Postgres\"]}\n"
        @"```\n"
        @"The IDE renders each option as a clickable button and sends the user's "
        @"choice back as the next message. The user may also type a custom answer. "
        @"Use this only for genuine decisions — don't over-ask.";
    NSMutableArray *args = [@[@"-p", prompt,
                             @"--output-format", @"json",
                             // Full agent powers: print mode can't prompt for
                             // approval, so bypass permission gating to give the
                             // embedded agent the same reach as Claude Code
                             // (Bash, Read, Write, Edit, …). This is a trusted,
                             // single-user IDE running on the user's machine.
                             @"--permission-mode", @"bypassPermissions",
                             @"--append-system-prompt", systemPrompt] mutableCopy];
    if (self.sessionID.length) {
        [args addObject:@"--resume"];
        [args addObject:self.sessionID];
    }
    task.arguments = args;
    task.currentDirectoryURL = self.rootURL;

    // Give the child a workable PATH so it can find node/helpers if needed.
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    NSString *home = NSHomeDirectory();
    NSString *existing = env[@"PATH"] ?: @"";
    env[@"PATH"] = [NSString stringWithFormat:
        @"%@/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:%@", home, existing];
    task.environment = env;

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    [self startThinking];

    __weak ClaudeChat *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *launchErr = nil;
        if (![task launchAndReturnError:&launchErr]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf stopThinking];
                [weakSelf appendNote:[NSString stringWithFormat:
                    @"Failed to launch claude: %@", launchErr.localizedDescription]];
                [weakSelf setBusy:NO];
            });
            return;
        }

        // Drain both pipes concurrently so a full stderr buffer can't deadlock
        // the child while we block reading stdout.
        __block NSData *outData = nil;
        __block NSData *errData = nil;
        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t bg = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_group_async(group, bg, ^{
            outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        });
        dispatch_group_async(group, bg, ^{
            errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        });
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        [task waitUntilExit];
        int status = task.terminationStatus;

        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleCLIOutput:outData errorData:errData status:status];
        });
    });
}

- (void)handleCLIOutput:(NSData *)outData errorData:(NSData *)errData status:(int)status {
    [self stopThinking];

    NSDictionary *json = nil;
    if (outData.length) {
        id parsed = [NSJSONSerialization JSONObjectWithData:outData options:0 error:NULL];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            json = parsed;
        }
    }

    if (!json) {
        NSString *errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
        NSString *msg = errStr.length ? errStr : (outStr.length ? outStr : @"no output");
        [self appendNote:[NSString stringWithFormat:@"claude CLI error (exit %d): %@",
            status, [msg stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]]]];
        [self setBusy:NO];
        return;
    }

    NSString *sid = json[@"session_id"];
    if ([sid isKindOfClass:[NSString class]] && sid.length) {
        self.sessionID = sid;
    }

    NSString *result = [json[@"result"] isKindOfClass:[NSString class]] ? json[@"result"] : @"";
    BOOL isError = [json[@"is_error"] boolValue];

    if (isError) {
        [self appendNote:[NSString stringWithFormat:@"Claude error: %@",
            result.length ? result : @"unknown error"]];
        [self setBusy:NO];
        return;
    }

    // The CLI may have edited files before responding; refresh the browser.
    if ([self.delegate respondsToSelector:@selector(claudeChatDidModifyFiles)]) {
        [self.delegate claudeChatDidModifyFiles];
    }

    // If Claude is asking a multiple-choice question, render chips instead of
    // printing the raw JSON, and wait for the user's choice.
    NSDictionary *ask = [self parseAskUserFromText:result];
    if (ask) {
        [self setBusy:NO];
        [self beginAskUserWithQuestion:ask[@"question"] options:ask[@"options"]];
        return;
    }

    [self appendRole:@"Claude" text:result.length ? result : @"(no text)"];
    [self setBusy:NO];
}

#pragma mark - Multiple-choice question (ask_user)

// Extract an ask_user request from Claude's reply. Accepts either a fenced
// ```ask_user … ``` block or a bare JSON object with a "question" field.
// Returns @{ @"question": NSString, @"options": NSArray<NSString> } or nil.
- (NSDictionary *)parseAskUserFromText:(NSString *)text {
    if (text.length == 0) {
        return nil;
    }
    NSString *jsonStr = nil;
    NSRange fence = [text rangeOfString:@"```ask_user"];
    if (fence.location != NSNotFound) {
        NSUInteger start = fence.location + fence.length;
        NSRange after = NSMakeRange(start, text.length - start);
        NSRange close = [text rangeOfString:@"```" options:0 range:after];
        jsonStr = (close.location != NSNotFound)
            ? [text substringWithRange:NSMakeRange(start, close.location - start)]
            : [text substringFromIndex:start];
    } else {
        NSString *trimmed = [text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"{"] && [trimmed containsString:@"\"question\""]) {
            jsonStr = trimmed;
        }
    }
    if (jsonStr == nil) {
        return nil;
    }
    jsonStr = [jsonStr stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    id obj = [NSJSONSerialization JSONObjectWithData:
        [jsonStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *q = obj[@"question"];
    if (![q isKindOfClass:[NSString class]] || q.length == 0) {
        return nil;
    }
    NSMutableArray *opts = [NSMutableArray array];
    if ([obj[@"options"] isKindOfClass:[NSArray class]]) {
        for (id o in obj[@"options"]) {
            if ([o isKindOfClass:[NSString class]]) {
                [opts addObject:o];
            }
        }
    }
    return @{@"question": q, @"options": opts};
}

// Show the question + clickable chips and arm the input for a custom answer.
- (void)beginAskUserWithQuestion:(NSString *)question options:(NSArray *)options {
    [self appendRole:@"Claude" text:question];
    self.askPending = YES;

    for (NSView *v in [self.optionsStack.arrangedSubviews copy]) {
        [self.optionsStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (options.count > 0) {
        for (NSString *opt in options) {
            NSButton *chip = [[NSButton alloc] initWithFrame:NSZeroRect];
            [chip setTitle:opt];
            [chip setBezelStyle:NSBezelStyleRounded];
            [chip setControlSize:NSControlSizeSmall];
            [chip setFont:[NSFont systemFontOfSize:11]];
            [chip setTarget:self];
            [chip setAction:@selector(optionChipClicked:)];
            [chip sizeToFit];
            [self.optionsStack addArrangedSubview:chip];
        }
        [self layoutOptionsVisible:YES];
        [self.inputField setPlaceholderString:@"Or type a custom response…"];
    } else {
        [self layoutOptionsVisible:NO];
        [self.inputField setPlaceholderString:@"Type your response…"];
    }
    [[self.view window] makeFirstResponder:self.inputField];
}

- (void)optionChipClicked:(NSButton *)sender {
    if (!self.askPending) {
        return;
    }
    [self submitAnswer:[sender title]];
}

// Tear down the chip strip, log the answer, and send it as the next turn.
- (void)submitAnswer:(NSString *)answer {
    self.askPending = NO;

    for (NSView *v in [self.optionsStack.arrangedSubviews copy]) {
        [self.optionsStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self layoutOptionsVisible:NO];
    [self.inputField setPlaceholderString:@"Ask Claude…"];
    [self.inputField setStringValue:@""];

    [self appendNote:[NSString stringWithFormat:@"You answered: %@",
        answer.length ? answer : @"(empty)"]];
    [self setBusy:YES];
    [self runTurnWithPrompt:answer];
}

@end
