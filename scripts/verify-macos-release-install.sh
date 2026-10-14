#!/bin/zsh
set -euo pipefail

dmg_path="${1:A}"
version="$2"
public_key="$3"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/lithe-release-install.XXXXXX")
mount_path="$test_root/mount"
mkdir -p "$mount_path"
cleanup() {
    hdiutil detach "$mount_path" -force >/dev/null 2>&1 || true
    rm -rf "$test_root"
}
trap cleanup EXIT

hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_path"
ditto "$mount_path/Lithe.app" "$test_root/Lithe.app"
app="$test_root/Lithe.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" = "$public_key"
codesign --verify --deep --strict "$app"
if [[ $(uname -m) == arm64 ]] && lipo "$app/Contents/MacOS/Lithe" -verify_arch x86_64 >/dev/null 2>&1; then
    softwareupdate --install-rosetta --agree-to-license
fi

# This integration probe owns a separate process group and always reaps it.
ruby -rdigest -rtimeout -e '
  app = ARGV.fetch(0)
  snapshot = -> { Dir.glob(File.join(app, "**", "*"), File::FNM_DOTMATCH).to_h { |p|
    stat = File.lstat(p)
    value = stat.symlink? ? File.readlink(p) : (stat.file? ? Digest::SHA256.file(p).hexdigest : "directory")
    [p, [stat.mode, value]]
  } }
  before = snapshot.call
  pid = Process.spawn(File.join(app, "Contents/MacOS/Lithe"), pgroup: true, out: File.join(File.dirname(app), "launch.log"), err: [:child, :out])
  begin
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      raise "Installed app exited during startup" if Process.waitpid(pid, Process::WNOHANG)
      sleep 0.25
    end
  ensure
    Process.kill("TERM", -pid) rescue Errno::ESRCH
    begin
      Timeout.timeout(5) { Process.waitpid(pid) }
    rescue Timeout::Error
      Process.kill("KILL", -pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    rescue Errno::ECHILD
    ensure
      Process.kill("KILL", -pid) rescue Errno::ESRCH
    end
  end
  raise "Runtime modified the installed application" unless snapshot.call == before
  puts "DMG installation, launch survival, cleanup, and bundle SHA-256 immutability passed"
' "$app"
