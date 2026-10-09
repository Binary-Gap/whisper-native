#!/usr/bin/env bash
# Generic coding-agent log wrapper. Runs a command and writes TWO logs under
# ~/.cache/ai-logs/:
#   <hash>.log            the FULL raw output (stdout+stderr)
#   <hash>.filtered.log   the PARSED view — verdict + extracted diagnostics
#                               (or a tail fallback) + warning count
# It prints a compact, verdict-first result to stdout so an AI agent gets the
# signal (succeeded / failed + the lines that matter). Each caller supplies
# its OWN patterns/tail, so the wrapper stays tool-agnostic (xcodebuild,
# swiftlint, anything). Logs live OUTSIDE the repo (global cache) so no
# project needs to vendor this script or gitignore a local .logs/ dir.
#
# Usage:
#   ai-logged.sh --label <name> [opts] -- <command> [args...]
#
# Options (all optional except --label):
#   --label <name>          log file prefix + verdict label (REQUIRED)
#   --tail <n>              FAILURE fallback: tail lines when no --diagnostic-pattern match (default 20)
#   --diagnostic-pattern <regex>  on FAILURE, rg these lines from the log (the errors an
#                           agent needs). Falls back to a tail if no match / unset.
#   --warn-pattern <regex>  on SUCCESS, COUNT these (reported as "N warning(s)";
#                           the text stays in the log, not echoed — saves context).
#   --fail-pattern <regex>  extra failure signal: if this rg-matches the log, treat
#                           as failure even on exit 0 (e.g. '\*\* BUILD FAILED \*\*').
#   --require-pattern <regex>  ABSENCE signal: the log MUST match this or the run is a
#                           failure, even on exit 0. Catches the silent lie a
#                           --fail-pattern cannot see — a command that reports success
#                           having done nothing (e.g. a typo'd -only-testing selection
#                           matching no test, which xcodebuild greenlights). Only
#                           applied when the command itself succeeded; a real failure
#                           keeps its own diagnostics. On SUCCESS the LAST match is
#                           echoed as the verdict's proof-of-work line.
#
# Patterns are passed to `rg` (PCRE-free; basic rg regex). Exit code is preserved,
# except an unmatched --require-pattern which turns an exit 0 into 1.
set -uo pipefail

label="" ; tail_lines=20
diagnostic_pattern="" ; warn_pattern="" ; fail_pattern="" ; require_pattern=""

while [ $# -gt 0 ]; do
  case "$1" in
    --label)        label="$2"; shift 2 ;;
    --tail)         tail_lines="$2"; shift 2 ;;
    --diagnostic-pattern) diagnostic_pattern="$2"; shift 2 ;;
    --warn-pattern) warn_pattern="$2"; shift 2 ;;
    --fail-pattern) fail_pattern="$2"; shift 2 ;;
    --require-pattern) require_pattern="$2"; shift 2 ;;
    --)             shift; break ;;
    *) echo "ai-logged.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$label" ] || { echo "ai-logged.sh: --label is required" >&2; exit 2; }
