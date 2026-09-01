# Herramientas fijadas para el sandbox local

| Herramienta | Versión | Motivo |
|---|---:|---|
| kind | 0.31.0 | Versión estable documentada para crear el clúster local |
| Istio | 1.30.3 | Compatible con Kubernetes 1.32–1.36 y con correcciones de julio de 2026 |
| Helm | 3.21.4 | Compatible con los charts Helm 3 existentes del repositorio |
| k6 | 1.7.1 | Generación de carga portable en Windows |

Los binarios se descargan en `.tools/`, ruta excluida de Git. Antes de GCP se
debe confirmar compatibilidad entre la versión real de GKE y la versión de
Istio. No actualizar versiones durante una corrida de evidencia.
