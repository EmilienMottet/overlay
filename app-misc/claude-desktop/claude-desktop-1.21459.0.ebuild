# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit desktop linux-info pax-utils unpacker xdg

DESCRIPTION="Official Claude desktop app for Linux (Chat, Cowork, Claude Code)"
HOMEPAGE="https://claude.ai https://code.claude.com/docs/en/desktop-linux"
SRC_URI="https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/${PN}/${PN}_${PV}_amd64.deb"
S="${WORKDIR}"

LICENSE="all-rights-reserved"
SLOT="0"
KEYWORDS="-* ~amd64"
IUSE="+appindicator +cowork"
RESTRICT="bindist mirror splitdebug strip test"

# From the .deb's Depends/Recommends plus the ELF's actual NEEDED set.
# Cowork runs its agent in a KVM microVM: the client execs
# qemu-system-x86_64 from PATH, probes virtiofsd at /usr/libexec/virtiofsd
# (where Gentoo installs it) and OVMF firmware at /usr/share/OVMF/ (Debian
# layout -- bridged by the compat symlinks installed below).
RDEPEND="
	app-accessibility/at-spi2-core:2
	app-crypt/libsecret
	app-misc/ca-certificates
	dev-libs/expat
	dev-libs/glib:2
	dev-libs/nspr
	>=dev-libs/nss-3.26
	media-libs/alsa-lib
	media-libs/mesa[gbm(+)]
	net-print/cups
	sys-apps/dbus
	sys-apps/util-linux
	sys-apps/xdg-desktop-portal
	sys-libs/glibc
	virtual/udev
	x11-libs/cairo
	x11-libs/gtk+:3
	x11-libs/libdrm
	x11-libs/libnotify
	x11-libs/libX11
	x11-libs/libXcomposite
	x11-libs/libXdamage
	x11-libs/libXext
	x11-libs/libXfixes
	x11-libs/libXrandr
	x11-libs/libXtst
	x11-libs/libxcb
	x11-libs/libxkbcommon
	x11-libs/pango
	x11-misc/xdg-utils
	appindicator? ( dev-libs/libayatana-appindicator )
	cowork? (
		app-emulation/qemu[qemu_softmmu_targets_x86_64(+)]
		app-emulation/virtiofsd
		|| ( sys-firmware/edk2-bin sys-firmware/edk2 )
	)
"
BDEPEND="$(unpacker_src_uri_depends)"

QA_PREBUILT="usr/lib/${PN}/*"

CLAUDE_HOME="/usr/lib/${PN}"

pkg_setup() {
	# All soft warnings: USER_NS for the Chromium namespace sandbox,
	# KVM + VHOST_VSOCK for the Cowork microVM.
	local CONFIG_CHECK="~USER_NS"
	use cowork && CONFIG_CHECK+=" ~KVM ~VHOST_VSOCK"
	linux-info_pkg_setup
}

src_install() {
	# Prebuilt Electron tree: cp -a keeps exec bits and symlinks intact.
	dodir /usr/lib
	cp -a usr/lib/${PN} "${ED}/usr/lib/" || die

	# SUID fallback sandbox; the userns sandbox is used where available.
	fperms 4711 "${CLAUDE_HOME}/chrome-sandbox"

	# Allow V8's JIT under PaX/hardened kernels.
	pax-mark m "${ED}${CLAUDE_HOME}/${PN}"

	# Upstream .desktop entry (StartupWMClass=com.anthropic.Claude) + icons.
	insinto /usr/share
	doins -r usr/share/applications usr/share/icons

	newbin "${FILESDIR}/${PN}.sh" ${PN}

	# The client resolves Cowork's OVMF firmware only at the Debian paths
	# (/usr/share/OVMF/OVMF_CODE{_4M,}.fd, VARS derived by substitution);
	# bridge them to Gentoo's edk2 layout, shared by edk2 and edk2-bin.
	if use cowork; then
		dosym -r /usr/share/edk2/OvmfX64/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd
		dosym -r /usr/share/edk2/OvmfX64/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd
	fi
}

pkg_postinst() {
	xdg_pkg_postinst

	if use cowork; then
		elog "Cowork runs its agent inside a KVM microVM. It needs:"
		elog "  - /dev/kvm and /dev/vhost-vsock accessible: add your user to the"
		elog "    'kvm' group (gpasswd -a <user> kvm)"
		elog "  - the vhost_vsock module: echo vhost_vsock > /etc/modules-load.d/${PN}.conf"
		elog "    (or modprobe vhost_vsock for the current boot)"
	fi
	elog
	elog "Wayland: upstream targets XWayland. Launch with CLAUDE_USE_WAYLAND=1"
	elog "for native Wayland (Quick Entry then needs the GlobalShortcuts portal)."
	elog
	elog "Sign in with a claude.ai subscription or your organization's SSO;"
	elog "Console API keys are not accepted by the desktop app."
	elog "~/.claude is shared with the Claude Code CLI, so signing in may"
	elog "update its login state."
}
