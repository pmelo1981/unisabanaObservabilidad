"""
OpenTelemetry SDK setup para data-service — tres pilares de observabilidad:
  - Trazas:  OTLPSpanExporter   -> OTel Collector -> Jaeger
  - Metricas: OTLPMetricExporter -> OTel Collector -> Prometheus
  - Logs:    OTLPLogExporter    -> OTel Collector -> Cloud Logging
             + JSON estructurado en stdout con trace_id/span_id inyectados

Mismo patron que services/service-a/otel_setup.py, adaptado para el servicio
de datos conectado a GCP Cloud SQL.
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

SERVICE_NAME_VAL = os.getenv("OTEL_SERVICE_NAME", "data-service")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
OTEL_DISABLED = os.getenv("OTEL_SDK_DISABLED", "false").lower() == "true"


class OTelJSONFormatter(logging.Formatter):
    """Formatter JSON con trace_id/span_id inyectados para correlacion cross-signal."""

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
            "cloud_provider": os.getenv("CLOUD_PROVIDER", "gcp"),
            "trace_id": format(ctx.trace_id, "032x") if ctx and ctx.is_valid else "",
            "span_id": format(ctx.span_id, "016x") if ctx and ctx.is_valid else "",
            "trace_flags": format(ctx.trace_flags, "02x") if ctx and ctx.is_valid else "",
        }
        if record.exc_info:
            log_entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_entry, ensure_ascii=False)


def _configure_logging() -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(OTelJSONFormatter())
    logging.basicConfig(level=logging.INFO, handlers=[handler], force=True)


def setup_telemetry() -> None:
    """Inicializa los tres pilares del SDK de OpenTelemetry. Llamar antes de crear la app FastAPI."""
    _configure_logging()
    log = logging.getLogger(__name__)

    if OTEL_DISABLED:
        log.info("OTel SDK deshabilitado (OTEL_SDK_DISABLED=true) - modo baseline")
        return

    resource = Resource.create({
        "service.name": SERVICE_NAME_VAL,
        "service.version": os.getenv("SERVICE_VERSION", "0.1.0"),
        "cloud.provider": os.getenv("CLOUD_PROVIDER", "gcp"),
        "deployment.environment": os.getenv("DEPLOYMENT_ENV", "development"),
    })

    # ── Trazas ────────────────────────────────────────────────────────────
    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True))
    )
    trace.set_tracer_provider(tracer_provider)

    # ── Metricas ──────────────────────────────────────────────────────────
    metric_reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=OTLP_ENDPOINT, insecure=True),
        export_interval_millis=15_000,
    )
    metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[metric_reader]))

    # ── Logs ──────────────────────────────────────────────────────────────
    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter(endpoint=OTLP_ENDPOINT, insecure=True))
    )
    set_logger_provider(logger_provider)

    # Bridge: Python logging -> OTel LoggerProvider (sin sobrescribir el formatter JSON)
    LoggingInstrumentor().instrument(set_logging_format=False)

    log.info(
        "OTel SDK inicializado correctamente",
        extra={"otlp_endpoint": OTLP_ENDPOINT, "service": SERVICE_NAME_VAL},
    )


def get_tracer(name: str | None = None) -> trace.Tracer:
    return trace.get_tracer(name or SERVICE_NAME_VAL, schema_url="https://opentelemetry.io/schemas/1.27.0")


def get_meter(name: str | None = None) -> metrics.Meter:
    return metrics.get_meter(name or SERVICE_NAME_VAL, schema_url="https://opentelemetry.io/schemas/1.27.0")
