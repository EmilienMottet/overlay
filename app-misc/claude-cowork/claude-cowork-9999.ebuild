# Copyright 2025 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

PYTHON_COMPAT=( python3_{11..14} )

inherit desktop git-r3 python-any-r1 xdg

# Pinned prebuilt Electron runtime. The @ant native stubs and node-pty target
# the Electron 41 ABI (see upstream launch.sh), so this must stay on 41.x.
ELECTRON_PV="41.8.0"

DESCRIPTION="Claude Desktop with Cowork (local agent) support, Linux port"
HOMEPAGE="https://github.com/johnzfitch/claude-cowork-linux"
EGIT_REPO_URI="https://github.com/johnzfitch/claude-cowork-linux.git"

SRC_URI="
	https://github.com/electron/electron/releases/download/v${ELECTRON_PV}/electron-v${ELECTRON_PV}-linux-x64.zip
		-> electron-${ELECTRON_PV}-linux-x64.zip
"

# MIT: the Linux-port glue (stubs, patches, launcher) from this repository.
# all-rights-reserved: the Claude Desktop archive itself is proprietary
# Anthropic software, downloaded from Anthropic's CDN at build time.
LICENSE="MIT all-rights-reserved"
SLOT="0"
KEYWORDS=""
IUSE="+sandbox wayland"

# - network-sandbox: the proprietary Claude Desktop archive is fetched from
#   Anthropic's CDN during src_unpack (Anthropic does not permit redistribution
#   or mirroring -- see the project's COMPAT.md), so the build needs network.
# - mirror/bindist: never mirror or redistribute the proprietary blob.
# - strip/test: prebuilt binaries; there is no test suite.
RESTRICT="network-sandbox mirror bindist strip test"

# Runtime libraries for the bundled prebuilt Electron (Chromium), mirroring
# www-client/google-chrome, plus the tools the Cowork SDK and the launcher
# shell out to at runtime (curl, zstd, dbus, xdg-utils, bubblewrap).
RDEPEND="
	>=app-accessibility/at-spi2-core-2.46.0:2
	app-arch/zstd
	app-misc/ca-certificates
	dev-libs/expat
	dev-libs/glib:2
	dev-libs/nspr
	>=dev-libs/nss-3.26
	media-fonts/liberation-fonts
	media-libs/alsa-lib
	media-libs/mesa[gbm(+)]
	net-misc/curl
	net-print/cups
	sys-apps/dbus
	sys-libs/glibc
	sys-libs/libcap
	x11-libs/cairo
	x11-libs/gdk-pixbuf:2
	x11-libs/gtk+:3[wayland?]
	x11-libs/libdrm
	>=x11-libs/libX11-1.5.0
	x11-libs/libXcomposite
	x11-libs/libXdamage
	x11-libs/libXext
	x11-libs/libXfixes
	x11-libs/libXrandr
	x11-libs/libxcb
	x11-libs/libxkbcommon
	x11-libs/libxshmfence
	x11-libs/pango
	x11-misc/xdg-utils
	wayland? ( dev-libs/wayland )
	sandbox? ( sys-apps/bubblewrap )
"
DEPEND=""
# unzip extracts both the Electron release and the macOS .zip; python runs the
# bundled asar extractor and upstream's enable-cowork.py; curl fetches the blob.
BDEPEND="
	${PYTHON_DEPS}
	app-arch/unzip
	net-misc/curl
"

QA_PREBUILT="usr/lib/${PN}/electron/*"

# git-r3 checks the packaging repo out here.
S="${WORKDIR}/${P}"

# Where the app + electron land on the target system.
CLAUDE_INSTALLDIR="/usr/lib/${PN}"

pkg_pretend() {
	use amd64 || die "${PN} only provides an amd64 (x86_64) Electron build"
}

pkg_setup() {
	python-any-r1_pkg_setup
}

