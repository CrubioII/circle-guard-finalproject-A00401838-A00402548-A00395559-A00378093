package com.circleguard.notification.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class EventPayloadsTest {

    private final ObjectMapper objectMapper = new ObjectMapper();

    @Test
    void parsesAJsonObject() {
        assertThat(EventPayloads.toMap(objectMapper, "{\"circleId\":\"c-1\"}", "circle.fenced"))
                .containsEntry("circleId", "c-1");
    }

    @Test
    void rejectsMalformedAndEmptyPayloads() {
        assertThatThrownBy(() -> EventPayloads.toMap(objectMapper, "not-json", "circle.fenced"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageStartingWith("Malformed circle.fenced event");
        assertThatThrownBy(() -> EventPayloads.toMap(objectMapper, "null", "alert.priority"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("alert.priority event is empty");
    }
}
