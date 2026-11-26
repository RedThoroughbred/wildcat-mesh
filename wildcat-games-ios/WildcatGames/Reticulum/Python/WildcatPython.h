// Wildcat Mesh: the embedded CPython that runs the Reticulum stack.
// Copyright (C) 2026 Seth Egger. GPL-3.0-or-later.
//
// The whole C surface between the app and Python. Swift starts the interpreter on a thread of its
// own (wc_python_run never returns while the bridge runs), submits commands as JSON from any thread,
// and gets events back as JSON through a callback. The RNode pipe moves raw KISS bytes between
// Reticulum's RNodeInterface and the app's Bluetooth link (RNodeLink).
//
// Nothing here includes Python.h, so Swift's importer never sees CPython's headers.
#ifndef WILDCAT_PYTHON_H
#define WILDCAT_PYTHON_H

#include <stddef.h>
#include <stdint.h>

/// An event from the bridge: one JSON object, UTF-8. Called on a Python thread with the GIL held:
/// copy the string and return; never call back into Python from here.
typedef void (*wc_event_fn)(const char *json);

/// Bytes Reticulum wants written to the RNode. Called on a Python thread with the GIL held.
typedef void (*wc_bytes_fn)(const uint8_t *bytes, size_t length);

/// Set both callbacks before wc_python_run.
void wc_set_handlers(wc_event_fn on_event, wc_bytes_fn on_rnode_write);

/// Initialises the interpreter (the standard library in `python_home`, `app_packages` as a site
/// directory, `app_path` first on sys.path) and runs the bridge's command loop on the calling thread,
/// which becomes Python's main thread. Blocks until the loop ends. 0 on a clean end; negative if
/// Python couldn't start (the reason also arrives as an error event).
int wc_python_run(const char *python_home, const char *app_packages, const char *app_path);

/// Any thread: queue a command (a JSON object) for the bridge. 0 when queued, -1 when Python isn't
/// running yet, -2 when the bridge refused it.
int wc_python_submit(const char *json);

/// The RNode link is up and handed to Reticulum (1) or not (0). Dropping it also drops unread bytes.
void wc_rnode_set_connected(int connected);

/// Bytes from the RNode (Bluetooth notifications), queued for Reticulum to read.
void wc_rnode_push(const uint8_t *bytes, size_t length);

/// Bytes from the RNode waiting for Reticulum (for tests and diagnostics).
size_t wc_rnode_pending(void);

#endif