[ $# -gt 0 ] || { echo "ai-logged.sh: no command after --" >&2; exit 2; }

# Logs live in a global cache dir (not the repo) so nothing needs vendoring
# or gitignoring.
root_dir="${MISE_PROJECT_ROOT:-$PWD}"
logs_dir="$HOME/.cache/ai-logs"
mkdir -p "$logs_dir"

# Prune logs older than 24h so the folder stays clean (time-based retention).
find "$logs_dir" -name '*.log' -type f -mtime +1 -delete 2>/dev/null || true

hash="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
log_file="$logs_dir/${hash}.log"
filtered_file="$logs_dir/${hash}.filtered.log"

echo "=== ${label}: running… ==="
echo "=== log (filtered): ${filtered_file} ==="
echo "=== log (full): ${log_file} ==="

# Shorten noise: strip the repo-root prefix so diagnostic paths are relative.
strip_root() { sed "s#${root_dir}/##g"; }

# Wall-clock start — reported on EVERY verdict (success or failure) so the agent
# always sees how long the run took (`SECONDS` is bash's built-in elapsed timer).
SECONDS=0

"$@" 2>&1 | tee "$log_file" >/dev/null
status=${PIPESTATUS[0]}

# A tool can signal failure while still exiting 0 (e.g. xcodebuild prints
# `** BUILD FAILED **`); let the caller declare that pattern.
extra_failed=false
if [ -n "$fail_pattern" ] && rg -q "$fail_pattern" "$log_file"; then
  extra_failed=true
fi

# A command can also lie by OMISSION: exit 0 having run nothing at all. Only
# meaningful when the command otherwise succeeded — on a real failure the build
# /test errors are the useful output, and demanding a success marker there would
# bury them.
required_missing=false
if [ -n "$require_pattern" ] && [ "$status" -eq 0 ] && [ "$extra_failed" = false ] \
   && ! rg -q "$require_pattern" "$log_file"; then
  required_missing=true
fi

# Format elapsed wall-clock as (Nm Ns) or (Ns) for sub-minute runs.
elapsed_secs=$SECONDS
if [ "$elapsed_secs" -ge 60 ]; then
  elapsed="$(( elapsed_secs / 60 ))m $(( elapsed_secs % 60 ))s"
else
  elapsed="${elapsed_secs}s"
fi

# Build the VERDICT summary: echo it to stdout (the agent's inline result)
# AND write it to the filtered log so the on-disk file ends with a verdict too.
# Every verdict carries the elapsed time so the agent always sees run duration.
verdict=""
exit_code="$status"
if [ "$required_missing" = true ]; then
  # Exit 0 + no work done. Report the ABSENCE, not a diagnostics dump: the log of a
  # run that did nothing holds no errors to show, and a tail would just be setup noise.
  exit_code=1
  verdict="=== ${label}: FAILURE (ran nothing, exit=${status}, ${elapsed}) ==="$'\n'"--- the command succeeded but produced no result matching --require-pattern (${require_pattern}) ---"$'\n'"--- nothing executed; on a test task the usual cause is an -only-testing selection matching no test (typo?) ---"
elif [ "$status" -eq 0 ] && [ "$extra_failed" = false ]; then
  # SUCCESS = nothing to read. Report the verdict + a warning COUNT only (the
  # whole point is to save context; warning text lives in the full log if wanted).
  msg="${label}: SUCCESS (exit=${status}, ${elapsed})"
  if [ -n "$warn_pattern" ]; then
    n="$(rg -c "$warn_pattern" "$log_file" || true)"
    [ "${n:-0}" -gt 0 ] 2>/dev/null && msg="${msg}, ${n} warning(s)"
  fi
  verdict="=== ${msg} ==="
  # A bare SUCCESS is unfalsifiable: it reads identically whether 700 tests ran or
  # one did, which is why callers open the full log on a GREEN run. The
  # require-pattern match is that missing proof, so echo it. Take the LAST match —
  # a tool prints per-suite subtotals first and the run total last.
  if [ -n "$require_pattern" ]; then
    proof="$(rg -N "$require_pattern" "$log_file" | tail -n 1 | sed 's/^[[:space:]]*//' | cut -c1-200 || true)"
    [ -n "$proof" ] && verdict="${verdict}"$'\n'"${proof}"
  fi
else
  verdict="=== ${label}: FAILURE (exit=${status}, ${elapsed}) ==="
  if [ -n "$diagnostic_pattern" ]; then
    total="$(rg -c "$diagnostic_pattern" "$log_file" || true)"
    if [ "${total:-0}" -gt 0 ] 2>/dev/null; then
      # Echo the first 40 matches to stdout (line numbers index into the full
      # log) plus a count so the agent knows if more were truncated. Anything
      # not matching is full-log-only.
      diags="$(rg -n "$diagnostic_pattern" "$log_file" | head -n 40 | strip_root || true)"
      shown="$(printf '%s\n' "$diags" | grep -c '' || true)"
      verdict="${verdict}"$'\n'"--- diagnostics: ${total} match(es), showing ${shown}; anything NOT matching --diagnostic-pattern is only in the full log ---"$'\n'"${diags}"
    else
      verdict="${verdict}"$'\n'"--- no --diagnostic-pattern match; showing tail -${tail_lines} (lines capped at 200 chars); real error may be elsewhere in the full log ---"$'\n'"$(tail -n "$tail_lines" "$log_file" | strip_root | cut -c1-200)"
    fi
  else
    verdict="${verdict}"$'\n'"--- no --diagnostic-pattern set; showing tail -${tail_lines} (lines capped at 200 chars) ---"$'\n'"$(tail -n "$tail_lines" "$log_file" | strip_root | cut -c1-200)"
  fi
fi

printf '%s\n' "$verdict" > "$filtered_file"
echo "=== Filtered Logs ==="
printf '%s\n' "${verdict:-EMPTY}"

log_lines="$(wc -l < "$log_file" | tr -d ' ')"
log_bytes="$(wc -c < "$log_file" | tr -d ' ')"
echo "=== ${label}: full log ${log_lines} lines, ${log_bytes} bytes ==="
exit "$exit_code"
