"""
Service B — Microservicio FastAPI con instrumentacion OTel completa.

Responsabilidad: gestion del catalogo de items.
Es llamado por Service A. Demuestra propagacion de contexto W3C TraceContext:
el trace_id iniciado en Service A llega aqui como header HTTP y se continua.

Pilares observables:
  - Trazas: spans automaticos (FastAPI/SQLAlchemy) + custom spans de negocio
  - Metricas: item fetch rate, cache simulation, enrichment duration
  - Logs: JSON estructurado con trace_id inyectado automaticamente
"""
import logging
import os
import random
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from pydantic import BaseModel

# ── Inicializar OTel ANTES de crear la app ─────────────────────────────────
from database import Item, engine, get_db, init_db
from otel_setup import get_meter, get_tracer, setup_telemetry

setup_telemetry(db_engine=engine)

log = logging.getLogger(__name__)


# ── Lifecycle ─────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    log.info("Service B iniciado y listo para recibir trafico")
    yield
    log.info("Service B finalizando")


# ── App ────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="Service B",
    description="Microservicio B — catalogo de productos con OTel end-to-end",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    openapi_url="/openapi.json",
)

# Auto-instrumentacion FastAPI
FastAPIInstrumentor.instrument_app(app)

tracer = get_tracer()
meter = get_meter()

# ── Metricas personalizadas ───────────────────────────────────────────────
items_fetched = meter.create_counter(
    name="items.fetched",
    description="Total de items consultados exitosamente",
    unit="1",
)
cache_hits = meter.create_counter(
    name="cache.hits",
    description="Simulacion de hits en cache de items",
    unit="1",
)
cache_misses = meter.create_counter(
    name="cache.misses",
    description="Simulacion de misses en cache de items",
    unit="1",
)
enrichment_duration = meter.create_histogram(
    name="item.enrichment.duration",
    description="Tiempo de enriquecimiento de datos del item (ms)",
    unit="ms",
)
db_errors = meter.create_counter(
    name="db.errors",
    description="Errores de acceso a base de datos",
    unit="1",
)


# ── Modelos Pydantic ──────────────────────────────────────────────────────
class ItemResponse(BaseModel):
    id: int
    name: str
    description: str | None
    price: float
    availability: str
    stock_quantity: int
    enriched: bool
    cache_hit: bool


class ItemCreate(BaseModel):
    name: str
    description: str | None = None
    price: float = 0.0


class HealthResponse(BaseModel):
    status: str
    service: str
    version: str


# ── Endpoints ─────────────────────────────────────────────────────────────

@app.get("/health", response_model=HealthResponse, tags=["Infraestructura"])
async def health():
    """Health check — usado por load balancers y readiness probes."""
    return HealthResponse(status="ok", service="service-b", version="1.0.0")


