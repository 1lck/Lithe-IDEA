#!/bin/sh
# Installs Lithe Desktop on Linux for the current user, in the form that updates itself:
#
#   curl -fsSL https://raw.githubusercontent.com/1lck/Lithe-IDEA/main/scripts/install/linux.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/1lck/Lithe-IDEA/main/scripts/install/linux.sh | sh -s -- uninstall
#
# It reads the stable update feed, the one the installed program checks, downloads the tar.gz
# for this machine, compares its SHA-256 with the feed and runs the archive's own install.sh.
# That script puts the program in <prefix>/bin, the menu entry in <prefix>/share/applications
# and the icon under <prefix>/share/icons, refreshes the desktop caches, and leaves every file
# owned by the user, so Lithe can later replace itself with a delta patch. A DEB or RPM install
# belongs to the package manager and only gets a link to the downloads page.
#
# POSIX sh, so it runs under dash as well as bash. Everything happens inside main, which the
# last line calls, so a download cut off halfway runs nothing.
set -eu

feed_url=https://github.com/1lck/Lithe-IDEA/releases/download/desktop-update-feed/stable.json
downloads_url=https://github.com/1lck/Lithe-IDEA/releases
script_url=https://raw.githubusercontent.com/1lck/Lithe-IDEA/main/scripts/install/linux.sh
# The update identity in desktop/viva.toml; the feed of another app is refused.
app_id=app.lithe.viva
# The executable and the DEB/RPM package name.
app=lithe

# Libraries the program opens with dlopen at run time, so nothing in its ELF header names
# them, each as <soname>=<Debian package>. These are what the DEB depends on: the set Viva
# itself requires plus the [linux] depends in desktop/viva.toml.
required_libraries="libxcb.so.1=libxcb1 libcairo.so.2=libcairo2 libfontconfig.so.1=libfontconfig1
libpango-1.0.so.0=libpango-1.0-0 libpangocairo-1.0.so.0=libpangocairo-1.0-0
libpangoft2-1.0.so.0=libpangoft2-1.0-0 libgobject-2.0.so.0=libglib2.0-0
libxcb-cursor.so.0=libxcb-cursor0 libxcb-randr.so.0=libxcb-randr0 libxcb-render.so.0=libxcb-render0
libxcb-shape.so.0=libxcb-shape0 libxcb-sync.so.1=libxcb-sync1"
# Without the Vulkan loader the program still starts but draws on the CPU.
recommended_libraries="libvulkan.so.1=libvulkan1"

say() {
	printf '%s\n' "$*"
}

warn() {
	printf 'warning: %s\n' "$*" >&2
}

fail() {
	printf 'lithe-install: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
usage: linux.sh [install|uninstall] [--prefix DIR]

  install       download the latest Lithe and install it for this user (default)
  uninstall     remove the program, menu entry and icon again; settings stay
  --prefix DIR  where to install: DIR/bin, DIR/share/applications, DIR/share/icons.
                Default is ~/.local. Lithe can only update itself in a directory you own.

Through a pipe, put the options after "sh -s --":

  curl -fsSL $script_url | sh -s -- uninstall
EOF
}

# os_family prints debian, fedora, suse or nothing, from /etc/os-release. Tests point
# LITHE_INSTALL_OS_RELEASE at their own file.
os_family() {
	release=${LITHE_INSTALL_OS_RELEASE:-/etc/os-release}
	[ -r "$release" ] || return 0
	ids=$(sed -n -e 's/^ID=//p' -e 's/^ID_LIKE=//p' "$release" | tr -d '"' | tr '\n' ' ')
	for id in $ids; do
		case $id in
		debian | ubuntu) echo debian && return 0 ;;
		suse | opensuse | opensuse-*) echo suse && return 0 ;;
		fedora | rhel | centos) echo fedora && return 0 ;;
		esac
	done
}

