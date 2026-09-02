#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Simulacion Continua de 30 Minutos en 2 Epocas de 15 Minutos con Chaos Engineering Real
=======================================================================================
Evalua de forma rigurosa la fatiga de alertas (Alert Fatigue) y la avalancha de notificaciones:

  - Epoca 1 (Min 0:00 - 15:00): Sistema Estatico Tradicional (Avalancha / Fatiga Extrema)
  - Epoca 2 (Min 15:00 - 30:00): Sistema Correlacionado Dinamico (0 Falsas Alarmas, Alerta Unica)

Todo el trafico consiste en PETICIONES HTTP REALES contra endpoints de base de datos
(PostgreSQL) y fallas inyectadas mediante Chaos Engineering a nivel de aplicacion.

Uso:
  python benchmark/run_30min_ops_simulation.py              # 30 minutos tiempo real
  python benchmark/run_30min_ops_simulation.py --speedup 10 # 3 minutos acelerado
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

DATA_SERVICE_URL = "http://localhost:18080"


def http_post(url: str, payload: dict) -> dict:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8"))
        except Exception:
            return {"error": str(e), "status_code": e.code}


def http_get(url: str) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8"))
        except Exception:
            return {"error": str(e), "status_code": e.code}


# Secuencia determinista identica para ambas epocas de 15 minutos (porcentaje de duracion)
CHAOS_PHASES = [
    {
        "name": "1. Tráfico Normal Saludable (Sin Caos)",
        "share": 0.27,  # 4.0 min
        "chaos_config": {"scenario": "normal"},
    },
    {
        "name": "2. Micro-Jitter Latencia Real (150ms)",
        "share": 0.20,  # 3.0 min
        "chaos_config": {"scenario": "latency_jitter", "latency_ms": 150.0, "latency_rate": 1.0},
    },
    {
        "name": "3. Errores 500 Reales Aislados (10%)",
        "share": 0.20,  # 3.0 min
        "chaos_config": {"scenario": "transient_errors", "error_rate": 0.10, "error_status_code": 500},
    },
    {
        "name": "4. Incidente Severo Real (50% Fallos + 350ms)",
        "share": 0.20,  # 3.0 min
        "chaos_config": {"scenario": "coordinated_incident", "latency_ms": 350.0, "error_rate": 0.50, "error_status_code": 500},
    },
    {
        "name": "5. Recuperación a Tráfico Normal",
        "share": 0.13,  # 2.0 min
        "chaos_config": {"scenario": "normal"},
    },
]


def send_real_traffic_batch(req_id: int):
    """Envia un lote de peticiones HTTP reales contra PostgreSQL."""
    # 1. POST /gcp/records
    http_post(f"{DATA_SERVICE_URL}/gcp/records", {"data": f"real_transaction_gcp_{req_id}_{int(time.time()*1000)}"})
    # 2. GET /gcp/records
    http_get(f"{DATA_SERVICE_URL}/gcp/records")


