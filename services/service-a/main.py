"""
Service A — Microservicio FastAPI con instrumentacion OTel completa.

Flujo:
  1. Cliente llama GET /process/{item_id}
  2. Service A valida el input (custom span)
  3. Service A llama a Service B via HTTP (auto-span httpx + W3C propagation)
  4. Service A enriquece los datos (custom span)
  5. Service A crea una Order en PostgreSQL (auto-span SQLAlchemy)
  6. Retorna respuesta con datos del item y order_id

Pilares observables:
  - Trazas: spans anidados con propagacion de contexto W3C TraceContext
  - Metricas: request rate, latencia, contadores de negocio
  - Logs: JSON estructurado con trace_id/span_id para correlacion
"""
import logging
import os
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from pydantic import BaseModel

# ── Inicializar OTel ANTES de crear la app ────────────────────────────────
from database import Order, engine, get_db, init_db
from otel_setup import get_meter, get_tracer, setup_telemetry

setup_telemetry(db_engine=engine)

log = logging.getLogger(__name__)
SERVICE_B_URL = os.getenv("SERVICE_B_URL", "http://service-b:8001")

# ── Lifecycle ────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    log.info("Service A iniciado y listo para recibir trafico")
    yield
    log.info("Service A finalizando")


# ── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Service A",
    description="Microservicio A — orchestador de ordenes con OTel end-to-end",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    openapi_url="/openapi.json",
)

# Auto-instrumentacion FastAPI (HTTP server spans automaticos)
FastAPIInstrumentor.instrument_app(app)

tracer = get_tracer()
meter = get_meter()

# ── Metricas personalizadas (SLIs de negocio) ─────────────────────────────
orders_created = meter.create_counter(
    name="orders.created",
    description="Total de ordenes creadas exitosamente",
    unit="1",
)
processing_duration = meter.create_histogram(
    name="order.processing.duration",
    description="Tiempo total de procesamiento de una orden (ms)",
    unit="ms",
)
business_errors = meter.create_counter(
    name="business.errors",
    description="Errores de logica de negocio detectados",
    unit="1",
)
service_b_calls = meter.create_counter(
    name="service_b.calls",
    description="Total de llamadas realizadas a Service B",
    unit="1",
)


# ── Modelos Pydantic ──────────────────────────────────────────────────────
class ProcessResponse(BaseModel):
    order_id: int
    item: dict
    status: str
    processing_time_ms: float
    trace_id: str


class HealthResponse(BaseModel):
    status: str
    service: str
    version: str


# ── Endpoints ─────────────────────────────────────────────────────────────

@app.get("/health", response_model=HealthResponse, tags=["Infraestructura"])
async def health():
    """Health check — usado por load balancers y readiness probes."""
    return HealthResponse(status="ok", service="service-a", version="1.0.0")