# installed_package prints the command that removes a DEB or RPM install of Lithe, or fails
# when there is none.
installed_package() {
	# dpkg-query expands ${Status} itself.
	# shellcheck disable=SC2016
	if command -v dpkg-query >/dev/null 2>&1 &&
		dpkg-query -W -f='${Status}' "$app" 2>/dev/null | grep -q 'ok installed'; then
		echo "sudo apt remove $app"
		return 0
	fi
	if command -v rpm >/dev/null 2>&1 && rpm -q "$app" >/dev/null 2>&1; then
		case $(os_family) in
		suse) echo "sudo zypper remove $app" ;;
		*) echo "sudo dnf remove $app" ;;
		esac
		return 0
	fi
	return 1
}

# fetch downloads $1 to $2; with $3 = progress it shows a progress bar on a terminal.
fetch() {
	if command -v curl >/dev/null 2>&1; then
		if [ "${3:-}" = progress ] && [ -t 2 ]; then
			curl -fL --proto '=https' --proto-redir '=https' --retry 3 --progress-bar -o "$2" "$1"
		else
			curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$2" "$1"
		fi
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1"
	else
		fail "neither curl nor wget is installed; install one of them and run this again"
	fi
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{ print $1 }'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 -r "$1" | awk '{ print $1 }'
	else
		fail "no sha256sum, shasum or openssl to check the download with"
	fi
}

# flatten_json prints one "<path><TAB><value>" line for each string, number, boolean and null
# in the JSON file $1, e.g. "latest.assets.2.url<TAB>https://…"; array elements are numbered
# from 0. Strings keep their escapes. It fails on input that does not close every bracket.
flatten_json() {
	awk '
	{ text = text $0 "\n" }
	function emit(value,   level, path) {
		path = key[1]
		for (level = 2; level <= depth; level++) path = path "." key[level]
		print path "\t" value
	}
	function string(   at, c, value) {
		value = ""
		for (at = i + 1; at <= n; at++) {
			c = substr(text, at, 1)
			if (c == "\\") { value = value substr(text, at, 2); at++; continue }
			if (c == "\"") { i = at + 1; return value }
			value = value c
		}
		broken = 1
		i = n + 1
		return value
	}
	END {
		n = length(text)
		i = 1
		depth = 0
		while (i <= n) {
			c = substr(text, i, 1)
			if (c == "{" || c == "[") {
				depth++
				type[depth] = c
				key[depth] = c == "[" ? 0 : ""
				wants_key[depth] = c == "{"
				i++
			} else if (c == "}" || c == "]") {
				depth--
				i++
			} else if (c == ",") {
				if (type[depth] == "[") key[depth]++
				else wants_key[depth] = 1
				i++
			} else if (c == ":") {
				wants_key[depth] = 0
				i++
			} else if (c == "\"") {
				value = string()
				if (type[depth] == "{" && wants_key[depth]) key[depth] = value
				else emit(value)
			} else if (c == " " || c == "\t" || c == "\r" || c == "\n") {
				i++
			} else {
				for (end = i; end <= n; end++) {
					c = substr(text, end, 1)
					if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\r" || c == "\n") break
				}
				emit(substr(text, i, end - i))
				i = end
			}
		}
		if (broken || depth != 0) exit 1
	}' "$1"
}

# missing_libraries prints the entries of $2 (soname=package lines) whose soname the library
# cache $1 does not list.
missing_libraries() {
	for entry in $2; do
		soname=${entry%%=*}
		printf '%s\n' "$1" | awk -v name="$soname" '$1 == name { found = 1 } END { exit !found }' ||
			printf '%s\n' "$entry"
	done
}

# install_command prints how to install the missing soname=package entries $1 on this
# distribution: Debian package names for apt, and the shared-library capabilities the
# Lithe RPM itself requires for dnf and zypper.
install_command() {
	packages=
	capabilities=
	sonames=
	for entry in $1; do
		packages="$packages ${entry#*=}"
		capabilities="$capabilities '${entry%%=*}()(64bit)'"
		sonames="$sonames ${entry%%=*}"
	done
	case $(os_family) in
	debian) echo "sudo apt install$packages" ;;
	fedora) echo "sudo dnf install$capabilities" ;;
	suse) echo "sudo zypper install$capabilities" ;;
	*) echo "install the packages that provide$sonames" ;;
	esac
}

