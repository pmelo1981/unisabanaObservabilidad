"""
Motor Local de Deteccion de Anomalias y Correlacion Multi-Señal — data-service
===============================================================================
Procesa peticiones HTTP REALES, calcula lineas base dinamicas (rolling z-score),
gestiona las 2 epocas de prueba y administra la bandeja de notificaciones
de alerta (Alert Avalanche Simulator) para Prometheus y Grafana.
"""
import asyncio
import logging
import math
import os
import time
from collections import deque
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import httpx
from opentelemetry import metrics

log = logging.getLogger(__name__)

JAEGER_API_URL = os.getenv("JAEGER_API_URL", "http://jaeger:16686")
JAEGER_PUBLIC_URL = os.getenv("JAEGER_PUBLIC_URL", "http://localhost:16686")
SLO_LATENCY_THRESHOLD_MS = float(os.getenv("SLO_LATENCY_THRESHOLD_MS", "200.0"))
STATIC_LATENCY_THRESHOLD_MS = float(os.getenv("STATIC_LATENCY_THRESHOLD_MS", "50.0"))
STATIC_ERROR_THRESHOLD = float(os.getenv("STATIC_ERROR_THRESHOLD", "0.0"))
WINDOW_SECONDS = int(os.getenv("ANOMALY_WINDOW_SECONDS", "60"))


@dataclass
class Sample:
    timestamp: float
    duration_ms: float
    is_error: bool
    status_code: int
    trace_id: str
    span_id: str
    provider: str
    route: str
    error_message: Optional[str] = None


@dataclass
class EnrichedAlert:
    alert_id: str
    timestamp: str
    epoch: int
    severity: str
    title: str
    rule_evaluated: str
    condition_description: str
    metrics: Dict[str, Any]
    trace_id: str
    span_id: str
    jaeger_url: str
    failing_route: str
    provider: str
    root_cause_summary: str


@dataclass
class NotificationItem:
    id: str
    timestamp: str
    epoch: int
    status: str  # "FIRING" | "RESOLVED"
    alertname: str
    severity: str  # "warning" | "critical"
    system_type: str  # "static_threshold" | "correlated_anomaly"
    summary: str
    description: str
    trace_id: Optional[str] = None
    jaeger_url: Optional[str] = None