@app.get(
    "/process/{item_id}",
    response_model=ProcessResponse,
    summary="Procesar item y crear orden",
    tags=["Negocio"],
)
async def process_item(item_id: int):
    """
    Endpoint principal de negocio.
    Demuestra trazas distribuidas end-to-end:
      service-a (validate) → service-a (fetch from service-b) → service-a (create order in DB)
    El trace_id se propaga automaticamente via W3C TraceContext headers.
    """
    start = time.monotonic()

    # Extraer trace_id del span activo (para incluirlo en la respuesta)
    current_span = trace.get_current_span()
    ctx = current_span.get_span_context()
    trace_id_hex = format(ctx.trace_id, "032x") if ctx and ctx.is_valid else "N/A"

    # ── Custom span: validacion de input ────────────────────────────────────
    with tracer.start_as_current_span("validate_item_request") as span:
        span.set_attribute("input.item_id", item_id)
        if item_id <= 0:
            span.set_status(trace.StatusCode.ERROR, "item_id debe ser positivo")
            span.set_attribute("validation.failed", True)
            business_errors.add(1, {"reason": "invalid_item_id", "service": "service-a"})
            log.warning("Validacion fallida: item_id invalido", extra={"item_id": item_id})
            raise HTTPException(status_code=400, detail="item_id debe ser un entero positivo")
        span.set_attribute("validation.passed", True)
        log.info("Validacion exitosa", extra={"item_id": item_id})

    # ── Llamada a Service B (httpx auto-instrumented + W3C context propagation) ──
    with tracer.start_as_current_span("call_service_b") as span:
        span.set_attribute("http.request.url", f"{SERVICE_B_URL}/items/{item_id}")
        span.set_attribute("peer.service", "service-b")
        service_b_calls.add(1, {"item_id": str(item_id)})
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(f"{SERVICE_B_URL}/items/{item_id}")
                response.raise_for_status()
                item_data = response.json()
            span.set_attribute("http.response.status_code", response.status_code)
            span.set_attribute("item.name", item_data.get("name", ""))
            span.set_attribute("item.availability", item_data.get("availability", ""))
            log.info(
                "Item obtenido de Service B",
                extra={"item_id": item_id, "item_name": item_data.get("name")},
            )
        except httpx.HTTPStatusError as exc:
            span.record_exception(exc)
            span.set_status(trace.StatusCode.ERROR, f"Service B devolvio {exc.response.status_code}")
            business_errors.add(1, {"reason": "service_b_http_error"})
            log.error("Service B respondio con error", extra={"status": exc.response.status_code})
            raise HTTPException(status_code=502, detail=f"Service B error: {exc}")
        except httpx.RequestError as exc:
            span.record_exception(exc)
            span.set_status(trace.StatusCode.ERROR, "No se pudo conectar a Service B")
            business_errors.add(1, {"reason": "service_b_unreachable"})
            log.error("Service B inalcanzable", extra={"url": f"{SERVICE_B_URL}/items/{item_id}"})
            raise HTTPException(status_code=503, detail=f"Service B no disponible: {exc}")

    # ── Custom span: enriquecimiento de datos ────────────────────────────────
    with tracer.start_as_current_span("enrich_order_data") as span:
        span.set_attribute("item.price", item_data.get("price", 0.0))
        total_price = item_data.get("price", 0.0) * 1.19  # + IVA simulado
        item_data["total_with_tax"] = round(total_price, 2)
        span.set_attribute("order.total_with_tax", total_price)
        log.info("Datos enriquecidos con impuestos", extra={"total": total_price})

    # ── Custom span: persistencia en DB (SQLAlchemy auto-instrumented) ────────
    with tracer.start_as_current_span("persist_order") as span:
        span.set_attribute("db.table", "orders")
        span.set_attribute("order.item_id", item_id)
        with get_db() as db:
            order = Order(
                item_id=item_id,
                status="completed",
                total_price=round(total_price, 2),
            )
            db.add(order)
            db.commit()
            db.refresh(order)
            span.set_attribute("order.id", order.id)
            span.set_attribute("order.status", order.status)
            log.info("Orden persistida en DB", extra={"order_id": order.id, "item_id": item_id})

    # ── Metricas de negocio ───────────────────────────────────────────────
    elapsed_ms = (time.monotonic() - start) * 1000
    orders_created.add(1, {"status": "completed", "item_id": str(item_id)})
    processing_duration.record(elapsed_ms, {"status": "completed"})

    log.info(
        "Procesamiento completado",
        extra={
            "order_id": order.id,
            "item_id": item_id,
            "processing_ms": round(elapsed_ms, 2),
        },
    )

    return ProcessResponse(
        order_id=order.id,
        item=item_data,
        status="completed",
        processing_time_ms=round(elapsed_ms, 2),
        trace_id=trace_id_hex,
    )


@app.get("/orders", summary="Listar ordenes recientes", tags=["Negocio"])
async def list_orders(limit: int = 20):
    """Lista las ultimas ordenes creadas en la base de datos."""
    with tracer.start_as_current_span("list_orders_db") as span:
        span.set_attribute("query.limit", limit)
        with get_db() as db:
            orders = (
                db.query(Order)
                .order_by(Order.created_at.desc())
                .limit(limit)
                .all()
            )
            span.set_attribute("result.count", len(orders))
            log.info("Listado de ordenes consultado", extra={"count": len(orders)})
            return [
                {
                    "id": o.id,
                    "item_id": o.item_id,
                    "status": o.status,
                    "total_price": o.total_price,
                    "created_at": o.created_at.isoformat(),
                }
                for o in orders
            ]


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    """Handler global — loguea excepciones no capturadas con contexto OTel."""
    span = trace.get_current_span()
    span.record_exception(exc)
    span.set_status(trace.StatusCode.ERROR, str(exc))
    log.exception("Excepcion no manejada", extra={"path": str(request.url)})
    return JSONResponse(status_code=500, content={"detail": "Error interno del servidor"})
