#!/bin/zsh

set -euo pipefail

# Records the `svn --xml` output the parse tests read (test/fixtures/). It
# builds a throwaway file:// repository whose working copy holds every status
# the provider maps, then saves status, info, log, and blame output with the
# machine-specific directory replaced by /tmp/lab. Re-run it after a
# Subversion upgrade and review the fixture diff:
#
#   Plugins/mac/Official/SvnSupport/test/record-fixtures.sh

FIXTURES="${0:A:h}/fixtures"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/lithe-svn-fixtures.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
LAB=${LAB:A}
mkdir -p "$FIXTURES"

# The same environment the provider uses: UTF-8 paths, English messages.
unset LC_ALL LANGUAGE
export LC_CTYPE=UTF-8 LC_MESSAGES=C
svn() { command svn --non-interactive --config-dir "$LAB/config" "$@"; }

REPO="file://$LAB/repo"
svnadmin create "$LAB/repo"
svn mkdir -q --parents -m "Create layout" --username alice "$REPO/trunk" "$REPO/branches" "$REPO/vendor/lib"
svn checkout -q "$REPO/trunk" "$LAB/wc"
cd "$LAB/wc"

commit() { svn commit -q --username alice -m "$1"; }

# The files every later revision changes.
mkdir -p src docs lib
print 'library' > lib/lib.c
print -l one two three > src/main.c
print -l alpha beta > src/util.c
print 'notes' > docs/readme.txt
print 'keep' > keep.txt
print 'to delete' > gone.txt
print 'to lose' > lost.txt
print 'to replace' > replaced.txt
print 'to move' > before.txt
print 'to copy' > template.txt
print 'locked' > locked.txt
print 'ünïcödé' > 'ünïcödé.txt'
print 'at sign' > 'a@b.txt'
print 'space' > 'with space.txt'
print -n 'bin\0ary' > image.bin
svn add -q src docs lib keep.txt gone.txt lost.txt replaced.txt before.txt template.txt locked.txt \
    'ünïcödé.txt' 'a@b.txt@' 'with space.txt' image.bin
svn propset -q svn:ignore '*.log' .
commit 'Add sources

Second paragraph with <markup> & "quotes".'
# A second author on part of main.c, for blame.
print -l one TWO three four > src/main.c
svn commit -q --username bob -m 'Change main' src/main.c
# A rename, a copy, and a property-only change in one revision.
svn move -q before.txt after.txt
svn copy -q template.txt copy-of-template.txt
svn propset -q custom:flag yes keep.txt
commit 'Rename, copy, and set a property'
# A delete and a replace; a change outside the root, which history of the
# root leaves out; a revision without a message.
svn delete -q gone.txt
commit 'Delete gone.txt'
svn delete -q replaced.txt && print 'new content' > replaced.txt && svn add -q replaced.txt
commit 'Replace replaced.txt'
svn mkdir -q -m 'Outside the root' --username alice "$REPO/branches/feature"
print 'more' >> keep.txt
svn commit -q --username alice -m '' keep.txt
# The external the working copy carries as its own root.
mkdir "$LAB/vendor" && print 'vendor' > "$LAB/vendor/vendor.txt"
svn import -q -m 'Vendor code' --username alice "$LAB/vendor" "$REPO/vendor/lib/docs"
# A property of the root commits only when the root is at HEAD.
svn update -q
svn propset -q svn:externals "^/vendor/lib/docs vendor-docs" .
commit 'Add an external'
svn update -q

# A conflicting change from a second working copy.
svn checkout -q "$REPO/trunk" "$LAB/other"
print -l alpha 'beta from other' > "$LAB/other/src/util.c"
svn commit -q --username bob -m 'Change util from elsewhere' "$LAB/other"
svn delete -q "$LAB/other/docs/readme.txt"
svn commit -q --username bob -m 'Delete readme elsewhere' "$LAB/other"

# Local changes for status.
print 'local edit' >> src/main.c
print -l alpha 'beta locally' > src/util.c
print 'edited' >> docs/readme.txt
svn update -q --accept postpone || true
svn propset -q custom:flag no 'with space.txt'
print 'new' > added.txt && svn add -q added.txt
svn copy -q template.txt copied.txt
svn move -q after.txt moved.txt
svn delete -q copy-of-template.txt
rm lost.txt
svn delete -q replaced.txt && print 'again' > replaced.txt && svn add -q replaced.txt
print 'scratch' > unversioned.txt
print 'log' > build.log
svn lock -q --username alice locked.txt
svn switch -q --ignore-ancestry "^/branches/feature" lib
print 'ünïcödé edit' >> 'ünïcödé.txt'
print 'at edit' >> 'a@b.txt'

record() {
    local name=$1; shift
    "$@" | sed -e "s|$LAB|/tmp/lab|g" > "$FIXTURES/$name"
}
record status.xml svn status --xml --ignore-externals
record status-no-ignore.xml svn status --xml --ignore-externals --no-ignore
record info.xml svn info --xml
record log-root.xml svn log --xml --verbose -r HEAD:1
record log-file.xml svn log --xml --verbose -r BASE:1 -- 'moved.txt@'
record blame.xml svn blame --xml -- keep.txt@
record blame-local.xml svn blame --xml -- src/main.c@
# What svn prints on stderr for the failures the provider tells apart.
record_error() {
    local name=$1; shift
    { "$@" 2>&1 >/dev/null || true } | sed -e "s|$LAB|/tmp/lab|g" > "$FIXTURES/errors/$name"
}
mkdir -p "$FIXTURES/errors"
record_error cat-added.txt svn cat -r BASE -- added.txt@
record_error cat-unversioned.txt svn cat -r BASE -- unversioned.txt@
record_error log-added.txt svn log --xml -- added.txt@
record_error blame-added.txt svn blame --xml -- added.txt@
record_error add-versioned.txt svn add --parents -- keep.txt@ unversioned.txt@
svn revert -q unversioned.txt
record_error move-unversioned.txt svn move -- unversioned.txt@ elsewhere.txt
record_error status-outside.txt svn status --xml "$LAB"
sqlite3 .svn/wc.db "insert into wc_lock (wc_id, local_dir_relpath, locked_levels) values (1, '', -1)"
record_error update-locked.txt svn update
svn cleanup
print 'theirs' > "$LAB/other/keep.txt"
svn commit -q --username bob -m 'Change keep elsewhere' "$LAB/other/keep.txt"
print 'mine' > keep.txt
record_error commit-out-of-date.txt svn commit -m 'Out of date' -- keep.txt@
svn revert -q keep.txt
record commit.txt svn commit --username alice -m 'Commit for output' -- added.txt@
print "Recorded $(svn --version --quiet) fixtures in $FIXTURES"
