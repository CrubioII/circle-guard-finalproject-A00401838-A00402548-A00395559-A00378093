package com.circleguard.promotion.metrics;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

/** US-41: una promoción suma al contador, registra su tiempo de contención y cuenta los contactos cercados. */
class PromotionMetricsTest {

    private final SimpleMeterRegistry registry = new SimpleMeterRegistry();
    private final PromotionMetrics metrics = new PromotionMetrics(registry);

    @Test
    void recordsPromotionContainmentAndFencedContacts() {
        metrics.promotionCompleted(metrics.startContainment(), "CONFIRMED", 3);
        metrics.promotionCompleted(metrics.startContainment(), "CONFIRMED", 2);

        assertEquals(2.0, registry.get(PromotionMetrics.PROMOTIONS).tag("status", "CONFIRMED").counter().count());
        assertEquals(2L, registry.get(PromotionMetrics.CONTAINMENT).tag("status", "CONFIRMED").timer().count());
        assertEquals(5.0, registry.get(PromotionMetrics.CONTACTS_FENCED).tag("status", "CONFIRMED").counter().count());
    }

    @Test
    void doesNotCountFencedContactsWhenNoneWereAffected() {
        metrics.promotionCompleted(metrics.startContainment(), "SUSPECT", 0);

        assertEquals(1.0, registry.get(PromotionMetrics.PROMOTIONS).tag("status", "SUSPECT").counter().count());
        assertNull(registry.find(PromotionMetrics.CONTACTS_FENCED).counter());
    }
}