class AnomalyDetector:
    """
    Detector estadistico de anomalias con ventana deslizante sobre trafico real,
    soporte de 2 epocas y gestor de bandeja de notificaciones (Alert Avalanche).
    """

    def __init__(self, window_seconds: int = WINDOW_SECONDS, slo_latency_ms: float = SLO_LATENCY_THRESHOLD_MS):
        self.window_seconds = window_seconds
        self.slo_latency_ms = slo_latency_ms
        self.samples: deque[Sample] = deque()
        self.alerts: List[EnrichedAlert] = []
        self.notifications: deque[NotificationItem] = deque(maxlen=200)
        self.notification_timestamps: deque[float] = deque()
        self.active_epoch: int = 1
        self.lock = asyncio.Lock()

        # Metricas en tiempo real
        self.current_error_z_score = 0.0
        self.current_latency_p99_ms = 0.0
        self.static_firing = 0
        self.correlated_firing = 0
        self.total_notifications_count = 0
        self.avalanche_rate_per_min = 0.0

        # Contadores separados por epoca
        self.stats = {
            "epoch_1_evaluations": 0,
            "epoch_1_static_alerts": 0,
            "epoch_1_notifications": 0,
            "epoch_2_evaluations": 0,
            "epoch_2_static_alerts": 0,
            "epoch_2_correlated_alerts": 0,
            "epoch_2_notifications": 0,
            "epoch_2_noise_filtered": 0,
        }

        # ── Registro de Instrumentos OTel para Prometheus ───────────────────
        meter = metrics.get_meter("data-service-anomalies", "2.0.0")

        meter.create_observable_gauge(
            name="anomaly_detector_static_firing",
            description="Estado de disparo de alerta estatica (1=firing, 0=ok)",
            callbacks=[lambda options: [metrics.Observation(self.static_firing)]],
        )
        meter.create_observable_gauge(
            name="anomaly_detector_correlated_firing",
            description="Estado de disparo de alerta correlacionada (1=firing, 0=ok)",
            callbacks=[lambda options: [metrics.Observation(self.correlated_firing)]],
        )
        meter.create_observable_gauge(
            name="anomaly_detector_error_z_score",
            description="Z-Score de la tasa de error actual vs baseline",
            callbacks=[lambda options: [metrics.Observation(self.current_error_z_score)]],
        )
        meter.create_observable_gauge(
            name="anomaly_detector_latency_p99_ms",
            description="Latencia percentil 99 en ms dentro de la ventana activa",
            callbacks=[lambda options: [metrics.Observation(self.current_latency_p99_ms)]],
        )
        meter.create_observable_gauge(
            name="anomaly_detector_active_epoch",
            description="Epoca activa de evaluacion (1=Estatico, 2=Correlacionado)",
            callbacks=[lambda options: [metrics.Observation(self.active_epoch)]],
        )
        meter.create_observable_gauge(
            name="alert_avalanche_rate_per_minute",
            description="Tasa instantanea de notificaciones de alerta recibidas por minuto (Avalancha)",
            callbacks=[lambda options: [metrics.Observation(self.avalanche_rate_per_min)]],
        )
        meter.create_observable_gauge(
            name="alert_notifications_received_total",
            description="Total acumulado de notificaciones de alerta recibidas",
            callbacks=[lambda options: [metrics.Observation(self.total_notifications_count)]],
        )
        self.noise_filtered_counter = meter.create_counter(
            name="anomaly_detector_noise_filtered_total",
            description="Total de falsas alarmas ruidosas suprimidas",
            unit="1",
        )

    def set_epoch(self, epoch: int, window_sec: Optional[int] = None) -> None:
        """Cambia la epoca activa y limpia el buffer para aislar mediciones."""
        self.active_epoch = epoch
        if window_sec:
            self.window_seconds = window_sec
        self.samples.clear()
        self.current_error_z_score = 0.0
        self.current_latency_p99_ms = 0.0
        self.static_firing = 0
        self.correlated_firing = 0
        log.info(f"Epoca de evaluacion cambiada a: {epoch} (buffer reiniciado, ventana={self.window_seconds}s)")

    def _prune_old_samples(self, now: float) -> None:
        """Elimina muestras fuera de la ventana de tiempo."""
        cutoff = now - self.window_seconds
        while self.samples and self.samples[0].timestamp < cutoff:
            self.samples.popleft()

    def record_request(
        self,
        duration_ms: float,
        is_error: bool,
        status_code: int,
        trace_id: str = "",
        span_id: str = "",
        provider: str = "general",
        route: str = "/",
        error_message: Optional[str] = None,
    ) -> None:
        """Registra una peticion procesada REAL en la ventana deslizante."""
        now = time.time()
        self._prune_old_samples(now)
        sample = Sample(
            timestamp=now,
            duration_ms=duration_ms,
            is_error=is_error,
            status_code=status_code,
            trace_id=trace_id,
            span_id=span_id,
            provider=provider,
            route=route,
            error_message=error_message,
        )
        self.samples.append(sample)

    def calculate_metrics(self) -> Dict[str, Any]:
        """Calcula estadisticos descriptivos, percentil 99 y linea base actual."""
        now = time.time()
        self._prune_old_samples(now)

        if not self.samples:
            self.current_error_z_score = 0.0
            self.current_latency_p99_ms = 0.0
            return {
                "sample_count": 0,
                "error_rate": 0.0,
                "error_count": 0,
                "error_baseline_mean": 0.01,
                "error_baseline_std": 0.02,
                "error_z_score": 0.0,
                "latency_mean_ms": 0.0,
                "latency_std_ms": 0.0,
                "latency_p50_ms": 0.0,
                "latency_p95_ms": 0.0,
                "latency_p99_ms": 0.0,
                "latency_z_score": 0.0,
                "slo_threshold_ms": self.slo_latency_ms,
                "static_threshold_ms": STATIC_LATENCY_THRESHOLD_MS,
                "active_epoch": self.active_epoch,
            }

        n = len(self.samples)
        durations = sorted([s.duration_ms for s in self.samples])
        errors = [1.0 if s.is_error else 0.0 for s in self.samples]

        latency_mean = sum(durations) / n
        variance_lat = sum((x - latency_mean) ** 2 for x in durations) / n if n > 1 else 0.0
        latency_std = math.sqrt(variance_lat)

        def percentile(p: float) -> float:
            idx = int(math.ceil(p * n) - 1)
            return durations[max(0, min(idx, n - 1))]

        latency_p50 = percentile(0.50)
        latency_p95 = percentile(0.95)
        latency_p99 = percentile(0.99)

        error_count = sum(errors)
        error_rate = error_count / n

        error_baseline_mean = 0.01
        error_baseline_std = max(0.015, math.sqrt(error_baseline_mean * (1 - error_baseline_mean) / max(10, n)))
        error_z_score = (error_rate - error_baseline_mean) / error_baseline_std
        latency_z_score = (latency_p99 - latency_mean) / (latency_std + 0.001) if latency_std > 0 else 0.0

        self.current_error_z_score = round(error_z_score, 2)
        self.current_latency_p99_ms = round(latency_p99, 2)

        return {
            "sample_count": n,
            "error_rate": round(error_rate, 4),
            "error_count": int(error_count),
            "error_baseline_mean": round(error_baseline_mean, 4),
            "error_baseline_std": round(error_baseline_std, 4),
            "error_z_score": self.current_error_z_score,
            "latency_mean_ms": round(latency_mean, 2),
            "latency_std_ms": round(latency_std, 2),
            "latency_p50_ms": round(latency_p50, 2),
            "latency_p95_ms": round(latency_p95, 2),
            "latency_p99_ms": self.current_latency_p99_ms,
            "latency_z_score": round(latency_z_score, 2),
            "slo_threshold_ms": self.slo_latency_ms,
            "static_threshold_ms": STATIC_LATENCY_THRESHOLD_MS,
            "active_epoch": self.active_epoch,
        }

    async def _lookup_recent_failing_trace(self) -> tuple[str, str, str, str]:
        """Obtiene trace_id y span_id del error real mas reciente."""
        for sample in reversed(self.samples):
            if sample.is_error and sample.trace_id and sample.trace_id != "N/A":
                return sample.trace_id, sample.span_id, sample.route, sample.provider

        try:
            async with httpx.AsyncClient(timeout=2.0) as client:
                res = await client.get(
                    f"{JAEGER_API_URL}/api/traces",
                    params={"service": "data-service", "limit": 5, "lookback": "5m"},
                )
                if res.status_code == 200:
                    data = res.json()
                    traces = data.get("data", [])
                    if traces:
                        latest_trace = traces[0]
                        trace_id = latest_trace.get("traceID", "")
                        spans = latest_trace.get("spans", [])
                        span_id = spans[0].get("spanID", "") if spans else ""
                        return trace_id, span_id, "/records", "data-service"
        except Exception as e:
            log.warning(f"No se pudo consultar Jaeger API: {e}")

        return "N/A", "N/A", "/records", "data-service"

    async def evaluate(self) -> Dict[str, Any]:
        """Evalua las alertas estaticas y correlacionadas sobre el trafico real."""
        metrics_dict = self.calculate_metrics()

        # ── Evaluacion Estatica ─────────────────────────────────────────────
        static_error_fired = metrics_dict["error_rate"] > STATIC_ERROR_THRESHOLD
        static_latency_fired = metrics_dict["latency_p99_ms"] > STATIC_LATENCY_THRESHOLD_MS
        static_alert_fired = static_error_fired or static_latency_fired

        # ── Evaluacion Correlacionada ───────────────────────────────────────
        error_condition = metrics_dict["error_z_score"] >= 2.0 and metrics_dict["error_count"] >= 1
        latency_condition = metrics_dict["latency_p99_ms"] >= self.slo_latency_ms
        correlated_alert_fired = error_condition and latency_condition

        # Actualizar estado de disparo segun epoca
        if self.active_epoch == 1:
            self.stats["epoch_1_evaluations"] += 1
            self.static_firing = 1 if static_alert_fired else 0
            self.correlated_firing = 0
            if static_alert_fired:
                self.stats["epoch_1_static_alerts"] += 1
                self._dispatch_internal_notification(
                    alertname="StaticHighLatencyOrErrors",
                    severity="warning",
                    system_type="static_threshold",
                    status="FIRING",
                    summary=f"Alerta Estática: Latencia P99={metrics_dict['latency_p99_ms']}ms > 50ms o Error Rate={metrics_dict['error_rate']*100}% > 0%",
                    description="Disparada por umbral estático rígido sin correlación. Probable falso positivo.",
                )
        else:
            self.stats["epoch_2_evaluations"] += 1
            self.static_firing = 0
            self.correlated_firing = 1 if correlated_alert_fired else 0
            if static_alert_fired:
                self.stats["epoch_2_static_alerts"] += 1
            if correlated_alert_fired:
                self.stats["epoch_2_correlated_alerts"] += 1
            else:
                if static_alert_fired:
                    self.stats["epoch_2_noise_filtered"] += 1
                    self.noise_filtered_counter.add(1, {"epoch": "2"})

        enriched_alert_data = None
        if correlated_alert_fired and self.active_epoch == 2:
            trace_id, span_id, route, provider = await self._lookup_recent_failing_trace()
            jaeger_url = f"{JAEGER_PUBLIC_URL}/trace/{trace_id}" if trace_id != "N/A" else f"{JAEGER_PUBLIC_URL}"

            alert_obj = EnrichedAlert(
                alert_id=f"alert-{int(time.time()*1000)}",
                timestamp=datetime.now(timezone.utc).isoformat(),
                epoch=self.active_epoch,
                severity="CRITICAL",
                title="DataServiceCorrelatedIncident",
                rule_evaluated="error_rate > baseline + 2*sigma AND latency_p99 > SLO (200ms)",
                condition_description=(
                    f"Tasa de error anomalamente alta (Z={metrics_dict['error_z_score']}sigma >= 2.0sigma) "
                    f"y Latencia p99 degradada ({metrics_dict['latency_p99_ms']}ms >= {self.slo_latency_ms}ms)"
                ),
                metrics=metrics_dict,
                trace_id=trace_id,
                span_id=span_id,
                jaeger_url=jaeger_url,
                failing_route=route,
                provider=provider,
                root_cause_summary=(
                    f"Incidente coordinado en {provider}: latencia p99 {metrics_dict['latency_p99_ms']}ms "
                    f"con {metrics_dict['error_count']} fallos reales registrados en ventana activa."
                ),
            )
            self.alerts.append(alert_obj)
            enriched_alert_data = asdict(alert_obj)

            self._dispatch_internal_notification(
                alertname="CorrelatedMultiSignalIncident",
                severity="critical",
                system_type="correlated_anomaly",
                status="FIRING",
                summary=f"🚨 INCIDENTE CRÍTICO CORRELACIONADO: Error Z={metrics_dict['error_z_score']}σ Y Latencia P99={metrics_dict['latency_p99_ms']}ms",
                description=alert_obj.root_cause_summary,
                trace_id=trace_id,
                jaeger_url=jaeger_url,
            )

            log.critical(
                "ALERTA CORRELACIONADA DISPARADA [data-service]",
                extra={
                    "alert_id": alert_obj.alert_id,
                    "epoch": self.active_epoch,
                    "trace_id": trace_id,
                    "span_id": span_id,
                    "jaeger_url": jaeger_url,
                },
            )

        total_static_epoch2 = self.stats["epoch_2_static_alerts"]
        noise_filtered = self.stats["epoch_2_noise_filtered"]
        noise_reduction_pct = round((noise_filtered / max(1, total_static_epoch2)) * 100.0, 2) if total_static_epoch2 > 0 else 0.0

        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "active_epoch": self.active_epoch,
            "metrics": metrics_dict,
            "static_system": {
                "alert_fired": static_alert_fired,
                "reasons": {
                    "error_above_threshold": static_error_fired,
                    "latency_above_50ms": static_latency_fired,
                },
                "epoch_1_alerts": self.stats["epoch_1_static_alerts"],
                "epoch_2_alerts": self.stats["epoch_2_static_alerts"],
                "epoch_1_notifications": self.stats["epoch_1_notifications"],
            },
            "correlated_system": {
                "alert_fired": correlated_alert_fired,
                "conditions": {
                    "error_z_score_gt_2sigma": error_condition,
                    "latency_p99_gt_slo": latency_condition,
                },
                "epoch_2_alerts": self.stats["epoch_2_correlated_alerts"],
                "epoch_2_notifications": self.stats["epoch_2_notifications"],
                "enriched_alert": enriched_alert_data,
            },
            "noise_reduction": {
                "noise_alerts_filtered": noise_filtered,
                "noise_reduction_pct": noise_reduction_pct,
            },
            "notifications": {
                "total_received": self.total_notifications_count,
                "avalanche_rate_per_min": self.avalanche_rate_per_min,
            },
        }

    def _dispatch_internal_notification(
        self,
        alertname: str,
        severity: str,
        system_type: str,
        status: str,
        summary: str,
        description: str,
        trace_id: Optional[str] = None,
        jaeger_url: Optional[str] = None,
    ) -> None:
        """Registra una notificacion en la bandeja de entrada de Ops y actualiza la tasa de avalancha."""
        now = time.time()
        self.notification_timestamps.append(now)
        cutoff = now - 60.0
        while self.notification_timestamps and self.notification_timestamps[0] < cutoff:
            self.notification_timestamps.popleft()

        self.avalanche_rate_per_min = float(len(self.notification_timestamps))
        self.total_notifications_count += 1

        if self.active_epoch == 1:
            self.stats["epoch_1_notifications"] += 1
        else:
            self.stats["epoch_2_notifications"] += 1

        item = NotificationItem(
            id=f"notif-{int(now*1000)}",
            timestamp=datetime.now(timezone.utc).strftime("%H:%M:%S"),
            epoch=self.active_epoch,
            status=status,
            alertname=alertname,
            severity=severity,
            system_type=system_type,
            summary=summary,
            description=description,
            trace_id=trace_id,
            jaeger_url=jaeger_url,
        )
        self.notifications.append(item)

    def record_webhook_notification(self, payload: Dict[str, Any]) -> None:
        """Registra una notificacion entregada por webhook desde Prometheus Alertmanager / Grafana."""
        alerts = payload.get("alerts", [payload])
        for a in alerts:
            labels = a.get("labels", {})
            annotations = a.get("annotations", {})
            alertname = labels.get("alertname", "UnknownAlert")
            severity = labels.get("severity", "warning")
            status = a.get("status", "FIRING").upper()
            summary = annotations.get("summary", alertname)
            description = annotations.get("description", "")
            system_type = labels.get("system_type", "static_threshold")

            self._dispatch_internal_notification(
                alertname=alertname,
                severity=severity,
                system_type=system_type,
                status=status,
                summary=summary,
                description=description,
            )

    def get_notifications(self, limit: int = 50) -> List[Dict[str, Any]]:
        """Retorna las notificaciones mas recientes en la bandeja de Ops."""
        return [asdict(n) for n in reversed(list(self.notifications)[-limit:])]

    def get_alerts(self, limit: int = 20) -> List[Dict[str, Any]]:
        """Retorna las ultimas alertas enriquecidas."""
        return [asdict(a) for a in reversed(self.alerts[-limit:])]

    def reset(self) -> None:
        """Reinicia buffer y contadores para nuevas pruebas limpias."""
        self.samples.clear()
        self.alerts.clear()
        self.notifications.clear()
        self.notification_timestamps.clear()
        self.current_error_z_score = 0.0
        self.current_latency_p99_ms = 0.0
        self.static_firing = 0
        self.correlated_firing = 0
        self.total_notifications_count = 0
        self.avalanche_rate_per_min = 0.0
        self.stats = {
            "epoch_1_evaluations": 0,
            "epoch_1_static_alerts": 0,
            "epoch_1_notifications": 0,
            "epoch_2_evaluations": 0,
            "epoch_2_static_alerts": 0,
            "epoch_2_correlated_alerts": 0,
            "epoch_2_notifications": 0,
            "epoch_2_noise_filtered": 0,
        }


# Instancia singleton global para data-service
detector = AnomalyDetector()
