#import "FileNode.h"

@interface FileNode ()
@property (nonatomic, strong) NSArray<FileNode *> *cachedChildren;
@end

@implementation FileNode

- (instancetype)initWithURL:(NSURL *)url isDirectory:(BOOL)isDir {
    self = [super init];
    if (self) {
        _url = url;
        _isDirectory = isDir;
        _name = [url lastPathComponent];
    }
    return self;
}

- (BOOL)isExpandable {
    return self.isDirectory;
}

- (void)invalidateChildren {
    self.cachedChildren = nil;
}

- (NSArray<FileNode *> *)children {
    if (!self.isDirectory) {
        return @[];
    }
    if (self.cachedChildren) {
        return self.cachedChildren;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSURLResourceKey> *keys = @[NSURLIsDirectoryKey, NSURLNameKey];
    NSArray<NSURL *> *contents =
        [fm contentsOfDirectoryAtURL:self.url
          includingPropertiesForKeys:keys
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                               error:NULL];

    NSMutableArray<FileNode *> *nodes = [NSMutableArray array];
    for (NSURL *child in contents) {
        NSNumber *isDirNum = nil;
        [child getResourceValue:&isDirNum forKey:NSURLIsDirectoryKey error:NULL];
        FileNode *node = [[FileNode alloc] initWithURL:child
                                           isDirectory:[isDirNum boolValue]];
        [nodes addObject:node];
    }

    // Folders first, then case-insensitive name order.
    [nodes sortUsingComparator:^NSComparisonResult(FileNode *a, FileNode *b) {
        if (a.isDirectory != b.isDirectory) {
            return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];

    self.cachedChildren = nodes;
    return nodes;
}

@end
