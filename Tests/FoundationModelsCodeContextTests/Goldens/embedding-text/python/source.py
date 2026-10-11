import os


# A comment that is not the doc text in Python.
class Repository(Base):
    """Keep the rows of one table.

    The rows stay in memory.
    """

    limit = 10

    def __init__(self, name):
        self.name = name

    @property
    def size(self) -> int:
        return len(self.rows)

    def find(
        self,
        key,
    ):
        def matches(row):
            return row.key == key

        return None

    class Meta:
        ordering = ["name"]


def helper():
    return os.sep
