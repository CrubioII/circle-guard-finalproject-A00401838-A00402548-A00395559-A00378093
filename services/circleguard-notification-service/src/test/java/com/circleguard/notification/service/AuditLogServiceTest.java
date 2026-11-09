package com.circleguard.notification.service;

import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.kafka.core.KafkaTemplate;

import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

/**
 * US-32: auditoría de entregas publicada en Kafka.
 */
class AuditLogServiceTest {

    @SuppressWarnings("unchecked")
    private final KafkaTemplate<String, Object> kafkaTemplate = mock(KafkaTemplate.class);
    private final AuditLogService service = new AuditLogService(kafkaTemplate);

    @SuppressWarnings("unchecked")
    private Map<String, Object> captureEvent(String userId) {
        ArgumentCaptor<Object> captor = ArgumentCaptor.forClass(Object.class);
        verify(kafkaTemplate).send(eq("notification.audit"), eq(userId), captor.capture());
        return (Map<String, Object>) captor.getValue();
    }

    @Test
    void publishesAuditEventWithGivenCorrelationId() {
        service.logDelivery("anon-1", "EMAIL", "SUCCESS", "corr-123");

        Map<String, Object> event = captureEvent("anon-1");
        assertEquals("anon-1", event.get("userId"));
        assertEquals("EMAIL", event.get("channel"));
        assertEquals("SUCCESS", event.get("status"));
        assertEquals("corr-123", event.get("correlationId"));
        assertDoesNotThrow(() -> UUID.fromString((String) event.get("eventId")));
        assertNotNull(event.get("timestamp"));
    }

    @Test
    void generatesCorrelationIdWhenMissing() {
        service.logDelivery("anon-2", "SMS", "FAILED", null);

        Map<String, Object> event = captureEvent("anon-2");
        assertDoesNotThrow(() -> UUID.fromString((String) event.get("correlationId")));
    }
}
