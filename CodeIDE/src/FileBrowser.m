#import "FileBrowser.h"
#import "FileNode.h"

@interface FileBrowser ()
@property (nonatomic, strong, readwrite) NSOutlineView *outlineView;
@property (nonatomic, strong) FileNode *rootNode;
@end

@implementation FileBrowser

- (instancetype)initWithOutlineView:(NSOutlineView *)outlineView {
    self = [super init];
    if (self) {
        _outlineView = outlineView;
        outlineView.dataSource = self;
        outlineView.delegate = self;
    }
    return self;
}

- (void)setRootURL:(NSURL *)url {
    self.rootNode = [[FileNode alloc] initWithURL:url isDirectory:YES];
    [self.outlineView reloadData];
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    (void)outlineView;
    FileNode *node = item ?: self.rootNode;
    return node ? (NSInteger)node.children.count : 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    (void)outlineView;
    FileNode *node = item ?: self.rootNode;
    return node.children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    (void)outlineView;
    return [(FileNode *)item isExpandable];
}

#pragma mark - NSOutlineViewDelegate

- (NSView *)outlineView:(NSOutlineView *)outlineView
     viewForTableColumn:(NSTableColumn *)tableColumn
                   item:(id)item {
    (void)tableColumn;
    FileNode *node = (FileNode *)item;

    NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"FileCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
        cell.identifier = @"FileCell";

        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:iv];
        cell.imageView = iv;

        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:tf];
        cell.textField = tf;

        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [iv.widthAnchor constraintEqualToConstant:16],
            [iv.heightAnchor constraintEqualToConstant:16],
            [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    cell.textField.stringValue = node.name;
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:node.url.path];
    if (icon) {
        icon.size = NSMakeSize(16, 16);
        cell.imageView.image = icon;
    }
    return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    NSOutlineView *outline = (NSOutlineView *)notification.object;
    NSInteger row = outline.selectedRow;
    if (row < 0) {
        return;
    }
    FileNode *node = [outline itemAtRow:row];
    if (node && !node.isDirectory) {
        if ([self.delegate respondsToSelector:@selector(fileBrowserDidSelectFile:)]) {
            [self.delegate fileBrowserDidSelectFile:node.url];
        }
    }
}

@end
