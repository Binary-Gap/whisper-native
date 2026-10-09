#!/usr/bin/env python3
"""iTerm2 helper for whisper-native.

Unified interface for iTerm2 operations via the Python API.
Replaces scattered AppleScript calls. Works with both regular
and tmux-integrated sessions.

Usage:
    iterm_helper.py get-session
    iterm_helper.py get-cwd --session-id ID
    iterm_helper.py send --session-id ID (--text TEXT | --text-file PATH) [--newline]
"""

import argparse
import asyncio
import os
import re
import sys

import iterm2


async def cmd_get_session(connection):
    """Get current session ID of the focused window."""
    app = await iterm2.async_get_app(connection)
    window = app.current_window
    if window is None:
        print("no window", file=sys.stderr)
        return 1
    tab = window.current_tab
    if tab is None or tab.current_session is None:
        print("no session", file=sys.stderr)
        return 1
    print(tab.current_session.session_id)
    return 0


async def cmd_get_cwd(connection, session_id):
    """Get working directory of a session."""
    app = await iterm2.async_get_app(connection)
    session = app.get_session_by_id(session_id)
    if session is None:
        print("session not found", file=sys.stderr)
        return 1
    path = await session.async_get_variable("path")
    if path:
        print(path)
        return 0
    print("no path", file=sys.stderr)
    return 1


# Foreground programs where a typed newline runs the line as a command.
SHELL_JOBS = {"zsh", "bash", "sh", "dash", "fish", "ksh", "tcsh", "csh", "nu", "ssh", "mosh-client"}


def prepare_text(text, job_name):
    """Joins the lines with spaces when a shell (or ssh) is in the foreground.

    The text is typed, not pasted, so each newline would run what came before
    it at a shell prompt. Other programs (TUIs like Claude Code) treat the
    newline as a line break, so they get the text unchanged.
    """
    job = os.path.basename((job_name or "").lstrip("-"))
    if job not in SHELL_JOBS:
        return text
    return re.sub(r"\s*\n\s*", " ", text).strip()


async def cmd_send(connection, session_id, text, newline=False):
    """Send text to a session."""
    app = await iterm2.async_get_app(connection)
    session = app.get_session_by_id(session_id)
    if session is None:
        print("session not found", file=sys.stderr)
        return 1
    job_name = await session.async_get_variable("jobName")
    await session.async_send_text(prepare_text(text, job_name))
    if newline:
        # Send Enter as a separate terminal write, after a short delay.
        # Gluing the CR onto the text makes TUIs (e.g. Claude Code) treat it
        # as part of a multi-line paste and insert a soft newline instead of
        # submitting. A standalone, delayed CR registers as a discrete Enter.
        await asyncio.sleep(0.15)
        await session.async_send_text("\x0d")
    return 0


def main():
    parser = argparse.ArgumentParser(description="iTerm2 helper for whisper-native")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("get-session", help="Get current session ID")

    p_cwd = sub.add_parser("get-cwd", help="Get session working directory")
    p_cwd.add_argument("--session-id", required=True, help="Session ID")

    p_send = sub.add_parser("send", help="Send text to session")
    p_send.add_argument("--session-id", required=True, help="Session ID")
    p_send.add_argument("--text", help="Text to send")
    p_send.add_argument("--text-file", help="Read text from file")
    p_send.add_argument("--newline", action="store_true", help="Press Enter after text")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    if args.command == "get-session":
        rc = iterm2.run_until_complete(cmd_get_session)
    elif args.command == "get-cwd":
        rc = iterm2.run_until_complete(
            lambda c: cmd_get_cwd(c, args.session_id)
        )
    elif args.command == "send":
        text = args.text
        if args.text_file:
            with open(args.text_file) as f:
                text = f.read()
        if not text:
            print("no text provided", file=sys.stderr)
            sys.exit(1)
        rc = iterm2.run_until_complete(
            lambda c: cmd_send(c, args.session_id, text, args.newline)
        )
    else:
        parser.print_help()
        sys.exit(1)

    sys.exit(rc)


if __name__ == "__main__":
    main()
