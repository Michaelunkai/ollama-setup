"""REST endpoint for system status"""
import asyncio
import subprocess
import re

from fastapi import APIRouter

from config import OLLAMA_URL, OLLAMA_MODEL
from models import StatusResponse
from engine.ollama_client import check_health, get_model_info

router = APIRouter()


async def _get_gpu_stats() -> dict:
    """Get GPU stats from nvidia-smi."""
    try:
        result = await asyncio.to_thread(
            subprocess.run,
            [
                "nvidia-smi",
                "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
                "--format=csv,noheader,nounits"
            ],
            capture_output=True, text=True, timeout=5,
            creationflags=0x08000000  # CREATE_NO_WINDOW
        )
        if result.returncode == 0 and result.stdout.strip():
            parts = [p.strip() for p in result.stdout.strip().split(",")]
            if len(parts) >= 5:
                return {
                    "gpu_name": parts[0],
                    "gpu_util_percent": float(parts[1]),
                    "vram_used_mb": float(parts[2]),
                    "vram_total_mb": float(parts[3]),
                    "gpu_temp_c": float(parts[4])
                }
    except Exception:
        pass
    return {}


@router.get("/status")
async def get_status() -> StatusResponse:
    # Run health check and GPU stats in parallel
    health_task = check_health(OLLAMA_URL)
    gpu_task = _get_gpu_stats()
    model_task = get_model_info(OLLAMA_URL, OLLAMA_MODEL)

    ollama_running, gpu_stats, model_info = await asyncio.gather(
        health_task, gpu_task, model_task
    )

    resp = StatusResponse(
        ollama_running=ollama_running,
        model_loaded=model_info is not None,
        model_name=OLLAMA_MODEL,
        context_size=131072,
    )

    if gpu_stats:
        resp.gpu_name = gpu_stats.get("gpu_name", "")
        resp.gpu_util_percent = gpu_stats.get("gpu_util_percent", 0)
        resp.vram_used_mb = gpu_stats.get("vram_used_mb", 0)
        resp.vram_total_mb = gpu_stats.get("vram_total_mb", 0)
        resp.gpu_temp_c = gpu_stats.get("gpu_temp_c", 0)

    if model_info:
        resp.context_size = model_info.get("details", {}).get("parameter_size", 131072)

    return resp
