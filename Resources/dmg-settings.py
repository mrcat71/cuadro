# dmgbuild settings for the release disk image: Cuadro on the left, a link to Applications on
# the right and an arrow between them, so installing is one drag. `make dist` passes the app
# with `-D app=build/Cuadro.app`; dmgbuild provides `defines`.
import os.path

application = defines.get("app", "build/Cuadro.app")  # noqa: F821
app_name = os.path.basename(application)

format = "ULFO"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")

# The built-in arrow is a 640 × 240 pt picture with the arrow at its center; the window and the
# icon positions follow it.
background = "builtin-arrow"
window_rect = ((200, 200), (640, 280))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {app_name: (140, 120), "Applications": (500, 120)}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
