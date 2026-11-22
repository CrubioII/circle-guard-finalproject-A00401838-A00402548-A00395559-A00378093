# Costos: estimación frente a costo real (US-48 CA2)

Cuenta AWS del proyecto tras la migración del 21 de noviembre de 2026, Región `us-east-2`.

Datos consultados el 21 de noviembre de 2026 con la API de AWS (Price List, Cost Explorer y EC2).

## Recursos que generan costo hoy

| Recurso | Cantidad | Detalle |
| :--- | :---: | :--- |
| EC2 `m7i-flex.large` (2 vCPU, 8 GB) | 4 | `circleguard-ci-server`, `circleguard-env-dev`, `circleguard-env-stage`, `circleguard-env-prod` |
| EBS `gp3` | 90 GB | 30 GB en CI y 20 GB en cada ambiente |
| IPv4 pública | 4 | Una por instancia, no elásticas |

## Estimación mensual (precios de lista, 730 horas)

| Concepto | Precio unitario | Cálculo | USD/mes |
| :--- | :--- | :--- | ---: |
| EC2 `m7i-flex.large` Linux bajo demanda | 0.09576 USD/hora (Price List API) | 4 × 0.09576 × 730 | 279.62 |
| EBS `gp3` | 0.08 USD/GB-mes | 90 × 0.08 | 7.20 |
| IPv4 pública | 0.005 USD/hora | 4 × 0.005 × 730 | 14.60 |
| Total | | | 301.42 |

Equivale a unos 9.90 USD por día con las cuatro instancias encendidas. La misma cuenta puede contrastarse en AWS Pricing Calculator con esos tres conceptos.

## Costo real

| Periodo | Fuente | Costo |
| :--- | :--- | ---: |
| 1 al 21 de noviembre de 2026 | Cost Explorer, `UnblendedCost` por servicio | 0.00 USD (estimado) |

La cuenta nueva empezó a usarse el 21 de noviembre, así que Cost Explorer todavía no refleja el consumo: los datos llegan con hasta 24 horas de retraso. Este valor se actualiza antes de la entrega con la consola de Billing and Cost Management.
