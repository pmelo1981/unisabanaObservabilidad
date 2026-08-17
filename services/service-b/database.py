"""
Capa de acceso a datos — Service B
Tabla: items (catalogo de productos).
OTel SQLAlchemyInstrumentor se aplica desde otel_setup.py.
"""
import os
from contextlib import contextmanager
from datetime import datetime
from typing import Generator

from sqlalchemy import Column, DateTime, Float, Integer, String, Text, create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://postgres:postgres@postgres:5432/labdb",
)


class Base(DeclarativeBase):
    pass


class Item(Base):
    """Catalogo de productos compartido con Service A."""
    __tablename__ = "items"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    description = Column(Text)
    price = Column(Float, nullable=False, default=0.0)
    created_at = Column(DateTime, default=datetime.utcnow)


engine = create_engine(
    DATABASE_URL,
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,
    pool_recycle=3600,
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def init_db() -> None:
    """Crea la tabla items con datos de seed si no existe."""
    Base.metadata.create_all(bind=engine)
    with SessionLocal() as session:
        if session.query(Item).count() == 0:
            seed_items = [
                Item(
                    name=f"Producto-{i:02d}",
                    description=f"Articulo de demostracion numero {i}",
                    price=round(i * 9.99, 2),
                )
                for i in range(1, 11)
            ]
            session.add_all(seed_items)
            session.commit()


@contextmanager
def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
