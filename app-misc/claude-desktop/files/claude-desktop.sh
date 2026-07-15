#!/bin/sh
# Launcher for the official Claude Desktop Linux build.
#
# Upstream targets X11/XWayland. Set CLAUDE_USE_WAYLAND=1 to run natively on
# Wayland; the Quick Entry global hotkey then needs your desktop environment's
# GlobalShortcuts portal.
if [ "${CLAUDE_USE_WAYLAND}" = "1" ] && [ -n "${WAYLAND_DISPLAY}" ]; then
	set -- --ozone-platform-hint=auto \
		--enable-features=WaylandWindowDecorations,GlobalShortcutsPortal \
		"$@"
fi
exec /usr/lib/claude-desktop/claude-desktop "$@"
