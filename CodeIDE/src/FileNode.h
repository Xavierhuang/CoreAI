#import <Foundation/Foundation.h>

// A lazily-populated node in the file tree. Directories load their children
// on first access (dotfiles excluded), sorted folders-first then by name.
@interface FileNode : NSObject

@property (nonatomic, strong, readonly) NSURL *url;
@property (nonatomic, assign, readonly) BOOL isDirectory;
@property (nonatomic, copy, readonly) NSString *name;

- (instancetype)initWithURL:(NSURL *)url isDirectory:(BOOL)isDir;

- (NSArray<FileNode *> *)children;   // lazy; @[] for files
- (BOOL)isExpandable;
- (void)invalidateChildren;          // drop cache so next access re-reads disk

@end
