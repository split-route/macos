# dmgbuild settings: dmgbuild -s dmg-settings.py -D app=<Splitroute.app> -D background=<bg.tiff> Splitroute <out.dmg>
# Window and icon geometry must match background.swift.
import os

app = defines["app"]
format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]

# window_rect is the whole frame: background (320) + title bar, path bar and
# status bar (~88). The bars are a global Finder setting; without them the
# window just has extra white space below the icons.
window_rect = ((200, 200), (560, 408))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (150, 142),
    "Applications": (410, 142),
}
