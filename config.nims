# Copyright 2023 Geoffrey Picron.
# SPDX-License-Identifier: (MIT or Apache-2.0)

switch("nimcache","./cache")

when defined(macosx):
    switch("passL", "-framework AppKit")
    switch("passL", "-framework WebKit")
    switch("passL", "-framework Cocoa")
    switch("passL", "-framework Foundation")
