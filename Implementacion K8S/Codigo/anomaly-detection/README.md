# Detección de anomalías — Isolation Forest y SVM RBF

Práctico de AIOps: implementación de **Isolation Forest** y **Support Vector
Machine con función núcleo RBF** sobre el dataset provisto por los docentes.

## Evidencia principal

[`anomaly-detection-notebook.ipynb`](anomaly-detection-notebook.ipynb)
— la notebook docente resuelta y ejecutada de punta a punta (semilla 42, outputs
conservados). La estructura original del docente se conserva: los `TODO` de las
secciones 4–7 quedaron resueltos y la sección 9 mantiene las preguntas de cierre.

- **Sección 6 — IsolationForest**: sobre las ventanas del dataset, score
  `-decision_function` y contamination como política de alertas.
- **Sección 7 — SVM con kernel RBF**: `OneClassSVM(kernel="rbf", gamma="scale")`,
  entrenado solo con datos normales (los anómalos se reservan para evaluar).
- **Secciones 1–5**: dataset del práctico y detectores univariados de
  referencia (k-sigma y MAD).
- **Sección 8**: comparación de detectores y gráficos.
- **Sección 9**: preguntas de cierre.

Resultado sobre las 300 ventanas del dataset (53 anomalías, 17,7 %):

| Detector | Precision | Recall | F1 | Alertas |
|---|---:|---:|---:|---:|
| k-sigma error | 1.000 | 0.189 | 0.317 | 10 |
| k-sigma latencia | 1.000 | 0.151 | 0.262 | 8 |
| MAD error | 0.944 | 0.321 | 0.479 | 18 |
| MAD latencia | 1.000 | 0.679 | 0.809 | 36 |
| **Isolation Forest** | 0.800 | 0.453 | 0.578 | 30 |
| **One-Class SVM RBF** | 0.621 | 0.340 | 0.439 | 29 |

## Ejecutar la notebook

Con Docker, desde la raíz del repositorio:

```bash
docker run --rm -v "${PWD}:/app" \
  -w "/app/Implementacion K8S/Codigo/anomaly-detection" \
  python:3.11-slim bash -lc \
  "pip install --no-cache-dir -r requirements-notebook.txt && \
   jupyter nbconvert --to notebook --execute --inplace \
   anomaly-detection-notebook.ipynb"
```

También se puede abrir en Jupyter o VS Code: la notebook quedó ejecutada con
semilla 42 y outputs guardados.

## Referencias

- Liu, Ting, Zhou. *Isolation Forest*. ICDM 2008.
- scikit-learn: `sklearn.ensemble.IsolationForest`,
  `sklearn.svm.OneClassSVM` (`kernel="rbf"`).