src_unpack() {
	# 1) The Linux-port packaging tree (stubs, patches, enable-cowork.py).
	git-r3_src_unpack

	# 2) The prebuilt Electron runtime (from SRC_URI / DISTDIR).
	mkdir -p "${WORKDIR}/electron" || die
	pushd "${WORKDIR}/electron" >/dev/null || die
	unpack "electron-${ELECTRON_PV}-linux-x64.zip"
	popd >/dev/null || die

	# 3) The proprietary Claude Desktop archive. Follow the version upstream
	#    declares supported in nix/package.nix (the maintainer bumps it after
	#    validating) rather than blindly grabbing the newest CDN release -- a
	#    too-new build breaks the minified-JS patches. Override with
	#    CLAUDE_COWORK_VERSION / CLAUDE_COWORK_URL if you know what you are doing.
	local pkgnix="${S}/nix/package.nix"
	local cver curl_url chash
	cver="${CLAUDE_COWORK_VERSION:-$(grep -oP 'claudeVersion \? "\K[^"]+' "${pkgnix}")}"
	curl_url="${CLAUDE_COWORK_URL:-$(grep -oP 'claudeUrl \? "\K[^"]+' "${pkgnix}")}"
	chash="$(grep -oP 'claudeHash \? "sha256-\K[^"]+' "${pkgnix}")"
	[[ -n ${curl_url} ]] || die "could not determine the Claude Desktop URL from ${pkgnix}"

	einfo "Fetching Claude Desktop ${cver} from Anthropic's CDN ..."
	einfo "  ${curl_url}"
	curl -fSL --retry 3 -o "${WORKDIR}/Claude.zip" "${curl_url}" \
		|| die "failed to download the Claude Desktop archive"

	# Best-effort integrity check against the SRI hash recorded upstream.
	if [[ -z ${CLAUDE_COWORK_URL} && -n ${chash} ]]; then
		local want got
		want="$(printf '%s' "${chash}" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')"
		got="$(sha256sum "${WORKDIR}/Claude.zip" | cut -d' ' -f1)"
		if [[ -n ${want} && ${want} != "${got}" ]]; then
			die "Claude Desktop archive checksum mismatch (want ${want}, got ${got})"
		fi
		einfo "Claude Desktop archive checksum verified (sha256 ${got})"
	fi

	export _CLAUDE_VER="${cver}"
}

src_prepare() {
	eapply_user

	local repo="${S}"
	local app="${WORKDIR}/app"
	local dmg="${WORKDIR}/dmg"

	# Unpack the macOS .zip. Recent Claude releases ship .zip; older LZFSE .dmg
	# images cannot be opened by unzip/p7zip, which is why we fetch the .zip URL.
	mkdir -p "${dmg}" || die
	unzip -q "${WORKDIR}/Claude.zip" -d "${dmg}" || die "failed to unzip Claude archive"

	local claude_app app_asar res
	claude_app="$(find "${dmg}" -maxdepth 3 -name '*.app' -type d | head -1)"
	[[ -n ${claude_app} ]] || die "Claude.app not found in archive"
	app_asar="${claude_app}/Contents/Resources/app.asar"
	res="${claude_app}/Contents/Resources"
	[[ -f ${app_asar} ]] || die "app.asar not found at ${app_asar}"

	# Stash the icon for src_install (claude_app is local to this phase).
	[[ -f ${res}/AppIcon.icns ]] && cp "${res}/AppIcon.icns" "${WORKDIR}/AppIcon.icns"

	# Extract the asar (and its .unpacked native blobs) with our zero-dep tool.
	einfo "Extracting app.asar ..."
	"${EPYTHON}" "${FILESDIR}/asar.py" extract "${app_asar}" "${app}" \
		|| die "asar extract failed"

	# Copy DMG resources/ (i18n JSON, icons, ...) except the asar payloads.
	mkdir -p "${app}/resources" || die
	local item name
	for item in "${res}"/*; do
		name="$(basename "${item}")"
		case "${name}" in
			app.asar|app.asar.unpacked) continue ;;
		esac
		cp -r "${item}" "${app}/resources/${name}" || die
	done

	# --- Bake in the Linux-port stubs (mirrors upstream launch.sh/PKGBUILD) ---
	einfo "Baking Linux-port stubs ..."
	mkdir -p "${app}/node_modules/@ant/claude-swift/js" \
	         "${app}/node_modules/@ant/claude-native" \
	         "${app}/cowork" || die
	cp -f "${repo}/stubs/@ant/claude-swift/js/index.js" \
	      "${app}/node_modules/@ant/claude-swift/js/index.js" || die
	cp -f "${repo}/stubs/@ant/claude-native/index.js" \
	      "${app}/node_modules/@ant/claude-native/index.js" || die
	cp -f "${repo}/stubs/frame-fix/frame-fix-entry.js" "${app}/frame-fix-entry.js" || die
	cp -f "${repo}/stubs/frame-fix/frame-fix-wrapper.js" "${app}/frame-fix-wrapper.js" || die
	cp -f "${repo}"/stubs/cowork/*.js "${app}/cowork/" || die
	cp -f "${repo}"/stubs/cowork/*.sh "${app}/cowork/" 2>/dev/null

	# Optional Linux node-pty build (absent in tagged releases -> the PTY panel
	# stays on the inert macOS binary, but the app still launches).
	if [[ -f ${repo}/stubs/node-pty-linux/pty.node ]]; then
		local ptydest="${app}/node_modules/node-pty/build/Release"
		[[ -d ${ptydest} ]] && cp -f "${repo}/stubs/node-pty-linux/pty.node" "${ptydest}/pty.node"
	fi

	# --- Linux-port wiring (mirrors upstream PKGBUILD build()) ---
	einfo "Applying Linux-port patches ..."
	local idx="${app}/.vite/build/index.js"
	local mainview="${app}/.vite/build/mainView.js"
	local pkgjson="${app}/package.json"

	# Trampoline: pin resourcesPath to our install layout, then hand off to the
	# frame-fix entry point (which adds native Linux window frames).
	cat > "${app}/trampoline.js" <<-JSEOF || die
		Object.defineProperty(process, 'resourcesPath', {
		    value: '${EPREFIX}${CLAUDE_INSTALLDIR}/app/resources',
		    writable: true,
		    configurable: true,
		    enumerable: true,
		});
		require('./frame-fix-entry.js');
	JSEOF

	if grep -q '"main":.*"\.vite/build/index\.pre\.js"' "${pkgjson}"; then
		sed -i 's|"main":.*"\.vite/build/index\.pre\.js"|"main": "trampoline.js"|' "${pkgjson}" || die
	else
		ewarn "asar entry-point patch skipped (target not found)"
	fi

	# Strip macOS titlebar options (Vite ESM bypasses the wrapper require-proxy).
	if grep -q 'titleBarOverlay' "${idx}"; then
		sed -i 's/titleBarStyle:"hidden",titleBarOverlay:[A-Za-z0-9_]\+,trafficLightPosition:[A-Za-z0-9_]\+,//g' "${idx}" || die
		sed -i 's/titleBarStyle:"hiddenInset",autoHideMenuBar:!0,skipTaskbar:!0/autoHideMenuBar:!0/g' "${idx}" || die
	else
		ewarn "titlebar patch skipped (target not found)"
	fi

	# Drop the isPackaged check on file:// preloads (else the renderer shell
	# never loads).
	if grep -qE 'e\.protocol==="file:"&&[A-Za-z0-9_]+\.app\.isPackaged===!0' "${idx}"; then
		sed -i -E 's/e\.protocol==="file:"&&[A-Za-z0-9_]+\.app\.isPackaged===!0/e.protocol==="file:"/g' "${idx}" || die
	else
		ewarn "file:// preload patch skipped (target not found)"
	fi

	# Add a linux branch to getHostPlatform() (best-effort; enable-cowork.py's
	# throw->return"darwin-x64" patch below is the real safety net).
	if grep -q 'win32-arm64":"win32-x64";throw new Error' "${idx}"; then
		sed -i 's|win32-arm64":"win32-x64";throw new Error|win32-arm64":"win32-x64";if(process.platform==="linux")return A==="arm64"?"linux-arm64":"linux-x64";throw new Error|' "${idx}" || die
	else
		ewarn "linux-x64 platform patch skipped (target not found)"
	fi

	# Allow file:// as a preload origin in mainView (CoworkSpaces/projects IPC).
	if [[ -f ${mainview} ]] && ! grep -q 'e\.protocol==="file:"' "${mainview}"; then
		sed -i 's/e\.hostname==="localhost"/e.hostname==="localhost"||e.protocol==="file:"/g' "${mainview}" || die
	fi

	# Remap --effort xhigh -> max (the SDK only accepts low/medium/high/max).
	if grep -q 'O\.push("--effort",this\.options\.effort)' "${idx}"; then
		sed -i 's/O\.push("--effort",this\.options\.effort)/O.push("--effort",this.options.effort==="xhigh"?"max":this.options.effort)/' "${idx}" || die
	fi

	# Neutralise macOS-only Handoff APIs that crash on Linux.
	if grep -q 'cA\.app\.invalidateCurrentActivity()' "${idx}"; then
		sed -i 's/cA\.app\.invalidateCurrentActivity()/(cA.app.invalidateCurrentActivity||function(){})()/' "${idx}" || die
		sed -i 's/cA\.app\.setUserActivity(adt,/((cA.app.setUserActivity||function(){}))(adt,/' "${idx}" || die
	fi

	# i18n JSONs are read from both resources/ and resources/i18n/.
	if compgen -G "${app}/resources/*.json" >/dev/null; then
		mkdir -p "${app}/resources/i18n" || die
		cp "${app}/resources/"*.json "${app}/resources/i18n/" || die
	fi

	# Allow bash/sh in the Cowork orchestrator allowlist (upstream gap).
	local orch="${app}/cowork/session_orchestrator.js"
	if [[ -f ${orch} ]] && grep -q '} else if (allowedPrefixes\.some' "${orch}" \
	   && ! grep -qE "commandBasename === [\"']bash[\"']" "${orch}"; then
		sed -i 's#^    } else if (allowedPrefixes\.some#    } else if (commandBasename === "bash" || commandBasename === "sh") {\n      hostCommand = "/usr/bin/" + commandBasename;\n      trace("Translated shell command: " + normalizedCommand + " -> " + hostCommand);\n    } else if (allowedPrefixes.some#' "${orch}" || die
	fi

	# Enable Cowork (yukonSilver): platform gate + getHostPlatform +
	# IPC origin guards + return-style platform gates.
	einfo "Applying Cowork patch (enable-cowork.py) ..."
	"${EPYTHON}" "${repo}/enable-cowork.py" "${idx}" || die "enable-cowork.py failed"

	# Hard gate: refuse to ship a half-patched (broken) app. A missing marker
	# means the Claude build is too new for the current packaging.
	if ! grep -q '/\*cowork-patched\*/' "${idx}"; then
		eerror "enable-cowork.py could not locate the Cowork platform gate in this"
		eerror "Claude Desktop build (${_CLAUDE_VER}): the minified bundle changed"
		eerror "and the upstream packaging has not caught up yet. Pin a known-good"
		eerror "build, e.g.:"
		eerror "  CLAUDE_COWORK_VERSION=1.11187.4 \\"
		eerror "  CLAUDE_COWORK_URL=https://downloads.claude.ai/releases/darwin/universal/1.11187.4/Claude-58400536f3ccde1cff9a129de6c3112dc8cb489a.zip \\"
		eerror "  emerge ${PN}"
		die "Cowork platform gate not patched -- aborting to avoid a broken install"
	fi
}

src_install() {
	# Big prebuilt trees: cp -a preserves +x bits and symlinks (doins would not).
	dodir "${CLAUDE_INSTALLDIR}"
	cp -a "${WORKDIR}/electron" "${ED}${CLAUDE_INSTALLDIR}/electron" || die
	cp -a "${WORKDIR}/app" "${ED}${CLAUDE_INSTALLDIR}/app" || die

	# Ensure the Electron binaries are executable.
	fperms 0755 "${CLAUDE_INSTALLDIR}/electron/electron"
	local b
	for b in chrome-sandbox chrome_crashpad_handler; do
		[[ -e ${ED}${CLAUDE_INSTALLDIR}/electron/${b} ]] \
			&& fperms 0755 "${CLAUDE_INSTALLDIR}/electron/${b}"
	done
	# Cowork shell shims must stay executable.
	[[ -e ${ED}${CLAUDE_INSTALLDIR}/app/cowork/cowork-plugin-shim.sh ]] \
		&& fperms 0755 "${CLAUDE_INSTALLDIR}/app/cowork/cowork-plugin-shim.sh"

	# Launcher.
	cat > "${T}/${PN}" <<-EOF || die
		#!/bin/bash
		# Claude Cowork (Linux port) launcher
		APPDIR="${EPREFIX}${CLAUDE_INSTALLDIR}"
		ELECTRON="\${APPDIR}/electron/electron"

		if [[ -n "\${WAYLAND_DISPLAY}" || "\${XDG_SESSION_TYPE}" == "wayland" ]]; then
		    export ELECTRON_OZONE_PLATFORM_HINT="\${ELECTRON_OZONE_PLATFORM_HINT:-auto}"
		fi

		# Pick a credential backend: SecretService if a provider owns the bus
		# name, otherwise Chromium's plaintext "basic" store.
		PW_STORE="gnome-libsecret"
		if ! dbus-send --session --print-reply --dest=org.freedesktop.DBus \\
		     /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \\
		     string:"org.freedesktop.secrets" 2>/dev/null | grep -q "boolean true"; then
		    PW_STORE="basic"
		fi

		# Register the claude:// scheme handler once.
		if command -v xdg-mime >/dev/null 2>&1; then
		    if [[ -z "\$(xdg-mime query default x-scheme-handler/claude 2>/dev/null)" ]]; then
		        xdg-mime default ${PN}.desktop x-scheme-handler/claude 2>/dev/null || true
		    fi
		fi

		# Prefer the Chromium namespace sandbox when unprivileged user
		# namespaces are available; otherwise fall back to --no-sandbox.
		SANDBOX_FLAG="--no-sandbox"
		if [[ -f /proc/sys/kernel/unprivileged_userns_clone ]]; then
		    [[ "\$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" == "1" ]] && SANDBOX_FLAG=""
		elif [[ -f /proc/sys/user/max_user_namespaces ]]; then
		    [[ "\$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)" -gt 0 ]] 2>/dev/null && SANDBOX_FLAG=""
		fi

		exec "\${ELECTRON}" "\${APPDIR}/app" \\
		    \${SANDBOX_FLAG} \\
		    --class=Claude \\
		    --password-store="\${PW_STORE}" \\
		    --enable-features=GlobalShortcutsPortal,WaylandWindowDecorations \\
		    "\$@"
	EOF
	dobin "${T}/${PN}"

	# Desktop entry.
	cat > "${T}/${PN}.desktop" <<-EOF || die
		[Desktop Entry]
		Name=Claude Cowork
		Comment=Anthropic Claude Desktop with local agent (Cowork) support
		Exec=${PN} %U
		Icon=${PN}
		Type=Application
		Categories=Development;Utility;
		MimeType=x-scheme-handler/claude;
		StartupWMClass=Claude
	EOF
	domenu "${T}/${PN}.desktop"

	# Icon (best effort: icns2png from media-gfx/libicns is not a hard dep).
	if [[ -f ${WORKDIR}/AppIcon.icns ]] && command -v icns2png >/dev/null 2>&1; then
		icns2png -x -s 256 "${WORKDIR}/AppIcon.icns" -o "${T}" 2>/dev/null
		local png
		for png in "${T}"/AppIcon*256*.png "${T}"/AppIcon*.png; do
			if [[ -f ${png} ]]; then
				newicon -s 256 "${png}" "${PN}.png"
				break
			fi
		done
	else
		elog "Install media-gfx/libicns (icns2png) and re-emerge for an app icon."
	fi
}

pkg_postinst() {
	xdg_pkg_postinst

	elog "Claude Desktop is proprietary Anthropic software; this package only"
	elog "provides the Linux compatibility layer. Launch it with: ${PN}"
	elog
	elog "This is a -9999 live ebuild: it tracks the packaging repo's master"
	elog "branch and downloads the Claude Desktop build that upstream pins in"
	elog "nix/package.nix. To force a specific Claude build, set CLAUDE_COWORK_VERSION"
	elog "and CLAUDE_COWORK_URL before emerging."
	elog
	if use sandbox; then
		elog "The Chromium sandbox needs unprivileged user namespaces"
		elog "(CONFIG_USER_NS). Without them the launcher falls back to"
		elog "--no-sandbox automatically."
	fi
}
