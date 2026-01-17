# gokapi-cli-2.1.0.ebuild
EAPI=8

DESCRIPTION="CLI tool for Gokapi file sharing server"
HOMEPAGE="https://github.com/Forceu/Gokapi"
SRC_URI="https://github.com/Forceu/Gokapi/releases/download/v${PV}/gokapi-cli-linux_amd64.zip"

LICENSE="AGPL-3"
SLOT="0"
KEYWORDS="~amd64"

BDEPEND="app-arch/unzip"

S="${WORKDIR}"

src_install() {
    newbin gokapi-cli-linux_amd64 gokapi-cli
}