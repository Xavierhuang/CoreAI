#import <Cocoa/Cocoa.h>

@class EditorWindowController;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) NSMutableArray *controllers;   // open windows

- (void)newWindow:(id)sender;

@end
