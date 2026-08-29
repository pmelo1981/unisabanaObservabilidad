import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import List
import asyncpg

# OpenTelemetry imports
from opentelemetry import trace, metrics, logs
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.logs import LoggerProvider
from opentelemetry.sdk.logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.grpc.logs_exporter import OTLPLogExporter

# Resource describing this service
resource = Resource.create({
    "service.name": "data-service",
    "service.version": "0.1.0",
    "deployment.environment": os.getenv("ENVIRONMENT", "dev"),
})

# Tracing setup
trace.set_tracer_provider(TracerProvider(resource=resource))
tracer = trace.get_tracer(__name__)
otlp_exporter = OTLPSpanExporter(endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317"), insecure=True)
span_processor = BatchSpanProcessor(otlp_exporter)
trace.get_tracer_provider().add_span_processor(span_processor)

# Metrics setup
metric_exporter = OTLPMetricExporter(endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317"), insecure=True)
metric_reader = PeriodicExportingMetricReader(metric_exporter, export_interval_millis=5000)
metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[metric_reader]))

# Logging setup
log_exporter = OTLPLogExporter(endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317"), insecure=True)
logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))
logs.set_logger_provider(logger_provider)

# Instrument asyncpg (PostgreSQL driver)
AsyncPGInstrumentor().instrument()

app = FastAPI(title="Data Service", version="0.1.0")
FastAPIInstrumentor().instrument_app(app)

# Database connection settings (use env variables)
CLOUD_SQL_DSN = os.getenv("CLOUD_SQL_DSN")  # e.g. postgresql://user:pass@host:5432/dbname

class Record(BaseModel):
    id: int
    data: str

async def get_connection(dsn: str):
    return await asyncpg.connect(dsn)

@app.get("/records", response_model=List[Record])
async def list_records():
    """Retrieve records from Cloud SQL database."""
    dsn = CLOUD_SQL_DSN
    if not dsn:
        raise HTTPException(status_code=500, detail="DSN not configured for Cloud SQL")
    conn = await get_connection(dsn)
    try:
        rows = await conn.fetch("SELECT id, data FROM records")
        return [Record(id=row["id"], data=row["data"]) for row in rows]
    finally:
        await conn.close()

@app.post("/records", response_model=Record)
async def create_record(record: Record):
    dsn = CLOUD_SQL_DSN
    if not dsn:
        raise HTTPException(status_code=500, detail="DSN not configured for Cloud SQL")
    conn = await get_connection(dsn)
    try:
        await conn.execute("INSERT INTO records (id, data) VALUES ($1, $2)", record.id, record.data)
        return record
    finally:
        await conn.close()
