// calfNXT macOS — native folder chooser (NSOpenPanel) for the Impulse
// IR library browser.
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.

#import <Cocoa/Cocoa.h>

#include "macos_folder_panel.h"

namespace calfNXT {
namespace Ui {

void showFolderPanelAsync(std::function<void(const std::string& path)> callback)
{
  // Always hop to the main queue: the panel must run on the main thread, and
  // deferring out of the WKScriptMessage handler avoids re-entrancy.
  dispatch_async(dispatch_get_main_queue(), ^{
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = NSLocalizedString(@"Choose Library", @"IR library panel prompt");
    panel.message = NSLocalizedString(@"Choose the impulse response library folder",
                                      @"IR library panel message");
    const NSModalResponse response = [panel runModal];
    if (response == NSModalResponseOK && panel.URL.path.length > 0)
      callback(std::string(panel.URL.path.UTF8String));
    else
      callback(std::string());
  });
}

} // namespace Ui
} // namespace calfNXT
