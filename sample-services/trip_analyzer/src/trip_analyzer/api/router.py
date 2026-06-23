from fastapi import APIRouter
from trip_analyzer.api.endpoints import schedule, trips, healthcheck

api_router = APIRouter()

api_router.include_router(schedule.router, prefix="/schedule", tags=["Schedule"])
api_router.include_router(healthcheck.router, prefix="/health", tags=["Health"])
api_router.include_router(trips.router, prefix="/trips", tags=["Trips"])
