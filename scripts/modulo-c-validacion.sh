#!/usr/bin/env bash
# =============================================================================
# Modulo C — Escenario de validacion de la observabilidad de red y seguridad
# =============================================================================
# Inyecta comportamientos anomalos controlados y mide cuanto tarda cada uno en
# ser VISIBLE en Cloud Logging, que es el primer sumando del MTTD:
#
#     MTTD = t_visible_en_logs + t_agregacion_metrica + t_evaluacion_alerta
#
# Este script mide el primero con precision. Los otros dos son deterministas:
#   - agregacion de la metrica basada en logs: hasta 60 s
#   - periodo de alineacion de la alert policy: 60 s (SEC-2) / 300 s (resto)
#
# QUE MODIFICA: nada permanente. Crea un unico pod temporal 'modulo-c-probe'
# en el namespace 'services' y lo borra con --limpiar. No toca despliegues,
# servicios, configuracion ni datos existentes.
#
# Uso:
#     ./scripts/modulo-c-validacion.sh <PROJECT_ID> [ENVIRONMENT] [REGION]
#     ./scripts/modulo-c-validacion.sh <PROJECT_ID> --limpiar
#
# Valores verificados en el proyecto 'observabilidad' (2026-09-01):
#     PROJECT_ID   project-546ee9f1-20e7-4368-919
#     ENVIRONMENT  dev          (cluster dev-otel-cluster, subred dev-gke-subnet)
#     REGION       us-central1
#
# Requisitos: gcloud autenticado y kubectl apuntando a dev-otel-cluster.
# =============================================================================
set -uo pipefail

PROJECT_ID="${1:-}"
if [[ -z "$PROJECT_ID" ]]; then
  echo "Uso: $0 <PROJECT_ID> [ENVIRONMENT] [REGION] | $0 <PROJECT_ID> --limpiar" >&2
  exit 1
fi

LIMPIAR="no"
for arg in "$@"; do [[ "$arg" == "--limpiar" ]] && LIMPIAR="si"; done

ENVIRONMENT="dev"
REGION="us-central1"
[[ "${2:-}" != "" && "${2:-}" != "--limpiar" ]] && ENVIRONMENT="$2"
[[ "${3:-}" != "" && "${3:-}" != "--limpiar" ]] && REGION="$3"

SUBRED="${ENVIRONMENT}-gke-subnet"
NS="services"
POD="modulo-c-probe"
TIMEOUT_ESPERA=420 # 7 min: margen holgado sobre el objetivo de MTTD de 2 min

# ── Destinos reales, verificados contra los charts y contra el cluster ───────
# Los tres servicios NO escuchan en el mismo puerto, y data-service NO esta en
# un namespace propio: vive en 'services' con el nombre que le da el fullname
# de Helm ({{ .Release.Name }}-{{ .Chart.Name }}) -> data-service-data-service.
SVC_DATA="data-service-data-service.${NS}.svc.cluster.local"
SVC_B="service-b.${NS}.svc.cluster.local"

# ── Por que el escenario B apunta a IPs DE POD y no a nombres de Service ─────
# Esto se corrigio el 2026-09-01 despues de ver fallar el escenario contra el
# cluster real. La version anterior hacia 'nc' contra el nombre DNS del
# Service, que resuelve a una ClusterIP. Una conexion a una ClusterIP en un
# puerto sin backend SI genera un flow log, pero SIN 'dest_gke_details': no
# hay ningun pod detras de esa IP:puerto que GKE pueda anotar. La metrica
# security/flow_unexpected_pair exige dest_gke_details.pod.pod_namespace, asi
# que el escenario no podia producir la senal que decia probar — daba un falso
# NEGATIVO silencioso, que en una prueba de deteccion es peor que no probar.
#
# Contra la IP del pod el registro si trae dest_gke_details. Verificado.
#
# Ademas la conexion debe CRUZAR de nodo: sin visibilidad intranodo
# (PARCHE-modulo-a.md seccion 4, desactivada) el trafico entre dos pods del
# mismo nodo no aparece en los flow logs. Por eso se elige un pod destino que
# no este en el mismo nodo que la sonda.

