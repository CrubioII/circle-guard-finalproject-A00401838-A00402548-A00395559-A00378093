# Marco Ágil y Configuración del Product Backlog (`US-01` / `SCRUM-13`)

> **Proyecto:** CircleGuard — Plataforma de Gestión de Salud y Control de Acceso Perimetral  
> **Asignatura:** Ingeniería de Software V — Universidad Icesi (2026-B)  
> **Equipo:** SuperPoderosos (Grupo 5)  
> **Workspace Jira:** `circleguard777` (`https://circleguard777.atlassian.net`)  
> **Proyecto Jira:** `SuperPoderosos`  
> **Épica Asociada:** `EPIC-01` (`SCRUM-5`) — Gestión Ágil, Backlog y Estrategia de Branching (`E1.1`)  
> **Historia de Usuario:** `US-01` (`SCRUM-13`) — Configuración del marco ágil y poblado del Product Backlog en Jira (`3 SP`)  

---

## 1. Justificación y Selección del Marco Ágil

Para el desarrollo del monorepo de microservicios y la plataforma DevOps de **CircleGuard**, el equipo evaluó los marcos de trabajo ágiles predominantes en la industria: **Scrum**, **Kanban** y un modelo híbrido **Scrumban**.

### 1.1 Evaluación Comparativa

| Dimensión | Scrum Puro | Kanban Puro | Scrum Adaptado con GitHub Flow (Seleccionado) |
| :--- | :--- | :--- | :--- |
| **Cadencia de Entrega** | Fija por iteraciones (Sprints de 1-2 semanas). | Continua basada en flujo y límites WIP. | **Iteraciones fijas con Entrega Continua automatizada en `main`**. |
| **Ceremonias** | Planning, Daily, Review, Retrospective obligatorias. | Reuniones a demanda o basadas en cadencias de servicio. | **Ceremonias estructuradas para control de hitos y dailies asíncronos/síncronos**. |
| **Estimación** | Story Points (Fibonacci / Planning Poker). | No obligatoria (se mide Throughput y Lead Time). | **Story Points formales para gobernanza y velocidad de equipo**. |
| **Gestión de Cambios** | Backlog bloqueado durante el sprint. | Cambio constante según capacidad disponible. | **Alcance del Sprint protegido con trazabilidad total hacia Jira**. |

### 1.2 Justificación del Modelo Adoptado
Se seleccionó **Scrum Adaptado con Trunk-Based / GitHub Flow**:
1. **Alineación con la Rúbrica Académica e Institucional:** El curso de Ingesoft V exige hitos evaluativos estructurados en dos entregas principales (**Parte 1 / Sprint 1** y **Parte 2 / Sprint 2**), con compromisos formales de puntos de historia y actas de ceremonias.
2. **Compatibilidad con DevOps y Despliegue Continuo:** Mientras la planeación y gobernanza del trabajo se rigen por la cadencia de Sprint, el flujo técnico de integración y entrega es continuo: cada Pull Request integrado en `main` dispara automáticamente las pruebas, el versionado semántico y la promoción entre ambientes (`dev` $\rightarrow$ `stage` $\rightarrow$ `prod`).

---

## 2. Conformación del Equipo y Roles Scrum

El equipo **SuperPoderosos (Grupo 5)** está conformado por 4 ingenieros de sistemas con responsabilidades transversales, combinando desarrollo de microservicios, aseguramiento de calidad e infraestructura en la nube:

| Integrante | Código Estudiantil | Rol Scrum Principal | Responsabilidades DevOps / Técnicas |
| :--- | :---: | :--- | :--- |
| **Juan Camilo Rubio Arboleda** | `A00378093` | **Scrum Master & DevOps Lead** | Gobernanza ágil en Jira, pipeline CI/CD multibranch en Jenkins, SonarQube, Nexus, Shared Library, aprobaciones de producción y ceremonias ágiles. |
| **Juan Pablo Ordoñez Jiménez** | `A00401838` | **Backend & Cloud Infrastructure Engineer** | Aprovisionamiento idempotente en AWS EC2 (scripts Bash), Dockerfiles seguros, Docker Compose por ambiente, promoción CD a dev/stage e informes técnicos. |
| **Esteban Cuéllar** | `A00402548` | **QA Automation & Test Lead** | Pruebas de integración con Testcontainers, automatización E2E con Playwright en Chromium headless, pipeline de rollback y notificaciones. |
| **Santiago Castillo** | `A00395559` | **Frontend & Security Engineer** | Microservicios de identidad y autenticación (LDAP/PostgreSQL), contenedorización de la app cliente Expo Web (Nginx) y políticas de seguridad/RFC. |

---

## 3. Capacidad del Sprint 1 y Escala de Estimación

