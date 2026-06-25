import json
from fastapi import APIRouter, Response, Request
from starlette.responses import JSONResponse
from trip_analyzer.config.config import settings

router = APIRouter()


@router.post(path="/{id}")
async def schedule_analysis(request: Request, id: str):
    scheduler = request.app.state.scheduler
    scheduler.schedule_analysis(id, settings.data_poll_interval)
    return JSONResponse(status_code=201, content=None)


@router.get(path="")
async def retrieve_scheduled(request: Request):
    scheduler = request.app.state.scheduler
    jobs = scheduler.retrieve_jobs()
    return JSONResponse(status_code=200, content={"jobs": jobs})


@router.delete(path="/{id}")
async def remove_analysis(request: Request, id: str):
    scheduler = request.app.state.scheduler
    scheduler.stop_analysis(id)
    return JSONResponse(status_code=200, content=None)
