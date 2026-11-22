package com.circleguard.notification.config;

import com.fasterxml.jackson.core.JsonParseException;
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.junit.jupiter.api.Test;
import org.springframework.kafka.listener.ConsumerRecordRecoverer;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.springframework.kafka.listener.ListenerExecutionFailedException;
import org.springframework.kafka.listener.MessageListenerContainer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

class KafkaErrorHandlingConfigTest {

    private final ConsumerRecordRecoverer recoverer = mock(ConsumerRecordRecoverer.class);
    private final Consumer<?, ?> consumer = mock(Consumer.class);
    private final MessageListenerContainer container = mock(MessageListenerContainer.class);
    private final ConsumerRecord<String, String> record = new ConsumerRecord<>("circle.fenced", 0, 0L, "k", "v");

    @Test
    void transientErrorsAreRetriedBeforeGoingToTheDeadLetterTopic() {
        DefaultErrorHandler handler = KafkaErrorHandlingConfig.errorHandler(recoverer, 0L, 2L);
        RuntimeException failure = wrap(new IllegalStateException("downstream unavailable"));

        assertThat(handler.handleOne(failure, record, consumer, container)).isFalse();
        assertThat(handler.handleOne(failure, record, consumer, container)).isFalse();
        verifyNoInteractions(recoverer);

        assertThat(handler.handleOne(failure, record, consumer, container)).isTrue();
        verify(recoverer).accept(eq(record), any());
    }

    @Test
    void malformedPayloadsGoStraightToTheDeadLetterTopic() {
        DefaultErrorHandler handler = KafkaErrorHandlingConfig.errorHandler(recoverer, 0L, 2L);

        assertThat(handler.handleOne(wrap(new IllegalArgumentException("Malformed")), record, consumer, container)).isTrue();
        assertThat(handler.handleOne(wrap(new JsonParseException(null, "bad json")), record, consumer, container)).isTrue();
        verify(recoverer, times(2)).accept(eq(record), any());
    }

    private static RuntimeException wrap(Exception cause) {
        return new ListenerExecutionFailedException("listener failed", cause);
    }
}
