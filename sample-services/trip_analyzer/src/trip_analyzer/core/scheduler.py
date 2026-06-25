from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.jobstores.memory import MemoryJobStore
from datetime import datetime, timedelta
from trip_analyzer.config.logging import logger
from trip_analyzer.core.processor import Processor


class TripScheduler:

    def __init__(self, processor: Processor):
        self._processor: Processor = processor
        # Configuration for the In-Memory store
        jobstores = {
            'default': MemoryJobStore()
        }
        # Use AsyncIOScheduler to play nice with FastAPI's event loop
        self.scheduler = AsyncIOScheduler(jobstores=jobstores)

    def start(self):
        self.scheduler.start()
        logger.info("APScheduler started (In-Memory)")

    def shutdown(self):
        self.scheduler.shutdown()
        logger.info("APScheduler shut down")

    def schedule_analysis(self, vehicle_id: str, interval_seconds: int):
        job = self.scheduler.add_job(
            self._execute_analysis,
            'interval',
            seconds=interval_seconds,
            args=[vehicle_id],
            id=f"recurring_{vehicle_id}",
            replace_existing=True,
            next_run_time=datetime.now()
        )
        logger.info("Recurring job scheduled", vehicle_id=vehicle_id, interval=interval_seconds)
        return job.id

    def stop_analysis(self, vehicle_id: str):
        self.scheduler.remove_job(f"recurring_{vehicle_id}")
        logger.info("Recurring job removed", vehicle_id=vehicle_id)

    def retrieve_jobs(self):
        jobs = self.scheduler.get_jobs(jobstore="default")

        job_list = [job.id for job in jobs]
        return job_list

    async def _execute_analysis(self, vehicle_id: str):
        logger.debug("Checking for trip started", vehicle_id=vehicle_id)
        await self._processor.scoreDrivingStyle(vehicle_id)
