"""
Capa de acceso a datos — Service A
Tablas: items (catalogo) y orders (pedidos).
La auto-instrumentacion de OTel (SQLAlchemyInstrumentor) se aplica
desde otel_setup.py despues de crear el engine, por lo que cada query
SQL genera un span hijo automaticamente.
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
    """Catalogo de productos. Compartida con Service B."""
    __tablename__ = "items"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(100), nullable=False)
    description = Column(Text)
    price = Column(Float, nullable=False, default=0.0)
    created_at = Column(DateTime, default=datetime.utcnow)


class Order(Base):
    """Registro de ordenes creadas por Service A."""
    __tablename__ = "orders"

    id = Column(Integer, primary_key=True, index=True)
    item_id = Column(Integer, nullable=False, index=True)
    status = Column(String(50), nullable=False, default="pending")
    total_price = Column(Float, nullable=False, default=0.0)
    created_at = Column(DateTime, default=datetime.utcnow)


# Engine global — SQLAlchemyInstrumentor lo capturara en otel_setup.py
engine = create_engine(
    DATABASE_URL,
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,
    pool_recycle=3600,
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def init_db() -> None:
    """Crea tablas y puebla datos iniciales de demostracion."""
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
    """Context manager para obtener una sesion de DB con cleanup garantizado."""
    db = SessionLocal()
    try:
        yield db
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
