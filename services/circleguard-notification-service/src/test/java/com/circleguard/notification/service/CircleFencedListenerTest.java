package com.circleguard.notification.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/**
 * US-32: cancelación de reservas cuando un círculo queda cercado.
 */
class CircleFencedListenerTest {

    private final RoomReservationService roomReservationService = mock(RoomReservationService.class);
    private final CircleFencedListener listener = new CircleFencedListener(new ObjectMapper(), roomReservationService);

    @Test
    void cancelsReservationWhenLocationIsPresent() {
        listener.handleCircleFenced("{\"circleId\":\"c-1\",\"locationId\":\"room-101\"}");

        verify(roomReservationService).cancelReservation("c-1", "room-101");
    }

    @Test
    void skipsCancellationWhenLocationIsMissing() {
        listener.handleCircleFenced("{\"circleId\":\"c-1\"}");

        verifyNoInteractions(roomReservationService);
    }

    @Test
    void skipsCancellationWhenLocationIsEmpty() {
        listener.handleCircleFenced("{\"circleId\":\"c-1\",\"locationId\":\"\"}");

        verifyNoInteractions(roomReservationService);
    }

    @Test
    void ignoresMalformedMessages() {
        listener.handleCircleFenced("not-json");

        verify(roomReservationService, never()).cancelReservation(any(), any());
    }
}
