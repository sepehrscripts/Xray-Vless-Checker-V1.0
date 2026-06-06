"""
Background scheduler — runs checks, fires Telegram alerts
"""
import asyncio, logging
from datetime import datetime
from typing import Callable, Awaitable

log = logging.getLogger("scheduler")

class Scheduler:
    def __init__(self):
        self._task: asyncio.Task | None = None
        self._report_task: asyncio.Task | None = None
        self._on_check: Callable | None = None
        self._on_report: Callable | None = None

    def set_check_handler(self, fn: Callable[[], Awaitable]):
        self._on_check = fn

    def set_report_handler(self, fn: Callable[[], Awaitable]):
        self._on_report = fn

    async def _loop(self, get_interval: Callable[[], Awaitable[int]]):
        while True:
            interval = await get_interval()
            if interval < 30:
                interval = 300
            try:
                if self._on_check:
                    await self._on_check()
            except Exception as e:
                log.error("Check error: %s", e)
            await asyncio.sleep(interval)

    async def _report_loop(self, get_interval: Callable[[], Awaitable[int]]):
        while True:
            interval = await get_interval()
            if interval <= 0:
                await asyncio.sleep(60)
                continue
            await asyncio.sleep(interval)
            try:
                if self._on_report:
                    await self._on_report()
            except Exception as e:
                log.error("Report error: %s", e)

    def start(self, get_interval: Callable, get_report_interval: Callable):
        if self._task and not self._task.done():
            self._task.cancel()
        if self._report_task and not self._report_task.done():
            self._report_task.cancel()
        self._task = asyncio.create_task(self._loop(get_interval))
        self._report_task = asyncio.create_task(self._report_loop(get_report_interval))
        log.info("Scheduler started")

    def trigger_now(self):
        """Fire an immediate check without waiting."""
        if self._on_check:
            asyncio.create_task(self._on_check())

scheduler = Scheduler()