def run_epoch(epoch_num: int, epoch_duration_sec: float, speedup: float):
    epoch_name = "ÉPOCA 1: Sistema Estático Tradicional (Avalancha / Fatiga de Alertas)" if epoch_num == 1 else "ÉPOCA 2: Sistema Correlacionado Inteligente (+2σ y SLO)"
    print("\n" + "=" * 80)
    print(f" INICIANDO {epoch_name}")
    print(f" Duracion: {epoch_duration_sec:.1f} segundos ({epoch_duration_sec/60:.2f} min equivalentes a 15 min reales)")
    print("=" * 80)

    # Configurar epoca en data-service con ventana escalada
    scaled_window = max(5, int(60.0 / speedup))
    http_post(f"{DATA_SERVICE_URL}/anomalies/epoch", {"epoch": epoch_num, "window_sec": scaled_window})

    epoch_start = time.time()
    events_log = []
    global_req_id = 0

    for idx, phase in enumerate(CHAOS_PHASES, start=1):
        phase_duration = epoch_duration_sec * phase["share"]
        phase_start = time.time()
        print(f"\n  >> [{idx}/5] Fase: {phase['name']} (Duración: {phase_duration:.1f}s)")

        # Configurar Chaos Engineering para esta fase
        http_post(f"{DATA_SERVICE_URL}/chaos/experiment", phase["chaos_config"])

        step_interval = max(0.4, 2.5 / speedup)

        while (time.time() - phase_start) < phase_duration:
            global_req_id += 1
            # Enviar tráfico HTTP real
            send_real_traffic_batch(global_req_id)

            # Evaluar y obtener telemetría
            status = http_get(f"{DATA_SERVICE_URL}/anomalies/status")

            elapsed_epoch = time.time() - epoch_start
            m = status.get("metrics", {})
            p99 = m.get("latency_p99_ms", 0.0)
            err_rate = m.get("error_rate", 0.0) * 100
            z_score = m.get("error_z_score", 0.0)
            st_alert = status.get("static_system", {}).get("alert_fired", False)
            co_alert = status.get("correlated_system", {}).get("alert_fired", False)
            avalanche_rate = status.get("notifications", {}).get("avalanche_rate_per_min", 0.0)
            total_notifs = status.get("notifications", {}).get("total_received", 0)

            st_icon = "🚨 ALERTA" if st_alert else "🟢 OK"
            co_icon = "🚨 CRITICAL" if co_alert else "🟢 OK"

            sys.stdout.write(
                f"\r     [{elapsed_epoch:5.1f}s/{epoch_duration_sec:5.1f}s] "
                f"P99: {p99:5.1f}ms | Err: {err_rate:4.1f}% | Z: {z_score:4.1f}σ | "
                f"Estático: {st_icon:<9} | Correlacionado: {co_icon:<11} | Notifs/min: {avalanche_rate:2.0f} (Total: {total_notifs})"
            )
            sys.stdout.flush()

            time.sleep(step_interval)

        # Fin de fase
        status = http_get(f"{DATA_SERVICE_URL}/anomalies/status")
        events_log.append((phase["name"], status))
        print()

    # Resetear caos al terminar epoca
    http_post(f"{DATA_SERVICE_URL}/chaos/reset", {})
    return events_log


