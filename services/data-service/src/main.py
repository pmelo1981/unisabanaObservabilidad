"""
data-service — tercer microservicio: acceso a datos multi-cloud.

Expone el mismo recurso "records" respaldado por dos bases de datos
PostgreSQL independientes (GCP Cloud SQL y AWS RDS/simulado), instrumentado
con OTel SDK completo (trazas, metricas, logs) y OTel DB Semantic
Conventions en cada operacion de base de datos.

Endpoints:
  GET  /health              -> estado del servicio y de cada backend de DB
  GET  /gcp/records         -> lista registros desde Cloud SQL (GCP)
  POST /gcp/records         -> crea un registro en Cloud SQL (GCP)
  GET  /aws/records         -> lista registros desde el backend AWS RDS
  POST /aws/records         -> crea un registro en el backend AWS RDS
  GET  /records             -> vista federada: agrega ambos backends en un
                               unico trace, demostrando la topologia
                               multi-cloud dentro de una sola peticion
"""
import logging
import os
import time
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from pydantic import BaseModel

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

# ── Metricas de negocio ────────────────────────────────────────────────────
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
    log.info("data-service listo", extra={"db_providers": db_registry.available_providers()})
    yield
    await db_registry.close_all()
    log.info("data-service finalizando")


app = FastAPI(
    title="Data Service",
    description="Acceso multi-cloud a datos (GCP Cloud SQL + AWS RDS) con OTel SDK completo",
    version="0.2.0",
    lifespan=lifespan,
)
FastAPIInstrumentor().instrument_app(app)


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
    """Registros desde el backend AWS RDS (en este despliegue, simulado dentro de GKE)."""
    return await _list_records("aws")


@app.post("/aws/records", response_model=Record, tags=["AWS RDS"])
async def create_aws_record(payload: RecordCreate):
    return await _create_record("aws", payload)


@app.get("/records", tags=["Federado"])
async def list_federated_records():
    """
    Vista federada: consulta ambos backends dentro de la misma traza,
    demostrando la topologia multi-cloud (GCP + AWS) en un solo request.
    """
    with tracer.start_as_current_span("federated_records_query") as span:
        span.set_attribute("app.providers_queried", db_registry.available_providers())
        result = {}
        for provider in db_registry.available_providers():
            result[provider] = await _list_records(provider)
        return result
