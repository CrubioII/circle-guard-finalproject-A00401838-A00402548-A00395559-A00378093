package com.circleguard.notification.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Service;

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
        JsonNode node = parse(eventJson);
        try {
            String userId = node.path("anonymousId").asText("unknown");
            String status = node.path("status").asText("UNKNOWN");
            
            if (!"ACTIVE".equals(status) && !"UNKNOWN".equals(status)) {
                dispatcher.dispatch(userId, status);
                lmsService.syncRemoteAttendance(userId, status);
            }
        } catch (Exception e) {
            log.error("Failed to process health status change event: {}", e.getMessage());
        }
    }

    // A payload that is not a JSON object can never succeed: let it reach the Dead Letter Topic (US-40).
    private JsonNode parse(String eventJson) {
        try {
            JsonNode node = objectMapper.readTree(eventJson);
            if (node == null || !node.isObject()) {
                throw new IllegalArgumentException("promotion.status.changed event is not a JSON object");
            }
            return node;
        } catch (JsonProcessingException e) {
            throw new IllegalArgumentException("Malformed promotion.status.changed event: " + e.getOriginalMessage(), e);
        }
    }
}
