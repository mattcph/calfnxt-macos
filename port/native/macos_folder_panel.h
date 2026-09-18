// calfNXT macOS — native folder chooser (NSOpenPanel) for the Impulse
// IR library browser.
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//
// The WebEditor intercepts {t:"ir",cmd:"browse"} and opens an NSOpenPanel
// in-process.

#pragma once

#include <functional>
#include <string>

namespace calfNXT {
namespace Ui {

/** Show an NSOpenPanel in choose-directory mode on the main thread.
    The callback runs on the main thread with the chosen POSIX path,
    or an empty string when the user cancels. */
void showFolderPanelAsync(std::function<void(const std::string& path)> callback);

} // namespace Ui
} // namespace calfNXT
