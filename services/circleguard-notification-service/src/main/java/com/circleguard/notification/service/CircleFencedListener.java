package com.circleguard.notification.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Service;

import java.util.Map;

@Service
@RequiredArgsConstructor
@Slf4j
public class CircleFencedListener {

    private final ObjectMapper objectMapper;
    private final RoomReservationService roomReservationService;

    @KafkaListener(topics = "circle.fenced", groupId = "notification-group")
    public void handleCircleFenced(String message) {
        log.info("Received circle.fenced event: {}", message);
        Map<String, Object> payload = parse(message);
        try {
            String circleId = (String) payload.get("circleId");
            String locationId = (String) payload.get("locationId");

            if (locationId != null && !locationId.isEmpty()) {
                roomReservationService.cancelReservation(circleId, locationId);
            } else {
                log.warn("Circle {} has no locationId. Skipping room cancellation.", circleId);
            }
        } catch (Exception e) {
            log.error("Failed to process circle.fenced event: {}", e.getMessage());
        }
    }

    // A payload that is not valid JSON can never succeed: let it reach the Dead Letter Topic (US-40).
    private Map<String, Object> parse(String message) {
        try {
            Map<String, Object> payload = objectMapper.readValue(message, new TypeReference<Map<String, Object>>() {});
            if (payload == null) {
                throw new IllegalArgumentException("circle.fenced event is empty");
            }
            return payload;
        } catch (JsonProcessingException e) {
            throw new IllegalArgumentException("Malformed circle.fenced event: " + e.getOriginalMessage(), e);
        }
    }
}
