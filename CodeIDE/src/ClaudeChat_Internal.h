#import "ClaudeChat.h"

// Private surface for ClaudeChat.m. Not part of the public API.
//
// The panel talks to Claude by shelling out to the `claude` CLI in print mode
// (`claude -p … --output-format json`). That path uses the user's Claude
// subscription via their `claude login` OAuth session — NOT a pay-per-use
// ANTHROPIC_API_KEY. The CLI runs its own agentic loop with built-in file
// tools, scoped to the project root we pass as its working directory.
@interface ClaudeChat ()

@property (nonatomic, strong, readwrite) NSView *view;
@property (nonatomic, strong) NSTextView *transcript;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSTextField *inputField;
@property (nonatomic, strong) NSButton *sendButton;
@property (nonatomic, assign) BOOL busy;

// Inline multiple-choice question ("ask_user"). When askPending is YES a
// question is on screen: the chip strip shows clickable options and Send
// submits a typed custom answer. The chosen answer becomes the next turn.
@property (nonatomic, strong) NSStackView *optionsStack;     // clickable choice chips
@property (nonatomic, strong) NSScrollView *optionsScroll;   // wraps the chip strip
@property (nonatomic, assign) BOOL askPending;

// Threads multi-turn continuity: captured from each CLI result and passed back
// via `--resume` so the conversation (and Claude's context) persists.
@property (nonatomic, copy) NSString *sessionID;

// Animated "Claude is thinking…" indicator shown while a turn is in flight.
// thinkingLocation marks where the indicator text begins in the transcript so
// it can be redrawn each tick and removed cleanly when the reply arrives.
@property (nonatomic, strong) NSTimer *thinkingTimer;
@property (nonatomic, assign) NSUInteger thinkingLocation;
@property (nonatomic, assign) NSUInteger thinkingTick;

// Transcript helpers.
- (void)appendRole:(NSString *)role text:(NSString *)text;
- (void)appendNote:(NSString *)text;

@end
