# otel_setup.py para service-b — identico a service-a.
# El nombre de servicio se configura via la variable de entorno OTEL_SERVICE_NAME.
# Copiar este archivo es intencional: cada servicio es un proceso independiente
# con su propio TracerProvider/MeterProvider/LoggerProvider.

"""
OpenTelemetry SDK setup — configura los tres pilares de observabilidad:
  - Trazas:  OTLPSpanExporter   → OTel Collector → Jaeger
  - Metricas: OTLPMetricExporter → OTel Collector → Prometheus
  - Logs:    OTLPLogExporter    → OTel Collector → Cloud Logging / CloudWatch
             + JSON estructurado en stdout con trace_id/span_id inyectados
"""
import json
import logging
import os

from opentelemetry import metrics, trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

SERVICE_NAME_VAL = os.getenv("OTEL_SERVICE_NAME", "service-b")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
OTEL_DISABLED = os.getenv("OTEL_SDK_DISABLED", "false").lower() == "true"


class OTelJSONFormatter(logging.Formatter):
    """
    Formatter de logs en JSON estructurado.
    Inyecta trace_id y span_id del span activo de OTel en cada log record,
    habilitando correlacion cross-signal (logs ↔ trazas) en Grafana Explorer.
    """

    def format(self, record: logging.LogRecord) -> str:
        span = trace.get_current_span()
        ctx = span.get_span_context()
        log_entry = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
            "service": SERVICE_NAME_VAL,
            "environment": os.getenv("DEPLOYMENT_ENV", "development"),
            "cloud_provider": os.getenv("CLOUD_PROVIDER", "local"),
            "trace_id": format(ctx.trace_id, "032x") if ctx and ctx.is_valid else "",
            "span_id": format(ctx.span_id, "016x") if ctx and ctx.is_valid else "",
            "trace_flags": format(ctx.trace_flags, "02x") if ctx and ctx.is_valid else "",
        }
        if record.exc_info:
            log_entry["exception"] = self.formatException(record.exc_info)
        if record.stack_info:
            log_entry["stack_info"] = self.formatStack(record.stack_info)
        return json.dumps(log_entry, ensure_ascii=False)


def _configure_logging() -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(OTelJSONFormatter())
    logging.basicConfig(level=logging.INFO, handlers=[handler], force=True)


def setup_telemetry(db_engine=None) -> None:
    _configure_logging()
    log = logging.getLogger(__name__)

    if OTEL_DISABLED:
        log.info("OTel SDK deshabilitado (OTEL_SDK_DISABLED=true) — modo baseline")
        return

    resource = Resource.create({
        "service.name": SERVICE_NAME_VAL,
        "service.version": os.getenv("SERVICE_VERSION", "1.0.0"),
        "service.instance.id": os.getenv("POD_NAME", os.getenv("HOSTNAME", SERVICE_NAME_VAL)),
        "cloud.provider": os.getenv("CLOUD_PROVIDER", "local"),
        "deployment.environment": os.getenv("DEPLOYMENT_ENV", "development"),
    })

    # Trazas
    tracer_provider = TracerProvider(resource=resource)
    span_exporter = OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(span_exporter, max_export_batch_size=512, export_timeout_millis=30_000)
    )
    trace.set_tracer_provider(tracer_provider)

    # Metricas
    metric_exporter = OTLPMetricExporter(endpoint=OTLP_ENDPOINT, insecure=True)
    metric_reader = PeriodicExportingMetricReader(
        metric_exporter, export_interval_millis=15_000, export_timeout_millis=10_000
    )
    meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(meter_provider)

    # Logs
    logger_provider = LoggerProvider(resource=resource)
    log_exporter = OTLPLogExporter(endpoint=OTLP_ENDPOINT, insecure=True)
    logger_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))
    set_logger_provider(logger_provider)
    LoggingInstrumentor().instrument(set_logging_format=False)

    # DB auto-instrumentation
    if db_engine is not None:
        from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
        SQLAlchemyInstrumentor().instrument(engine=db_engine)

    log.info("OTel SDK inicializado", extra={"otlp_endpoint": OTLP_ENDPOINT, "service": SERVICE_NAME_VAL})


def get_tracer(name: str | None = None) -> trace.Tracer:
    return trace.get_tracer(name or SERVICE_NAME_VAL, schema_url="https://opentelemetry.io/schemas/1.24.0")


def get_meter(name: str | None = None) -> metrics.Meter:
    return metrics.get_meter(name or SERVICE_NAME_VAL, schema_url="https://opentelemetry.io/schemas/1.24.0")
