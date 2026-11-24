# dmgbuild settings for the Lumora installer window.
# Invoked by Scripts/make-dmg.sh: dmgbuild -s Scripts/dmg-settings.py -D app=... -D background=... Lumora dmg
import os.path

application = defines["app"]  # noqa: F821 - injected by dmgbuild
app_name = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
compression_level = 9
size = None

files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

icon_locations = {
    app_name: (170, 190),
    "Applications": (490, 190),
}

background = defines["background"]  # noqa: F821
window_rect = ((200, 120), (660, 420))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
icon_size = 128
text_size = 13
arrange_by = None
label_pos = "bottom"
