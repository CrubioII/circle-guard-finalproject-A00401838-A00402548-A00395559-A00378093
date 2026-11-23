package com.circleguard.notification.service;

import lombok.extern.slf4j.Slf4j;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.common.header.Header;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.stereotype.Service;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/**
 * Consumes the Dead Letter Topics (US-40) so every message that could not be processed leaves
 * an error-level trace with its original topic, key and failure reason.
 *
 * <p>It never throws: a failure here must not send the record to yet another dead letter topic.
 */
@Service
@Slf4j
public class DeadLetterListener {

    @KafkaListener(
            topics = {"promotion.status.changed.DLT", "circle.fenced.DLT", "alert.priority.DLT"},
            groupId = "notification-dlt-group")
    public void handleDeadLetter(ConsumerRecord<String, String> consumerRecord) {
        log.error("Dead letter received from topic={} partition={} offset={} key={} exception={} message={} payload={}",
                header(consumerRecord, KafkaHeaders.DLT_ORIGINAL_TOPIC, consumerRecord.topic()),
                header(consumerRecord, KafkaHeaders.DLT_ORIGINAL_PARTITION, "?"),
                header(consumerRecord, KafkaHeaders.DLT_ORIGINAL_OFFSET, "?"),
                consumerRecord.key(),
                header(consumerRecord, KafkaHeaders.DLT_EXCEPTION_FQCN, "unknown"),
                header(consumerRecord, KafkaHeaders.DLT_EXCEPTION_MESSAGE, "unknown"),
                consumerRecord.value());
    }

    static String header(ConsumerRecord<?, ?> consumerRecord, String name, String fallback) {
        Header header = consumerRecord.headers().lastHeader(name);
        if (header == null || header.value() == null) {
            return fallback;
        }
        if (KafkaHeaders.DLT_ORIGINAL_PARTITION.equals(name) && header.value().length == Integer.BYTES) {
            return String.valueOf(ByteBuffer.wrap(header.value()).getInt());
        }
        if (KafkaHeaders.DLT_ORIGINAL_OFFSET.equals(name) && header.value().length == Long.BYTES) {
            return String.valueOf(ByteBuffer.wrap(header.value()).getLong());
        }
        return new String(header.value(), StandardCharsets.UTF_8);
    }
}
