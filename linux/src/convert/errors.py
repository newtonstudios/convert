"""The one error type users see, and the one that means "you pressed Stop"."""

from __future__ import annotations


class ConvertError(Exception):
    """A conversion can't be done, with a sentence for the person who asked.

    The text is what the window and the command line show, so it says what
    happened and (where there is one) what to do about it -- never a stack
    trace.
    """


class Stopped(ConvertError):
    """Stop was pressed. The caller shows no error, and nothing is left behind."""
