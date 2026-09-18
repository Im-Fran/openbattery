# dmgbuild settings for the OpenBattery disk image.
#
# The Finder route (AppleScript setting `background picture`) is silently
# ignored on current macOS: the assignment raises no error and nothing lands in
# .DS_Store. dmgbuild writes .DS_Store itself, so the window is recorded without
# the Finder being involved at all.
#
# Paths come from -D defines so the lane can pass absolute ones.

import os.path

application = defines["app"]
appname = os.path.basename(application)

format = "UDZO"
compression_level = 9
size = None

files = [application]
symlinks = {"Applications": "/Applications"}

background = defines["background"]

# Window content is 640x400, the size of the background image.
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 12
icon_size = 128

icon_locations = {
    appname: (160, 190),
    "Applications": (480, 190),
}
