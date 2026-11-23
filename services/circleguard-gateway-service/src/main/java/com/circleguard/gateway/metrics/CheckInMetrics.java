package com.circleguard.gateway.metrics;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.stereotype.Component;

/**
 * Check-ins en las puertas del campus (US-41 / SCRUM-122).
 * {@code circleguard_checkins_total{result}} con result = granted, denied (riesgo de salud) o invalid (QR malo o vencido).
 */
@Component
public class CheckInMetrics {

    public static final String GRANTED = "granted";
    public static final String DENIED = "denied";
    public static final String INVALID = "invalid";

    private final Counter granted;
    private final Counter denied;
    private final Counter invalid;

    public CheckInMetrics(MeterRegistry registry) {
        this.granted = counter(registry, GRANTED);
        this.denied = counter(registry, DENIED);
        this.invalid = counter(registry, INVALID);
    }

    private static Counter counter(MeterRegistry registry, String result) {
        return Counter.builder("circleguard.checkins")
                .description("Validaciones de QR en las puertas del campus")
                .tag("result", result)
                .register(registry);
    }

    public void granted() {
        granted.increment();
    }

    public void denied() {
        denied.increment();
    }

    public void invalid() {
        invalid.increment();
    }
}
