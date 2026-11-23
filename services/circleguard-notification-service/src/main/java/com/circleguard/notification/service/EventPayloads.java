package com.circleguard.notification.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.Map;

/**
 * Parses Kafka event payloads (US-40). A payload that is not a JSON object can never succeed on a
 * retry, so it fails with {@link IllegalArgumentException} and goes straight to the Dead Letter Topic.
 */
final class EventPayloads {

    private static final TypeReference<Map<String, Object>> MAP_TYPE = new TypeReference<>() {};

    private EventPayloads() {
    }

    static Map<String, Object> toMap(ObjectMapper objectMapper, String message, String topic) {
        try {
            Map<String, Object> payload = objectMapper.readValue(message, MAP_TYPE);
            if (payload == null) {
                throw new IllegalArgumentException(topic + " event is empty");
            }
            return payload;
        } catch (JsonProcessingException e) {
            throw new IllegalArgumentException("Malformed " + topic + " event: " + e.getOriginalMessage(), e);
        }
    }
}