azul()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
verde() { printf '\033[1;32m%s\033[0m\n' "$*"; }
rojo()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
gris()  { printf '\033[0;90m%s\033[0m\n' "$*"; }

if [[ "$LIMPIAR" == "si" ]]; then
  azul "Eliminando el pod de sondeo..."
  kubectl delete pod "$POD" -n "$NS" --ignore-not-found
  exit 0
fi

# -----------------------------------------------------------------------------
# 0. Requisito duro: VPC Flow Logs
# -----------------------------------------------------------------------------
# Sin flow logs el modulo se aplica sin errores pero todos los paneles de
# trafico quedan vacios, y nada lo explica. Aqui eso se convierte en un error
# explicito antes de gastar tiempo generando trafico.
# ── Comprobacion de credenciales, ANTES de nada ──────────────────────────────
# Aprendido a golpes el 2026-09-01: la sesion de Cloud Shell puede perder la
# cuenta activa a mitad de trabajo. Cuando eso pasa, cada 'gcloud logging read'
# de este script devuelve un error de autenticacion que el '2>/dev/null' de
# esperar_log() se traga, y el script informa "NO aparecio en 420s" — es decir,
# reporta un FALLO DE DETECCION cuando lo que hay es un fallo de credenciales.
# En una prueba de seguridad esa confusion es inaceptable: se comprueba aqui.
if ! gcloud auth print-access-token >/dev/null 2>&1; then
  rojo "gcloud no tiene una cuenta activa; el script no puede leer los logs."
  echo
  gris "Sin esto, cada espera de este script fallaria por credenciales y se"
  gris "reportaria como un fallo de deteccion. Arreglalo con:"
  echo
  echo "  gcloud config set account TU_CUENTA"
  echo "  gcloud config set project ${PROJECT_ID}"
  echo
  exit 1
fi

azul "== 0. Comprobando VPC Flow Logs en $SUBRED =="

FLOW_LOGS="$(gcloud compute networks subnets describe "$SUBRED" \
  --project "$PROJECT_ID" --region "$REGION" \
  --format="value(enableFlowLogs)" 2>/dev/null)"

if [[ "$FLOW_LOGS" != "True" ]]; then
  rojo "VPC Flow Logs NO esta habilitado en $SUBRED."
  echo
  gris "Sin ellos no habra datos de trafico N-S/E-W ni alertas SEC-2/3/5."
  gris "Habilitalos con:"
  echo
  cat <<EOF
  gcloud compute networks subnets update ${SUBRED} \\
    --region=${REGION} --project=${PROJECT_ID} \\
    --enable-flow-logs \\
    --logging-aggregation-interval=interval-30-sec \\
    --logging-flow-sampling=1.0 \\
    --logging-metadata=include-all
EOF
  echo
  gris "Detalle y alternativa declarativa:"
  gris "  infrastructure/gcp-modulo-c/PARCHE-modulo-a.md"
  exit 1
fi

CONFIG="$(gcloud compute networks subnets describe "$SUBRED" \
  --project "$PROJECT_ID" --region "$REGION" \
  --format="value(logConfig.aggregationInterval,logConfig.flowSampling,logConfig.metadata)" 2>/dev/null)"
verde "OK — flow logs activos. Config: $CONFIG"
echo

# ── Estado del mesh: determina que escenarios tienen sentido ─────────────────
ISTIO="no"
kubectl get namespace istio-system >/dev/null 2>&1 && ISTIO="si"
gris "Istio instalado: $ISTIO"
if [[ "$ISTIO" == "no" ]]; then
  gris "El escenario A (403 RBAC del mesh) se omite: sin Istio no hay"
  gris "AuthorizationPolicy que rechazar. La senal de autenticacion fallida"
  gris "se valida igualmente en el escenario D, sobre Cloud Audit Logs."