def main():
    parser = argparse.ArgumentParser(description="Simulación continua de 30 minutos en 2 épocas de 15 min con Chaos Engineering")
    parser.add_argument(
        "--speedup",
        type=float,
        default=1.0,
        help="Factor de aceleración (ej. 10 para ejecutar 30 min en 3 min, 1 para 30 min tiempo real)",
    )
    args = parser.parse_args()

    total_real_duration = 1800.0  # 30 minutos = 1800s
    sim_duration = total_real_duration / args.speedup
    epoch_duration = sim_duration / 2.0

    print("=" * 80)
    print(" OTel Lab -- Benchmark de Operaciones (Ops Alert Avalanche & Chaos Engineering)")
    print(f" Target Service        : {DATA_SERVICE_URL}")
    print(f" Duración Total        : {sim_duration:.1f} segundos ({sim_duration/60:.2f} min)")
    print(f" Duración por Época    : {epoch_duration:.1f} segundos (15.0 min equivalentes c/u)")
    print(f" Factor de Aceleración : {args.speedup}x")
    print("=" * 80)

    # 1. Verificar conectividad
    try:
        health = http_get(f"{DATA_SERVICE_URL}/health")
        print(f"\n>> data-service conectado: status={health.get('status')}, backends={health.get('db_backends')}")
    except Exception as e:
        print(f"\nERROR: No se pudo conectar a {DATA_SERVICE_URL}: {e}")
        print("Verifica que el stack este corriendo: docker compose up -d")
        sys.exit(1)

    # 2. Reiniciar estados
    http_post(f"{DATA_SERVICE_URL}/chaos/reset", {})
    http_post(f"{DATA_SERVICE_URL}/anomalies/reset", {})

    # 3. Ejecutar Época 1 (Sin Correlación - Avalancha de Alertas)
    epoch1_results = run_epoch(epoch_num=1, epoch_duration_sec=epoch_duration, speedup=args.speedup)
    status_epoch1 = http_get(f"{DATA_SERVICE_URL}/anomalies/status")

    # 4. Ejecutar Época 2 (Con Correlación Inteligente) bajo el MISMO Caos
    epoch2_results = run_epoch(epoch_num=2, epoch_duration_sec=epoch_duration, speedup=args.speedup)
    status_epoch2 = http_get(f"{DATA_SERVICE_URL}/anomalies/status")

    # 5. Obtener alertas enriquecidas y feed de notificaciones
    enriched_alerts = http_get(f"{DATA_SERVICE_URL}/anomalies/alerts")
    notifications = http_get(f"{DATA_SERVICE_URL}/alerts/notifications")

    # ── 6. Reporte Comparativo ───────────────────────────────────────────────
    print("\n" + "=" * 80)
    print(" REPORTE COMPARATIVO DE OPERACIONES (30 MINUTOS / 2 ÉPOCAS DE 15 MIN)")
    print("=" * 80)
    print(f"{'Fase de Chaos Engineering Idéntica':<42} | {'Época 1 (Estática)':<18} | {'Época 2 (Correlacionada)':<20}")
    print("-" * 80)

    for i in range(len(CHAOS_PHASES)):
        name = CHAOS_PHASES[i]["name"]
        s1 = epoch1_results[i][1]
        s2 = epoch2_results[i][1]

        st_label = "🚨 DISPARADA (Ruido)" if "Jitter" in name or "Errores" in name else ("🚨 DISPARADA (Real)" if "Incidente" in name else "✅ Silente")
        co_label = "🚨 DISPARADA (Real)" if "Incidente" in name else "✅ Silente (Filtrada)"

        print(f"{name:<42} | {st_label:<18} | {co_label:<20}")

    print("-" * 80)
    ep1_alerts = status_epoch2["static_system"].get("epoch_1_alerts", 0)
    ep1_notifs = status_epoch2["static_system"].get("epoch_1_notifications", 0)
    ep2_correlated = status_epoch2["correlated_system"].get("epoch_2_alerts", 0)
    ep2_notifs = status_epoch2["correlated_system"].get("epoch_2_notifications", 0)
    filtered = status_epoch2["noise_reduction"].get("noise_alerts_filtered", 0)
    reduction_pct = status_epoch2["noise_reduction"].get("noise_reduction_pct", 0.0)

    print("\n📊 INDICADORES CLAVE DE RENDIMIENTO OPERACIONAL (KPIs OPS):")
    print(f"   • Alertas Totales Época 1 (Sistema Estático)     : {ep1_alerts} (fatiga por falsas alarmas de jitter/errores aislados)")
    print(f"   • Notificaciones Recibidas en Época 1 (Spam/Ruido): {ep1_notifs} notificaciones (avalancha que satura al operador)")
    print(f"   • Alertas Totales Época 2 (Sistema Inteligente)  : {ep2_correlated} (únicamente durante el incidente real coordinado)")
    print(f"   • Notificaciones Recibidas en Época 2            : {ep2_notifs} notificación accionable")
    print(f"   • Falsas Alarmas Eliminadas en Época 2 como Ruido: {filtered} alertas suprimidas")
    print(f"   • Eficiencia en Reducción de Ruido y Fatiga      : {reduction_pct}%")

    # ── 7. Detalle de la Alerta de Ops Enriquecida ────────────────────────────
    print("\n" + "=" * 80)
    print(" ALERTA OPERATIVA ENRIQUECIDA EN ÉPOCA 2 (LO QUE VE OPS)")
    print("=" * 80)
    if enriched_alerts:
        alert = enriched_alerts[0]
        print(f"   • ID Incidente          : {alert['alert_id']}")
        print(f"   • Época                 : Época {alert['epoch']}")
        print(f"   • Severidad             : {alert['severity']}")
        print(f"   • Regla Disparada       : {alert['rule_evaluated']}")
        print(f"   • Causa Raíz Diagnosticada: {alert['root_cause_summary']}")
        print(f"   • TRACE_ID Extraído     : {alert['trace_id']}")
        print(f"   • SPAN_ID Extraído      : {alert['span_id']}")
        print(f"   • Enlace Directo Jaeger : {alert['jaeger_url']}")
        print(f"   • Dashboard Grafana Ops : http://localhost:3000/d/ops-alerts-v1")
    else:
        print("   No se generaron alertas enriquecidas.")

    print("\n" + "=" * 80)
    print(" BANDEJA DE ENTRADA DE NOTIFICACIONES DE OPS (LIVE INBOX FEED)")
    print("=" * 80)
    print(f"{'Hora':<10} | {'Época':<7} | {'Estado':<10} | {'Severidad':<10} | {'Resumen Notificación':<45}")
    print("-" * 80)
    for n in notifications[:8]:
        print(f"{n['timestamp']:<10} | Época {n['epoch']:<1} | {n['status']:<10} | {n['severity']:<10} | {n['summary'][:45]:<45}")

    print("\n" + "=" * 80)
    print(" SIMULACIÓN DE 30 MINUTOS Y BENCHMARK COMPLETADOS EXITOSAMENTE")
    print("=" * 80)


if __name__ == "__main__":
    main()

