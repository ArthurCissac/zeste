# Réglages dmgbuild pour Zeste.dmg (mise en page écrite directement, sans piloter le Finder).
# Valeurs passées par -D : app, icon, bg. Positions en phase avec make-dmg-background.swift.
app = defines["app"]

format = "UDZO"
compression_level = 9
size = None
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
badge_icon = None

background = defines["bg"]
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
window_rect = ((200, 120), (660, 420))
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 112
icon_locations = {
    "Zeste.app": (175, 200),
    "Applications": (485, 200),
}
