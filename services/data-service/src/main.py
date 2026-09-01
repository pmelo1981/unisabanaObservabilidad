"""
data-service — tercer microservicio: acceso a datos multi-cloud.
================================================================
Acceso dual a bases de datos PostgreSQL (GCP Cloud SQL + AWS RDS simulado),
integrado con OpenTelemetry SDK completo, motor de Chaos Engineering en caliente
y detector de anomalias/avalancha de alertas operativas.
"""
import asyncio
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Any, Dict, Optional

import asyncpg
from fastapi import FastAPI, HTTPException, Request, Response
from opentelemetry import trace
from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from pydantic import BaseModel

from anomaly_detector import detector
from chaos_engine import chaos_engine
from database import DbRegistry, db_span
from otel_setup import get_meter, get_tracer, setup_telemetry

setup_telemetry()

# Auto-instrumentacion de asyncpg: genera automaticamente db.system,
# db.statement, db.name, server.address/port por cada query (OTel DB
# Semantic Conventions) sobre TODAS las conexiones abiertas despues de esto.
AsyncPGInstrumentor().instrument()

log = logging.getLogger(__name__)
tracer = get_tracer()
meter = get_meter()

db_registry = DbRegistry()
db_registry.register("gcp", os.getenv("CLOUD_SQL_DSN"))
db_registry.register("aws", os.getenv("AWS_RDS_DSN"))

