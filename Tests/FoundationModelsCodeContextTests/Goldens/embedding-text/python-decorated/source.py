"""Hold the Python golden case for the embed text of a decorated class.

`Row` is the container: a class with two decorators, a docstring, fields
and methods. Its `decorated_definition` chunk embeds a summary. `label` is
a decorated function: its `decorated_definition` chunk embeds its full text.
"""

import dataclasses
import functools

__all__ = ["Row", "label"]


@functools.total_ordering
@dataclasses.dataclass(frozen=True)
class Row:
    """Hold one row of a table.

    The rows sort by key.
    """

    key: str
    value: int = 0

    def __lt__(self, other):
        """Give True when the key of this row is before the key of `other`."""
        return self.key < other.key

    @property
    def width(self) -> int:
        """Give the number of characters of the key."""
        return len(self.key)


@functools.cache
def label(row):
    """Give the label of `row`: its key, padded to its width, and its value."""
    return f"{row.key:<{row.width}}={row.value}"
