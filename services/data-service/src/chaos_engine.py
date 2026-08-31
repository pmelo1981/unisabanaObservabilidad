"""
Motor de Chaos Engineering a Nivel de Aplicacion — data-service
===============================================================
Permite inyectar fallas reales (latencia asincrona real y excepciones HTTP 503 reales)
sobre peticiones HTTP genuinas procesadas por FastAPI y PostgreSQL, garantizando
que OpenTelemetry capture trazas, spans y excepciones 100% organicas.
"""
import asyncio
import logging
import random
import time
from dataclasses import asdict, dataclass
from typing import Any, Dict, Optional

from fastapi import HTTPException, Request

log = logging.getLogger(__name__)


@dataclass
class ChaosExperiment:
    enabled: bool = False
    scenario: str = "normal"  # "normal", "latency_jitter", "transient_errors", "flapping", "coordinated_incident"
    latency_ms: float = 0.0
    latency_rate: float = 0.0  # Probabilidad de inyectar latencia (0.0 a 1.0)
    error_rate: float = 0.0  # Probabilidad de inyectar error (0.0 a 1.0)
    error_status_code: int = 503
    error_message: str = "ChaosEngine: Database connection timeout / pool exhaustion"
    flapping_interval_sec: float = 0.0  # Para oscilaciones de latencia


class ChaosEngine:
    """
    Motor de inyeccion de fallas de Chaos Engineering en caliente.
    """

    def __init__(self):
        self.experiment = ChaosExperiment()
        self.injected_delays_count = 0
        self.injected_errors_count = 0
        self.total_requests_intercepted = 0
        self.start_time = time.time()

    def configure(
        self,
        scenario: str = "normal",
        latency_ms: float = 0.0,
        latency_rate: float = 0.0,
        error_rate: float = 0.0,
        error_status_code: int = 503,
        error_message: str = "ChaosEngine: Database connection timeout / pool exhaustion",
    ) -> Dict[str, Any]:
        """Configura y activa un experimento de caos."""
        if scenario == "normal":
            self.experiment = ChaosExperiment(enabled=False, scenario="normal")
        elif scenario == "latency_jitter":
            self.experiment = ChaosExperiment(
                enabled=True,
                scenario="latency_jitter",
                latency_ms=latency_ms or 150.0,
                latency_rate=latency_rate or 1.0,
                error_rate=0.0,
            )
        elif scenario == "transient_errors":
            self.experiment = ChaosExperiment(
                enabled=True,
                scenario="transient_errors",
                latency_ms=latency_ms or 15.0,
                latency_rate=0.0,
                error_rate=error_rate or 0.10,
                error_status_code=error_status_code,
                error_message=error_message,
            )
        elif scenario == "flapping":
            self.experiment = ChaosExperiment(
                enabled=True,
                scenario="flapping",
                latency_ms=latency_ms or 65.0,  # Oscila alrededor de 50ms para causar flapping de alertas
                latency_rate=latency_rate or 0.85,
                error_rate=0.0,
            )
        elif scenario == "coordinated_incident":
            self.experiment = ChaosExperiment(
                enabled=True,
                scenario="coordinated_incident",
                latency_ms=latency_ms or 350.0,
                latency_rate=1.0,
                error_rate=error_rate or 0.50,
                error_status_code=error_status_code,
                error_message="ChaosEngine: CRITICAL - PostgreSQL connection pool exhausted and query timeout",
            )
        else:
            self.experiment = ChaosExperiment(
                enabled=True,
                scenario=scenario,
                latency_ms=latency_ms,
                latency_rate=latency_rate,
                error_rate=error_rate,
                error_status_code=error_status_code,
                error_message=error_message,
            )

        log.warning(f"Experimento de Chaos Engineering configurado: {self.experiment.scenario}")
        return self.get_status()

    def reset(self) -> Dict[str, Any]:
        """Desactiva todo el caos y restaura estado normal."""
        self.experiment = ChaosExperiment(enabled=False, scenario="normal")
        self.injected_delays_count = 0
        self.injected_errors_count = 0
        self.total_requests_intercepted = 0
        log.info("Chaos Engineering desactivado y contadores reiniciados.")
        return self.get_status()

    def get_status(self) -> Dict[str, Any]:
        """Retorna el estado del experimento activo y estadisticas."""
        return {
            "experiment": asdict(self.experiment),
            "stats": {
                "total_requests_intercepted": self.total_requests_intercepted,
                "injected_delays_count": self.injected_delays_count,
                "injected_errors_count": self.injected_errors_count,
            },
        }

    async def maybe_inject_fault(self, path: str) -> None:
        """
        Aplica fallas de latencia real y errores segun el experimento activo.
        Afecta unicamente a los endpoints de datos de base de datos.
        """
        # Excluir endpoints de administracion y health
        if path.startswith("/chaos") or path.startswith("/anomalies") or path.startswith("/alerts") or path.startswith("/health") or path.startswith("/docs") or path.startswith("/openapi"):
            return

        self.total_requests_intercepted += 1

        if not self.experiment.enabled:
            return

        # 1. Inyeccion de Latencia Real Asincrona
        if self.experiment.latency_ms > 0 and random.random() < self.experiment.latency_rate:
            delay_sec = (self.experiment.latency_ms + random.uniform(-10.0, 15.0)) / 1000.0
            if delay_sec > 0:
                await asyncio.sleep(delay_sec)
                self.injected_delays_count += 1

        # 2. Inyeccion de Error HTTP Real
        if self.experiment.error_rate > 0 and random.random() < self.experiment.error_rate:
            self.injected_errors_count += 1
            log.error(f"ChaosEngine inyectando excepcion {self.experiment.error_status_code} en {path}")
            raise HTTPException(
                status_code=self.experiment.error_status_code,
                detail=self.experiment.error_message,
            )


# Instancia singleton global del motor de caos
chaos_engine = ChaosEngine()

