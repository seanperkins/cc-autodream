#!/bin/bash
# Canonical project identity, shared by every harness adapter.
#
# Claude derives a project bucket name from the session's cwd by mapping
# EVERYTHING outside [A-Za-z0-9-] to a dash, on the symlink-resolved physical
# path. Verified against real buckets on this host:
#
#   /Users/<u>/.claude                      -> -Users-<u>--claude
#   /private/var/folders/c2/29g..z_4tv..gn  -> -private-var-folders-c2-29g..z-4tv..gn
#   /Users/<u>/Documents/Personal Items/..  -> -Users-<u>-Documents-Personal-Items-..
#   /Users/<u>/../Personal House (39 Loring)/Improvements
#                                           -> ..-Personal-House--39-Loring--Improvements
#
# All of those break an encoder that maps only `/`, and they break it
# silently: the record still carries a cwd, so nothing counts it as
# unreconciled — the project just quietly splits in two.
#
# This started life as `tr '/._' '---'`, which is what an eyeball survey of
# dash-shaped bucket names suggests and what a survey of THIS repo's own paths
# confirms, because none of them contain a space. Measured instead: of the 96
# path-derived buckets under ~/.claude/projects on this host, the three-character
# form gets 89 and the complement form gets all 96 — every miss is a space or a
# parenthesis. The host also carries the artifact of the bug, a stale
# `-Users-…-Personal Items-…-RAW` bucket holding an empty `memory/` beside the
# live `-Personal-Items-` one that holds the actual sessions. That is a project
# split in two, already on disk, from something that encoded the space form.
#
# LC_ALL=C is load-bearing, not decoration. `tr -c` complements the set, and
# under a UTF-8 collation `A-Za-z` is a wider set than the 52 ASCII letters — so
# the complement SHRINKS and characters that must be mapped silently are not.
# Same collation trap as the enumerated character classes below, arriving from
# the opposite direction.
#
# Not verified: a non-ASCII path. `tr` is byte-oriented, so a multi-byte
# character becomes one dash per byte, and no bucket on this host tests whether
# that is what Claude does.
#
# This lives in one place because every adapter must produce the SAME key for
# the same real directory. That is what makes one project out of two harnesses'
# work, and it is why this design has no reconciliation pass at all. Deriving
# the key once, here, at triage time removes the failure rather than fixing it.
#
# macOS resolution matters too: Claude records the physical path, so a session
# in /tmp/foo is stored under -private-tmp-foo, while a harness that reports an
# unresolved cwd would produce -tmp-foo and group as a different project.

# Encode an already-absolute, already-resolved path into a bucket name.
encode_project() { # $1=absolute path -> encoded bucket name on stdout
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9-' '-'
}

# Resolve a path to its physical location, then encode it. Fails loudly rather
# than encoding something unresolved: a wrong project key splits a group, and a
# silent split is precisely what this function exists to prevent.
canonical_project() { # $1=path -> encoded name on stdout, or exit 1 with nothing
  local real
  real=$(realpath "$1" 2>/dev/null) || return 1
  [ -n "$real" ] || return 1
  encode_project "$real"
}

# The artifact key, validated. Nothing may derive a hash any other way.
#
# `h=$(printf %s "$p" | shasum -a 1 | cut -c1-12)` has two silent failure modes
# that end in the same place. `cut` masks shasum's exit status, so a shasum that
# EXISTS — satisfying preflight — but fails at runtime yields an empty hash, and
# every session then targets the same artifact. A short or non-hex result does
# the same.
#
# The character set is ENUMERATED, not a range. Verified on this host: under
# bash 3.2 with an en_US.UTF-8 collation, `A` matches [0-9a-f]; under bash 5.3 it
# does not. The nightly runs #!/bin/bash, which is 3.2, so the range form was
# accepting uppercase exactly where it matters. This is the same collation
# behaviour that made an uppercase adapter basename pass on CI and not locally.
session_hash() { # $1=session path -> 12 lowercase hex chars, or exit 1
  local out h
  out=$(printf '%s' "$1" | shasum -a 1 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  h=${out:0:12}
  case "$h" in
    [0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) printf '%s' "$h" ;;
    *) return 1 ;;
  esac
}