# check_libraries warns about runtime libraries this system lacks. It only warns: the cache
# can miss libraries in unusual places, and the install itself does not need them.
check_libraries() {
	cache=
	for tool in "$(command -v ldconfig 2>/dev/null || true)" /sbin/ldconfig /usr/sbin/ldconfig; do
		if [ -n "$tool" ] && [ -x "$tool" ] && cache=$("$tool" -p 2>/dev/null); then
			break
		fi
		cache=
	done
	if [ -z "$cache" ]; then
		say "Could not list the shared libraries (ldconfig -p); if Lithe does not start, install libxcb, cairo, fontconfig, pango and glib."
		return 0
	fi
	missing=$(missing_libraries "$cache" "$required_libraries")
	if [ -n "$missing" ]; then
		names=
		for entry in $missing; do
			names="$names ${entry%%=*}"
		done
		warn "Lithe needs libraries this system lacks:$names"
		warn "install them with: $(install_command "$missing")"
	fi
	missing=$(missing_libraries "$cache" "$recommended_libraries")
	if [ -n "$missing" ]; then
		warn "libvulkan.so.1 is missing, so Lithe draws on the CPU without GPU acceleration."
		warn "for GPU acceleration: $(install_command "$missing"), plus a Vulkan driver such as Mesa's"
	fi
}

# check_menu warns when the desktop does not read the applications directory under $1/share.
check_menu() {
	data=$1/share
	data_home=${XDG_DATA_HOME:-$HOME/.local/share}
	[ "${data_home%/}" = "$data" ] && return 0
	old_ifs=$IFS
	IFS=:
	for directory in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
		if [ "${directory%/}" = "$data" ]; then
			IFS=$old_ifs
			return 0
		fi
	done
	IFS=$old_ifs
	warn "the desktop does not read $data/applications, so Lithe is not in the application menu."
	warn "add $data to XDG_DATA_DIRS for your session, or install without --prefix to use ~/.local."
}