@app.get(
    "/items/{item_id}",
    response_model=ItemResponse,
    summary="Obtener item por ID con enriquecimiento",
    tags=["Catalogo"],
)
async def get_item(item_id: int):
    """
    Retorna un item con datos enriquecidos (disponibilidad, stock).
    Demuestra continuacion de traza distribuida desde Service A:
      el trace_id de Service A se propaga via W3C traceparent header.
    """
    # ── Custom span: verificacion de cache (simulada) ────────────────────────
    with tracer.start_as_current_span("check_item_cache") as span:
        span.set_attribute("cache.key", f"item:v1:{item_id}")
        span.set_attribute("cache.backend", "redis-simulated")
        # Simulamos 35% de hit rate
        is_cache_hit = random.random() < 0.35
        span.set_attribute("cache.hit", is_cache_hit)
        if is_cache_hit:
            cache_hits.add(1, {"item_id": str(item_id)})
            log.info("Cache hit detectado", extra={"item_id": item_id, "cache_hit": True})
        else:
            cache_misses.add(1, {"item_id": str(item_id)})

    # ── Custom span: consulta a la base de datos ─────────────────────────────
    with tracer.start_as_current_span("fetch_item_from_db") as span:
        span.set_attribute("db.system", "postgresql")
        span.set_attribute("db.name", "labdb")
        span.set_attribute("db.table", "items")
        span.set_attribute("item.id", item_id)
        try:
            with get_db() as db:
                item = db.query(Item).filter(Item.id == item_id).first()
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(trace.StatusCode.ERROR, "Error de DB")
            db_errors.add(1, {"table": "items", "operation": "select"})
            log.error("Error al consultar DB", extra={"item_id": item_id})
            raise HTTPException(status_code=500, detail="Error de base de datos")

        if not item:
            span.set_status(trace.StatusCode.ERROR, "Item no encontrado")
            span.set_attribute("item.found", False)
            log.warning("Item no encontrado", extra={"item_id": item_id})
            raise HTTPException(status_code=404, detail=f"Item {item_id} no existe")

        span.set_attribute("item.found", True)
        span.set_attribute("item.name", item.name)
        span.set_attribute("item.price", item.price)
        log.info("Item encontrado en DB", extra={"item_id": item_id, "item_name": item.name})

    # ── Custom span: enriquecimiento con datos externos (simulado) ───────────
    enrich_start = time.monotonic()
    with tracer.start_as_current_span("enrich_item_data") as span:
        span.set_attribute("enrichment.source", "inventory-service-mock")
        span.set_attribute("item.id", item_id)

        # Simula latencia de servicio externo (5–25 ms)
        time.sleep(random.uniform(0.005, 0.025))

        # Simula disponibilidad y stock
        availability_options = ["in_stock", "low_stock", "out_of_stock"]
        weights = [0.60, 0.25, 0.15]
        availability = random.choices(availability_options, weights=weights)[0]
        stock_qty = {
            "in_stock": random.randint(50, 500),
            "low_stock": random.randint(1, 10),
            "out_of_stock": 0,
        }[availability]

        span.set_attribute("item.availability", availability)
        span.set_attribute("item.stock_quantity", stock_qty)
        log.info(
            "Item enriquecido con datos de inventario",
            extra={"item_id": item_id, "availability": availability, "stock": stock_qty},
        )

    enrich_ms = (time.monotonic() - enrich_start) * 1000
    enrichment_duration.record(enrich_ms, {"availability": availability})
    items_fetched.add(1, {"availability": availability, "cache_hit": str(is_cache_hit)})

    return ItemResponse(
        id=item.id,
        name=item.name,
        description=item.description,
        price=item.price,
        availability=availability,
        stock_quantity=stock_qty,
        enriched=True,
        cache_hit=is_cache_hit,
    )


@app.get("/items", summary="Listar todos los items", tags=["Catalogo"])
async def list_items(skip: int = 0, limit: int = 10):
    """Retorna una lista paginada de items del catalogo."""
    with tracer.start_as_current_span("list_items_db") as span:
        span.set_attribute("query.skip", skip)
        span.set_attribute("query.limit", limit)
        with get_db() as db:
            items = db.query(Item).offset(skip).limit(limit).all()
            span.set_attribute("result.count", len(items))
            log.info("Listado de items consultado", extra={"count": len(items)})
            return [
                {"id": i.id, "name": i.name, "price": i.price, "description": i.description}
                for i in items
            ]


@app.post("/items", response_model=ItemResponse, status_code=201, tags=["Catalogo"])
async def create_item(payload: ItemCreate):
    """Crea un nuevo item en el catalogo."""
    with tracer.start_as_current_span("create_item_db") as span:
        span.set_attribute("item.name", payload.name)
        span.set_attribute("item.price", payload.price)
        with get_db() as db:
            new_item = Item(
                name=payload.name,
                description=payload.description,
                price=payload.price,
            )
            db.add(new_item)
            db.commit()
            db.refresh(new_item)
            span.set_attribute("item.id", new_item.id)
            log.info("Item creado", extra={"item_id": new_item.id, "item_name": new_item.name})
            return ItemResponse(
                id=new_item.id,
                name=new_item.name,
                description=new_item.description,
                price=new_item.price,
                availability="in_stock",
                stock_quantity=100,
                enriched=False,
                cache_hit=False,
            )


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    span = trace.get_current_span()
    span.record_exception(exc)
    span.set_status(trace.StatusCode.ERROR, str(exc))
    log.exception("Excepcion no manejada", extra={"path": str(request.url)})
    return JSONResponse(status_code=500, content={"detail": "Error interno del servidor"})