fi
echo

# -----------------------------------------------------------------------------
# Utilidad: espera a que aparezca una entrada de log y mide el retardo
# -----------------------------------------------------------------------------
esperar_log() {
  local etiqueta="$1" filtro="$2" t0="$3"
  local inicio_rfc
  inicio_rfc="$(date -u -d "@$t0" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$t0" +%Y-%m-%dT%H:%M:%SZ)"

  local fin=$((t0 + TIMEOUT_ESPERA))
  while (( $(date +%s) < fin )); do
    if [[ -n "$(gcloud logging read "${filtro} AND timestamp>=\"${inicio_rfc}\"" \
                 --project "$PROJECT_ID" --limit 1 --format="value(timestamp)" 2>/dev/null)" ]]; then
      verde "  [$etiqueta] visible en Cloud Logging tras $(( $(date +%s) - t0 ))s"
      return 0
    fi
    sleep 10
  done

  rojo "  [$etiqueta] NO aparecio en ${TIMEOUT_ESPERA}s"
  return 1
}

# -----------------------------------------------------------------------------
# 1. Pod de sondeo
# -----------------------------------------------------------------------------
azul "== 1. Desplegando pod de sondeo en el namespace '$NS' =="
kubectl delete pod "$POD" -n "$NS" --ignore-not-found >/dev/null 2>&1
kubectl run "$POD" -n "$NS" --image=nicolaka/netshoot \
  --restart=Never --command -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready "pod/$POD" -n "$NS" --timeout=180s >/dev/null || {
  rojo "El pod de sondeo no arranco."
  exit 1
}
verde "Pod listo."
echo

ejec() { kubectl exec -n "$NS" "$POD" -c "$POD" -- sh -c "$1" 2>/dev/null; }

# -----------------------------------------------------------------------------
# 2. Escenario A — movimiento lateral rechazado por el mesh (solo con Istio)
# -----------------------------------------------------------------------------
if [[ "$ISTIO" == "si" ]]; then
  azul "== 2. Escenario A: movimiento lateral (esperado 403 RBAC_ACCESS_DENIED) =="
  T0=$(date +%s)
  for _ in $(seq 1 15); do
    ejec "curl -s -o /dev/null --max-time 3 http://${SVC_DATA}:8080/records" || true
  done
  gris "Senal esperada: security/failed_auth_workload -> alerta SEC-1."
  esperar_log "SEC-1 mesh 403" \
    'resource.type="k8s_container" AND jsonPayload.response_code=403' "$T0"
  echo
else
  azul "== 2. Escenario A: omitido (no hay Istio en el cluster) =="
  echo
fi

# -----------------------------------------------------------------------------
# 3. Escenario B — flujo E-W hacia un puerto fuera de la matriz autorizada
# -----------------------------------------------------------------------------
azul "== 3. Escenario B: conexion E-W a un puerto no autorizado =="
gris "Puertos 9999/6379/27017: ninguno esta en var.ew_allowed_ports."

# Nodo de la sonda, para elegir un destino que este en OTRO nodo.
NODO_SONDA="$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}')"

# Primer pod de la aplicacion que no comparta nodo con la sonda.
IP_DESTINO=""
POD_DESTINO=""
while read -r nombre ip nodo; do
  [[ "$nombre" == "$POD" ]] && continue
  [[ -z "$ip" || "$ip" == "<none>" ]] && continue
  if [[ "$nodo" != "$NODO_SONDA" ]]; then
    IP_DESTINO="$ip"; POD_DESTINO="$nombre"; break
  fi