# ── Metricas de negocio OTel ───────────────────────────────────────────────
records_created = meter.create_counter(
    name="data_service.records.created",
    description="Total de registros creados, por proveedor de base de datos",
    unit="1",
)
db_query_duration = meter.create_histogram(
    name="data_service.db.query.duration",
    description="Duracion de operaciones de base de datos por proveedor",
    unit="ms",
)
db_errors = meter.create_counter(
    name="data_service.db.errors",
    description="Errores de base de datos por proveedor",
    unit="1",
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    if not db_registry.available_providers():
        log.warning("data-service iniciando sin ningun backend de DB configurado")
    await db_registry.connect_all()
    log.info("data-service listo con Chaos Engineering y Anomaly Detection", extra={"db_providers": db_registry.available_providers()})
    yield
    await db_registry.close_all()
    log.info("data-service finalizando")


app = FastAPI(
    title="Data Service",
    description="Acceso multi-cloud a datos con OTel SDK, Chaos Engineering y Anomaly Detection",
    version="0.4.0",
    lifespan=lifespan,
)

CHAOS_CONTROL_ENABLED = os.getenv("CHAOS_CONTROL_ENABLED", "false").lower() == "true"


# ── Middleware 1: Chaos Engineering Interceptor ────────────────────────────
@app.middleware("http")
async def chaos_middleware(request: Request, call_next):
    # Inyecta latencia real y excepciones reales si el experimento esta activo
    await chaos_engine.maybe_inject_fault(request.url.path)
    return await call_next(request)


# ── Middleware 2: Anomaly Tracking Middleware sobre Trafico REAL ───────────
@app.middleware("http")
async def anomaly_tracking_middleware(request: Request, call_next):
    start_time = time.monotonic()
    response = None
    status_code = 500
    is_error = False
    error_msg = None

    try:
        response = await call_next(request)
        status_code = response.status_code
        is_error = status_code >= 400
    except Exception as exc:
        is_error = True
        error_msg = str(exc)
        if isinstance(exc, HTTPException):
            status_code = exc.status_code
        raise exc
    finally:
        duration_ms = (time.monotonic() - start_time) * 1000.0

        # Extraer trace_id y span_id activos del contexto OTel
        span = trace.get_current_span()
        ctx = span.get_span_context() if span else None
        trace_id_hex = format(ctx.trace_id, "032x") if ctx and ctx.is_valid else ""
        span_id_hex = format(ctx.span_id, "016x") if ctx and ctx.is_valid else ""

        path = request.url.path
        provider = "gcp" if "/gcp" in path else ("aws" if "/aws" in path else "multi-cloud")

        # Registrar UNICAMENTE peticiones reales de datos
        if not path.startswith("/chaos") and not path.startswith("/anomalies") and not path.startswith("/alerts") and not path.startswith("/docs") and not path.startswith("/openapi"):
            detector.record_request(
                duration_ms=duration_ms,
                is_error=is_error,
                status_code=status_code,
                trace_id=trace_id_hex,
                span_id=span_id_hex,
                provider=provider,
                route=path,
                error_message=error_msg,
            )

    return response


FastAPIInstrumentor().instrument_app(app)


# ── Modelos Pydantic ───────────────────────────────────────────────────────
class Record(BaseModel):
    id: int
    data: str
    created_at: str


class RecordCreate(BaseModel):
    data: str


class HealthResponse(BaseModel):
    status: str
    service: str
    db_backends: dict[str, str]


class ChaosExperimentRequest(BaseModel):
    scenario: str = "normal"  # "normal", "latency_jitter", "transient_errors", "flapping", "coordinated_incident"
    latency_ms: float = 0.0
    latency_rate: float = 0.0
    error_rate: float = 0.0
    error_status_code: int = 500
    error_message: str = "ChaosEngine: Database connection timeout / pool exhaustion"


class EpochRequest(BaseModel):
    epoch: int  # 1 o 2
    window_sec: Optional[int] = None


# ── Operaciones de Base de Datos Reales ─────────────────────────────────────
async def _list_records(provider: str) -> list[Record]:
    target = db_registry.get(provider)
    start = time.monotonic()
    try:
        async with db_span(tracer, target, "select", "records"):
            async with target.pool.acquire() as conn:
                rows = await conn.fetch("SELECT id, data, created_at FROM records ORDER BY id DESC LIMIT 50")
        db_query_duration.record((time.monotonic() - start) * 1000, {"provider": provider, "operation": "select"})
        return [Record(id=r["id"], data=r["data"], created_at=r["created_at"].isoformat()) for r in rows]
    except (asyncpg.PostgresError, OSError) as exc:
        db_errors.add(1, {"provider": provider, "operation": "select"})
        log.error("Fallo consultando records", extra={"provider": provider, "error": str(exc)})
        raise HTTPException(status_code=503, detail=f"Backend {provider} no disponible") from exc


async def _create_record(provider: str, payload: RecordCreate) -> Record:
    target = db_registry.get(provider)
    start = time.monotonic()
    try:
        async with db_span(tracer, target, "insert", "records") as span:
            span.set_attribute("app.record.data_length", len(payload.data))
            async with target.pool.acquire() as conn:
                row = await conn.fetchrow(
                    "INSERT INTO records (data) VALUES ($1) RETURNING id, data, created_at",
                    payload.data,
                )
        db_query_duration.record((time.monotonic() - start) * 1000, {"provider": provider, "operation": "insert"})
        records_created.add(1, {"provider": provider})
        log.info("Registro creado", extra={"provider": provider, "record_id": row["id"]})
        return Record(id=row["id"], data=row["data"], created_at=row["created_at"].isoformat())
    except (asyncpg.PostgresError, OSError) as exc:
        db_errors.add(1, {"provider": provider, "operation": "insert"})
        log.error("Fallo creando record", extra={"provider": provider, "error": str(exc)})
        raise HTTPException(status_code=503, detail=f"Backend {provider} no disponible") from exc


# ── Endpoints de Negocio (Trafico Real) ────────────────────────────────────

@app.get("/health", response_model=HealthResponse, tags=["Infraestructura"])
async def health():
    backends = {}
    for provider in ("gcp", "aws"):
        if provider not in db_registry.available_providers():
            backends[provider] = "not_configured"
            continue
        try:
            target = db_registry.get(provider)
            async with target.pool.acquire() as conn:
                await conn.fetchval("SELECT 1")
            backends[provider] = "ok"
        except Exception:
            backends[provider] = "unreachable"
    return HealthResponse(status="ok", service="data-service", db_backends=backends)


@app.get("/gcp/records", response_model=list[Record], tags=["GCP Cloud SQL"])
async def list_gcp_records():
    """Registros desde GCP Cloud SQL (PostgreSQL)."""
    return await _list_records("gcp")


@app.post("/gcp/records", response_model=Record, tags=["GCP Cloud SQL"])
async def create_gcp_record(payload: RecordCreate):
    return await _create_record("gcp", payload)


@app.get("/aws/records", response_model=list[Record], tags=["AWS RDS"])
async def list_aws_records():
    """Registros desde el backend AWS RDS."""
    return await _list_records("aws")


@app.post("/aws/records", response_model=Record, tags=["AWS RDS"])
async def create_aws_record(payload: RecordCreate):
    return await _create_record("aws", payload)


@app.get("/records", tags=["Federado"])
async def list_federated_records():
    """Vista federada: consulta ambos backends dentro de la misma traza."""
    with tracer.start_as_current_span("federated_records_query") as span:
        span.set_attribute("app.providers_queried", db_registry.available_providers())
        result = {}
        for provider in db_registry.available_providers():
            result[provider] = await _list_records(provider)
        return result


# ── Endpoints de Chaos Engineering ─────────────────────────────────────────

@app.post("/chaos/experiment", tags=["Chaos Engineering"])
async def set_chaos_experiment(req: ChaosExperimentRequest):
    """Configura e inyecta fallas reales de Chaos Engineering en caliente."""
    if not CHAOS_CONTROL_ENABLED:
        raise HTTPException(status_code=403, detail="Chaos control is disabled")
    return chaos_engine.configure(
        scenario=req.scenario,
        latency_ms=req.latency_ms,
        latency_rate=req.latency_rate,
        error_rate=req.error_rate,
        error_status_code=req.error_status_code,
        error_message=req.error_message,
    )


@app.get("/chaos/status", tags=["Chaos Engineering"])
async def get_chaos_status():
    """Retorna el estado activo del motor de caos y estadisticas de fallas inyectadas."""
    return {"control_enabled": CHAOS_CONTROL_ENABLED, **chaos_engine.get_status()}


@app.post("/chaos/reset", tags=["Chaos Engineering"])
async def reset_chaos():
    """Desactiva todas las fallas de caos."""
    if not CHAOS_CONTROL_ENABLED:
        raise HTTPException(status_code=403, detail="Chaos control is disabled")
    return chaos_engine.reset()


# ── Endpoints de Anomalias y Avalancha de Notificaciones (Ops View) ────────

@app.get("/anomalies/status", tags=["Observabilidad / Anomaly Detection"])
async def get_anomaly_status():
    """Retorna el estado de la linea base estadistica dinamica y evaluacion de alertas."""
    return await detector.evaluate()


@app.get("/anomalies/alerts", tags=["Observabilidad / Anomaly Detection"])
async def get_enriched_alerts(limit: int = 20):
    """Retorna las alertas enriquecidas con trace_id generadas sobre trafico real."""
    return detector.get_alerts(limit=limit)


@app.post("/anomalies/epoch", tags=["Observabilidad / Anomaly Detection"])
async def set_anomaly_epoch(req: EpochRequest):
    """Establece la epoca activa de evaluacion (1=Estatico, 2=Correlacionado)."""
    if req.epoch not in (1, 2):
        raise HTTPException(status_code=400, detail="La epoca debe ser 1 o 2")
    detector.set_epoch(req.epoch, window_sec=req.window_sec)
    return {"status": "epoch_updated", "active_epoch": req.epoch, "window_sec": detector.window_seconds}


@app.post("/anomalies/reset", tags=["Observabilidad / Anomaly Detection"])
async def reset_anomalies():
    """Reinicia el buffer y estadisticos del detector de anomalias."""
    detector.reset()
    return {"status": "reset_successful", "message": "Buffer y contadores reiniciados"}


@app.post("/alerts/webhook", tags=["Alert Avalanche Simulator"])
async def alert_webhook_receiver(payload: Dict[str, Any]):
    """Webhook receptor de alertas de Prometheus Alertmanager / Grafana."""
    detector.record_webhook_notification(payload)
    return {"status": "notification_received", "total": detector.total_notifications_count}


@app.get("/alerts/notifications", tags=["Alert Avalanche Simulator"])
async def get_alert_notifications(limit: int = 50):
    """Retorna la bandeja de notificaciones en vivo de Ops."""
    return detector.get_notifications(limit=limit)