### 3.1 Capacidad Comprometida
Para el **Sprint 1 (Parte 1)** se comprometió formalmente una capacidad total de:
$$\text{Capacidad Total} = \mathbf{95 \text{ Story Points (SP)}}$$
distribuidos en **19 Historias de Usuario (`US-01` a `US-19`)** agrupadas en **8 Épicas (`EPIC-01` a `EPIC-08`)**.

### 3.2 Escala de Estimación: Serie de Fibonacci Modificada
Se utilizó la técnica de **Planning Poker** aplicando la escala de Fibonacci:

$$\text{Escala} \in \{1, 2, 3, 5, 8, 13\}$$

- **`2 SP` (Bajo):** Tareas operativas de documentación formal o ajustes menores de configuración con cero incertidumbre técnica.
- **`3 SP` (Moderado-Bajo):** Configuración de herramientas aisladas, scripts específicos de empaquetamiento o políticas de gestión de cambios.
- **`5 SP` (Medio):** Aprovisionamiento idempotente de servidores en la nube, contenedorización de familias de microservicios, Quality Gates bloqueantes y scripts de rollback.
- **`8 SP` (Alto):** Componentes medulares de alta complejidad técnica o esfuerzo extensivo (Jenkinsfile Multibranch con Shared Library modular, pruebas de integración Testcontainers, flujos E2E con Playwright y cobertura unitaria $\ge 60\%$).

---

## 4. Estructura del Backlog y Épicas en Jira (`circleguard777`)

Las 8 épicas del proyecto reflejan 1:1 los entregables de la Parte 1 del proyecto:

| Clave Épica | Nombre de la Épica en Jira | Entregable Oficial | Peso Evaluativo | Historias Asociadas | Story Points |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **`EPIC-01`** | Gestión Ágil, Backlog y Estrategia de Branching | `E1.1` (P1.1) | 2.0% | `US-01`, `US-02`, `US-03` | **`8 SP`** |
| **`EPIC-02`** | Infraestructura en la Nube Automatizada con Bash | `E1.2` (P1.2) | 2.0% | `US-04`, `US-05` | **`10 SP`** |
| **`EPIC-03`** | Empaquetamiento Inmutable y Contenedorización | `E1.3` (P1.3) | 2.5% | `US-06`, `US-07`, `US-08` | **`13 SP`** |
| **`EPIC-04`** | Integración Continua (CI) con Jenkins y SonarQube | `E1.4` (P1.4) | 2.5% | `US-09`, `US-10`, `US-11` | **`16 SP`** |
| **`EPIC-05`** | Entrega Continua (CD), Promoción y Rollback | `E1.5` (P1.5) | 2.5% | `US-12`, `US-13`, `US-14` | **`16 SP`** |
| **`EPIC-06`** | Aseguramiento de Calidad y Pruebas Automatizadas | `E1.6` (P1.6) | 3.5% | `US-15`, `US-16`, `US-17` | **`24 SP`** |
| **`EPIC-07`** | Gestión de Cambios (Change Management) y Release Notes | `E1.7` (P1.7) | 1.5% | `US-18` | **`3 SP`** |
| **`EPIC-08`** | Documentación Operativa, Arquitectura y Bitácora IAG | `E1.8` (P1.8) | 1.0% | `US-19` | **`5 SP`** |
| **TOTAL** | **8 Épicas de la Parte 1** | **`E1.1` – `E1.8`** | **15.0%** | **19 Historias (`US-01` – `US-19`)** | **`95 SP`** |

---

## 5. Definición de Hecho (Definition of Done - DoD)

Una Historia de Usuario en CircleGuard se considera terminada (**Done**) únicamente cuando cumple con los siguientes criterios rigurosos:

1. **Código Fuente y Compilación:** El código compila sin errores en Gradle 8.5 / Java 21 y Node 20.
2. **Branching y PR:** El trabajo se desarrolló en una rama `feature/*`, `fix/*` o `docs/*`, cuenta con Pull Request hacia `main` que respeta la plantilla oficial y tiene al menos 1 aprobación técnica por pares.
3. **Validación CI en Jenkins:** El build multibranch en Jenkins ejecuta exitosamente las etapas de análisis estático, cobertura JaCoCo ($\ge 60\%$ en servicios núcleo), Quality Gate en SonarQube y pruebas unitarias/integración.
4. **Idempotencia e Inmutabilidad:** Los scripts Bash y archivos Dockerfiles son reproducibles e idempotentes; las imágenes Docker se construyen y versionan con SemVer inmutable.
5. **Documentación:** Toda funcionalidad técnica cuenta con su respectivo documento de arquitectura u operación en `docs/` y actualización en el `README.md`.
6. **Cierre en Jira:** La historia y sus subtareas correspondientes se encuentran en la columna `Done` del tablero de Jira.
