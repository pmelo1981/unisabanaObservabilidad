"""
Capa de acceso a datos — data-service.

Mantiene DOS pools de conexion independientes, uno por backend de base de
datos, para demostrar la arquitectura multi-cloud pedida en el enunciado:

  - "gcp": PostgreSQL en GCP Cloud SQL (CLOUD_SQL_DSN)
  - "aws": PostgreSQL equivalente a AWS RDS (AWS_RDS_DSN)

Nota de despliegue: este entorno es exclusivamente GCP (sin cuenta AWS activa).
El backend "aws" apunta, en este despliegue, a un Postgres corriendo dentro
del mismo cluster GKE (ver helm/data-service/templates/rds-sim.yaml) que
simula el rol de AWS RDS. El codigo es agnostico al proveedor real: si se
dispone de una instancia AWS RDS real, basta con apuntar AWS_RDS_DSN a ella
sin cambiar una linea de este modulo.

AsyncPGInstrumentor (instrumentado en otel_setup/main) genera automaticamente
los atributos base de OTel DB Semantic Conventions (db.system, db.statement,
db.name, server.address, server.port) para cada query ejecutada sobre estos
pools. db_span() añade encima los atributos que la auto-instrumentacion no
puede inferir por si sola: db.operation, db.sql.table y cloud.provider, para
poder distinguir en Jaeger que backend atendio cada operacion.
"""
import logging
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import AsyncIterator, Optional
from urllib.parse import urlparse

import asyncpg
from opentelemetry.trace import Span, Tracer

log = logging.getLogger(__name__)

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS records (
    id SERIAL PRIMARY KEY,
    data TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)
"""


@dataclass
class DbTarget:
    """Un backend de base de datos administrado (pool + metadatos para spans)."""

    provider: str  # "gcp" | "aws"
    dsn: str
    pool: Optional[asyncpg.Pool] = None

    @property
    def host(self) -> str:
        return urlparse(self.dsn).hostname or "unknown"

    @property
    def port(self) -> int:
        return urlparse(self.dsn).port or 5432

    @property
    def dbname(self) -> str:
        return (urlparse(self.dsn).path or "/").lstrip("/") or "unknown"

    async def connect(self) -> None:
        self.pool = await asyncpg.create_pool(self.dsn, min_size=1, max_size=5)
        async with self.pool.acquire() as conn:
            await conn.execute(CREATE_TABLE_SQL)
        log.info(
            "Pool de base de datos inicializado",
            extra={"provider": self.provider, "host": self.host, "db": self.dbname},
        )

    async def close(self) -> None:
        if self.pool is not None:
            await self.pool.close()


class DbRegistry:
    """Registro de los backends de DB disponibles (gcp obligatorio, aws opcional)."""

    def __init__(self) -> None:
        self.targets: dict[str, DbTarget] = {}

    def register(self, provider: str, dsn: Optional[str]) -> None:
        if dsn:
            self.targets[provider] = DbTarget(provider=provider, dsn=dsn)

    async def connect_all(self) -> None:
        for target in self.targets.values():
            await target.connect()

    async def close_all(self) -> None:
        for target in self.targets.values():
            await target.close()

    def get(self, provider: str) -> DbTarget:
        target = self.targets.get(provider)
        if target is None:
            raise KeyError(f"Backend de base de datos '{provider}' no configurado")
        return target

    def available_providers(self) -> list[str]:
        return list(self.targets.keys())


def db_span(tracer: Tracer, target: DbTarget, operation: str, table: str = "records"):
    """
    Context manager que abre un span hijo con atributos OTel DB Semantic
    Conventions que complementan a AsyncPGInstrumentor: db.operation,
    db.sql.table y cloud.provider (para diferenciar GCP vs AWS en Jaeger).
    """

    @asynccontextmanager
    async def _ctx() -> AsyncIterator[Span]:
        with tracer.start_as_current_span(f"db.{operation}.{table}") as span:
            span.set_attribute("db.system", "postgresql")
            span.set_attribute("db.operation", operation)
            span.set_attribute("db.sql.table", table)
            span.set_attribute("db.name", target.dbname)
            span.set_attribute("server.address", target.host)
            span.set_attribute("server.port", target.port)
            span.set_attribute("cloud.provider", target.provider)
            yield span

    return _ctx()
