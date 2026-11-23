package com.circleguard.promotion.metrics;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Component;

import java.time.Duration;

/**
 * Métricas de negocio de la promoción de estados (US-41 / SCRUM-122).
 *
 * <ul>
 *   <li>{@code circleguard_promotions_total{status}}: cambios de estado aplicados. Con rate() da promociones por minuto.</li>
 *   <li>{@code circleguard_containment_seconds}: tiempo de contención, desde que llega el cambio de estado hasta que
 *       los contactos quedan cercados, la caché actualizada y el evento publicado.</li>
 *   <li>{@code circleguard_contacts_fenced_total{status}}: contactos que el cerco movió a SUSPECT o PROBABLE.</li>
 * </ul>
 */
@Component
public class PromotionMetrics {

    static final String PROMOTIONS = "circleguard.promotions";
    static final String CONTAINMENT = "circleguard.containment";
    static final String CONTACTS_FENCED = "circleguard.contacts.fenced";
    static final String STATUS_TAG = "status";

    private final MeterRegistry registry;

    public PromotionMetrics(MeterRegistry registry) {
        this.registry = registry;
    }

    public Timer.Sample startContainment() {
        return Timer.start(registry);
    }

    /** Registra una promoción terminada y cuánto tardó su contención. */
    public void promotionCompleted(Timer.Sample sample, String status, int contactsFenced) {
        sample.stop(Timer.builder(CONTAINMENT)
                .description("Tiempo desde el cambio de estado hasta el cerco de los contactos")
                .tag(STATUS_TAG, status)
                .publishPercentileHistogram()
                .serviceLevelObjectives(Duration.ofMillis(300), Duration.ofSeconds(1))
                .register(registry));
        Counter.builder(PROMOTIONS)
                .description("Cambios de estado de salud aplicados")
                .tag(STATUS_TAG, status)
                .register(registry)
                .increment();
        if (contactsFenced > 0) {
            Counter.builder(CONTACTS_FENCED)
                    .description("Contactos cercados por una promoción")
                    .tag(STATUS_TAG, status)
                    .register(registry)
                    .increment(contactsFenced);
        }
    }
}