main() {
	action=install
	prefix=
	default_prefix=yes
	while [ $# -gt 0 ]; do
		case $1 in
		install | uninstall) action=$1 ;;
		--prefix)
			[ $# -ge 2 ] || fail "--prefix needs a directory"
			prefix=$2
			default_prefix=
			shift
			;;
		--prefix=*)
			prefix=${1#--prefix=}
			default_prefix=
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			usage >&2
			exit 2
			;;
		esac
		shift
	done

	[ "$(uname -s)" = Linux ] || fail "this installer is for Linux; other systems are listed at $downloads_url"
	machine=$(uname -m)
	case $machine in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) fail "there is no Lithe build for $machine, only for x86_64 and aarch64" ;;
	esac
	if [ "$(id -u)" = 0 ]; then
		fail "run this as your own user, without sudo. Lithe goes under your home directory so it can update itself; a copy owned by root cannot. For a system-wide install use the DEB or RPM package from $downloads_url"
	fi

	if [ -z "$prefix" ]; then
		[ -n "${HOME:-}" ] || fail "HOME is not set; give --prefix"
		prefix=$HOME/.local
	fi
	case $prefix in
	/*) ;;
	*) fail "the prefix must be an absolute path, not $prefix" ;;
	esac
	# The archive's install.sh writes the prefix into the menu entry's Exec line and refuses
	# characters that would need quoting there; refusing them here saves the download.
	case $prefix in
	*[!A-Za-z0-9_./+-]*) fail "the prefix may only contain letters, digits and _ . / + -, not $prefix" ;;
	esac
	prefix=${prefix%/}

	if [ "$action" = install ] && remove=$(installed_package); then
		fail "Lithe is installed from a DEB or RPM package, which the package manager updates instead of Lithe. Remove it with \"$remove\" (your settings stay), then run this again."
	fi

	work=$(mktemp -d "${TMPDIR:-/tmp}/lithe-install.XXXXXX")
	# A signal exits through the EXIT trap, which removes the downloads.
	trap 'rm -rf "$work"' EXIT
	trap 'exit 1' HUP INT TERM

	say "Reading $feed_url"
	fetch "$feed_url" "$work/feed.json" || fail "could not download the update feed $feed_url"
	flatten_json "$work/feed.json" >"$work/feed.tsv" || fail "the update feed is not valid JSON"
	value() {
		awk -F '\t' -v key="$1" '$1 == key { print $2; exit }' "$work/feed.tsv"
	}
	[ "$(value schema)" = 1 ] || fail "the update feed has a format this installer does not know; download the tar.gz from $downloads_url"
	[ "$(value app)" = "$app_id" ] || fail "the update feed is not Lithe's; download the tar.gz from $downloads_url"
	version=$(value latest.version)
	[ -n "$version" ] || fail "the update feed names no version"
	asset=$(awk -F '\t' -v arch="$arch" '
		$1 ~ /^latest\.assets\.[0-9]+\.(os|arch|format)$/ {
			split($1, part, ".")
			field[part[3], part[4]] = $2
			if (part[3] + 0 > last) last = part[3] + 0
		}
		END {
			for (n = 0; n <= last; n++)
				if (field[n, "os"] == "linux" && field[n, "arch"] == arch && field[n, "format"] == "tar.gz") { print n; exit }
		}' "$work/feed.tsv")
	[ -n "$asset" ] || fail "Lithe $version has no tar.gz for Linux $arch in the update feed"
	url=$(value "latest.assets.$asset.url")
	sha256=$(value "latest.assets.$asset.sha256")
	case $url in
	https://*) ;;
	*) fail "the update feed gives no https address for the Linux $arch tar.gz" ;;
	esac
	case $sha256 in
	*[!0-9a-f]* | "") fail "the update feed gives no SHA-256 for the Linux $arch tar.gz" ;;
	esac
	[ ${#sha256} -eq 64 ] || fail "the update feed gives no SHA-256 for the Linux $arch tar.gz"

	say "Downloading Lithe $version for Linux $arch"
	fetch "$url" "$work/lithe.tar.gz" progress || fail "could not download $url"
	actual=$(sha256_of "$work/lithe.tar.gz")
	[ "$actual" = "$sha256" ] || fail "the download's SHA-256 is $actual, but the update feed says $sha256; nothing was installed"

	mkdir "$work/unpacked"
	tar -xzf "$work/lithe.tar.gz" -C "$work/unpacked" || fail "could not unpack $url"
	installer=$work/unpacked/$app-$version-linux-$arch/install.sh
	[ -f "$installer" ] || fail "the archive has no $app-$version-linux-$arch/install.sh"
	sh "$installer" "$action" --prefix "$prefix"

	options=
	[ -n "$default_prefix" ] || options=" --prefix $prefix"
	if [ "$action" = uninstall ]; then
		say "Your settings and projects are kept."
		return 0
	fi

	say ""
	say "Lithe $version is installed: $prefix/bin/$app, with its menu entry in $prefix/share/applications."
	say "Open it from the application menu, or run $app. If the menu does not show it yet, log out and back in."
	say "Lithe checks for updates itself and, when it can, downloads only what changed."
	say "To remove it: curl -fsSL $script_url | sh -s -- uninstall$options"
	check_menu "$prefix"
	first=$(command -v "$app" 2>/dev/null || true)
	if [ -n "$first" ] && [ "$first" != "$prefix/bin/$app" ]; then
		warn "$first comes before $prefix/bin/$app in PATH, so running $app starts that copy."
	fi
	check_libraries
}

main "$@"
