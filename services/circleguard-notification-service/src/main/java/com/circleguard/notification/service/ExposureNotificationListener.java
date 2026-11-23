package com.circleguard.notification.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Service;

import java.util.Map;

@Service
@RequiredArgsConstructor
@Slf4j
public class ExposureNotificationListener {

    private final NotificationDispatcher dispatcher;
    private final ObjectMapper objectMapper;
    private final LmsService lmsService;

    /**
     * Listens for status changes and exposure events.
     */
    @KafkaListener(topics = "promotion.status.changed", groupId = "notification-group")
    public void handleStatusChange(String eventJson) {
        log.info("Received health status change event: {}", eventJson);
        Map<String, Object> payload = EventPayloads.toMap(objectMapper, eventJson, "promotion.status.changed");
        try {
            String userId = text(payload, "anonymousId", "unknown");
            String status = text(payload, "status", "UNKNOWN");
            
            if (!"ACTIVE".equals(status) && !"UNKNOWN".equals(status)) {
                dispatcher.dispatch(userId, status);
                lmsService.syncRemoteAttendance(userId, status);
            }
        } catch (Exception e) {
            log.error("Failed to process health status change event: {}", e.getMessage());
        }
    }

    private static String text(Map<String, Object> payload, String field, String fallback) {
        Object value = payload.get(field);
        return value == null ? fallback : value.toString();
    }
}
