"""Hold the Python golden case for the embed text of a container chunk.

`Repository` is the container: a class with a docstring, members, and a
nested class.
"""

import os

__all__ = ["Base", "Repository", "helper"]


class Base:
    """Mark a class that keeps the rows of one table."""


# A comment that is not the doc text in Python.
class Repository(Base):
    """Keep the rows of one table.

    The rows stay in memory.
    """

    limit = 10

    def __init__(self, name):
        """Make an empty repository for the table `name`."""
        self.name = name
        self.rows = []

    @property
    def size(self) -> int:
        """Give the number of rows."""
        return len(self.rows)

    def find(
        self,
        key,
    ):
        """Give the first row whose key is `key`, or None.

        The search reads no more than `limit` rows.
        """
        def matches(row):
            return row.key == key

        return next(filter(matches, self.rows[: self.limit]), None)

    class Meta:
        """Give the options of a repository."""

        ordering = ["name"]


def helper(repository, key):
    """Give the path of the row with `key` in `repository`, or None.

    The path joins the fields that `Repository.Meta.ordering` names with the
    path separator.
    """
    if repository.size == 0:
        return None
    row = repository.find(key)
    if row is None:
        return None
    return os.sep.join(str(getattr(row, field)) for field in repository.Meta.ordering)
