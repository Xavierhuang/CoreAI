APP_NAME  = CodeIDE
BUNDLE    = $(APP_NAME).app
CONTENTS  = $(BUNDLE)/Contents
BIN       = $(CONTENTS)/MacOS/$(APP_NAME)

SRC       = src/main.m src/AppDelegate.m src/EditorWindowController.m \
            src/FileBrowser.m src/FileNode.m src/ClaudeChat.m
HDR       = src/AppDelegate.h src/EditorWindowController.h \
            src/FileBrowser.h src/FileNode.h src/ClaudeChat.h

CC        = clang
CFLAGS    = -fobjc-arc -Wall -Wextra -O2
FRAMEWORKS = -framework Cocoa

all: $(BIN)

$(BIN): $(SRC) $(HDR) Info.plist
	@mkdir -p $(CONTENTS)/MacOS
	@mkdir -p $(CONTENTS)/Resources
	cp Info.plist $(CONTENTS)/Info.plist
	$(CC) $(CFLAGS) $(FRAMEWORKS) -o $(BIN) $(SRC)

run: all
	open $(BUNDLE)

clean:
	rm -rf $(BUNDLE)

.PHONY: all run clean
