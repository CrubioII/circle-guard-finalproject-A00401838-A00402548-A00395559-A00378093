package com.circleguard.notification.service;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.junit.jupiter.api.Test;
import org.springframework.kafka.support.KafkaHeaders;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;

class DeadLetterListenerTest {

    private final DeadLetterListener listener = new DeadLetterListener();

    @Test
    void readsTheDeadLetterHeaders() {
        ConsumerRecord<String, String> consumerRecord = new ConsumerRecord<>("circle.fenced.DLT", 0, 5L, "key-1", "not-json");
        consumerRecord.headers().add(KafkaHeaders.DLT_ORIGINAL_TOPIC, "circle.fenced".getBytes(StandardCharsets.UTF_8));
        consumerRecord.headers().add(KafkaHeaders.DLT_ORIGINAL_PARTITION, ByteBuffer.allocate(Integer.BYTES).putInt(2).array());
        consumerRecord.headers().add(KafkaHeaders.DLT_ORIGINAL_OFFSET, ByteBuffer.allocate(Long.BYTES).putLong(41L).array());
        consumerRecord.headers().add(KafkaHeaders.DLT_EXCEPTION_MESSAGE, "Malformed circle.fenced event".getBytes(StandardCharsets.UTF_8));

        assertThat(DeadLetterListener.header(consumerRecord, KafkaHeaders.DLT_ORIGINAL_TOPIC, "?")).isEqualTo("circle.fenced");
        assertThat(DeadLetterListener.header(consumerRecord, KafkaHeaders.DLT_ORIGINAL_PARTITION, "?")).isEqualTo("2");
        assertThat(DeadLetterListener.header(consumerRecord, KafkaHeaders.DLT_ORIGINAL_OFFSET, "?")).isEqualTo("41");
        assertThat(DeadLetterListener.header(consumerRecord, KafkaHeaders.DLT_EXCEPTION_MESSAGE, "?")).isEqualTo("Malformed circle.fenced event");
        assertThatCode(() -> listener.handleDeadLetter(consumerRecord)).doesNotThrowAnyException();
    }

    @Test
    void neverFailsWhenHeadersAreMissing() {
        ConsumerRecord<String, String> consumerRecord = new ConsumerRecord<>("alert.priority.DLT", 0, 0L, null, null);

        assertThat(DeadLetterListener.header(consumerRecord, KafkaHeaders.DLT_EXCEPTION_MESSAGE, "unknown")).isEqualTo("unknown");
        assertThatCode(() -> listener.handleDeadLetter(consumerRecord)).doesNotThrowAnyException();
    }
}
