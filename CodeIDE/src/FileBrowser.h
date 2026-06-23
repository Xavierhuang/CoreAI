#import <Cocoa/Cocoa.h>

@protocol FileBrowserDelegate <NSObject>
- (void)fileBrowserDidSelectFile:(NSURL *)url;
@end

// Drives an NSOutlineView as a lazy folder/file tree rooted at a directory.
@interface FileBrowser : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>

@property (nonatomic, strong, readonly) NSOutlineView *outlineView;
@property (nonatomic, weak) id<FileBrowserDelegate> delegate;

- (instancetype)initWithOutlineView:(NSOutlineView *)outlineView;
- (void)setRootURL:(NSURL *)url;

@end