done < <(kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{" "}{.spec.nodeName}{"\n"}{end}')

if [[ -z "$IP_DESTINO" ]]; then
  rojo "No hay ningun pod de '$NS' en un nodo distinto al de la sonda."
  gris "Sin visibilidad intranodo, el trafico dentro de un mismo nodo no"
  gris "aparece en los flow logs, asi que el escenario no puede validarse."
  gris "Ver infrastructure/gcp-modulo-c/PARCHE-modulo-a.md seccion 4."
else
  gris "Destino: $POD_DESTINO ($IP_DESTINO), nodo distinto al de la sonda."
  T0=$(date +%s)

  for _ in 1 2 3 4 5 6 7 8; do
    for puerto in 9999 6379 27017; do
      ejec "nc -z -w2 ${IP_DESTINO} $puerto" || true
    done
  done

  gris "Senal esperada: security/flow_unexpected_pair -> alerta SEC-2."
  # El filtro NO restringe 'reporter': una conexion rechazada (puerto cerrado)
  # se registra con reporter=DEST y no genera registro del lado SRC.
  esperar_log "SEC-2 flujo E-W inesperado" \
    'log_id("compute.googleapis.com/vpc_flows") AND jsonPayload.connection.dest_port=9999 AND jsonPayload.dest_gke_details.pod.pod_namespace="'"$NS"'"' "$T0"
fi
echo

# -----------------------------------------------------------------------------
# 4. Escenario C — egress hacia puertos de command-and-control
# -----------------------------------------------------------------------------
azul "== 4. Escenario C: egress hacia puertos asociados a C2 =="
T0=$(date +%s)

for _ in $(seq 1 15); do
  ejec "nc -z -w2 1.1.1.1 4444" || true
  ejec "nc -z -w2 8.8.8.8 6667" || true
done

gris "Senal esperada: security/firewall_denied (regla ${ENVIRONMENT}-deny-suspicious-egress) -> SEC-4."
esperar_log "SEC-4 firewall DENIED" \
  'log_id("compute.googleapis.com/firewall") AND jsonPayload.disposition="DENIED"' "$T0"
echo

# -----------------------------------------------------------------------------
# 5. Escenario D — acceso no autorizado al plano de control
# -----------------------------------------------------------------------------
azul "== 5. Escenario D: intento de leer el secreto de la base de datos =="
gris "El pod pide un token al metadata server y llama a Secret Manager."
gris "La SA de los nodos no tiene roles/secretmanager.secretAccessor:"
gris "el resultado esperado es PERMISSION_DENIED en Cloud Audit Logs."
T0=$(date +%s)

ejec "TOKEN=\$(curl -s -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' \
  | sed -n 's/.*\"access_token\":\"\\([^\"]*\\)\".*/\\1/p'); \
  for i in 1 2 3 4 5 6 7 8; do \
    curl -s -o /dev/null -H \"Authorization: Bearer \$TOKEN\" \
    'https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${ENVIRONMENT}-otel-db-url/versions/latest:access'; \
  done"

gris "Senal esperada: security/failed_auth_control_plane -> alerta SEC-1."
esperar_log "SEC-1 plano de control" \
  '(log_id("cloudaudit.googleapis.com/data_access") OR log_id("cloudaudit.googleapis.com/activity")) AND protoPayload.status.code=7' "$T0"
echo

# -----------------------------------------------------------------------------
# 6. Resumen
# -----------------------------------------------------------------------------
azul "== 6. Verificacion de las alertas =="
cat <<EOF

Los tiempos de arriba son el PRIMER sumando del MTTD (visibilidad en logs).
Para cerrar la medicion, revisa los incidentes abiertos:

  https://console.cloud.google.com/monitoring/alerting/incidents?project=${PROJECT_ID}

y el dashboard:

  https://console.cloud.google.com/monitoring/dashboards?project=${PROJECT_ID}

Alertas que deberian haber abierto incidente:
  [SEC-2] Trafico E-W hacia un puerto no autorizado    (escenario B)
  [SEC-4] Conexiones denegadas por el firewall         (escenario C)
  [SEC-1] Rafaga de autenticacion/autorizacion fallida (escenario D)

Limpieza:
  $0 ${PROJECT_ID} --limpiar

EOF
verde "Escenario de validacion completado."
