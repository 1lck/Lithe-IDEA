#!/usr/bin/env python3
"""Module docstring."""
import os
from typing import Optional

@dataclass(frozen=True)
class Point(Base):
    x: int = 0

    def norm(self, scale: float = 1.5e3) -> Optional[float]:
        # A comment
        if self.x > 0 and not None:
            return f"{self.x!r:>10} items\n" + r'\d+' + b"\x00"
        return [i ** 2 for i in range(0x1F) if i % 2 == 0]

async def main():
    await asyncio.sleep(1)
    lambda y: y + 1
