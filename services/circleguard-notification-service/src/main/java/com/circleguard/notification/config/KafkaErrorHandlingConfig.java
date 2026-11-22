package com.circleguard.notification.config;

import com.fasterxml.jackson.core.JsonProcessingException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.core.KafkaOperations;
import org.springframework.kafka.listener.ConsumerRecordRecoverer;
import org.springframework.kafka.listener.DeadLetterPublishingRecoverer;
import org.springframework.kafka.listener.DefaultErrorHandler;
import org.springframework.util.backoff.FixedBackOff;

/**
 * Retry + Dead Letter Topic for every {@code @KafkaListener} of the service (US-40).
 *
 * <p>A record whose listener throws is retried {@code max-retries} times, waiting
 * {@code retry-interval-ms} between attempts. If it still fails, it is published to
 * {@code <original-topic>.DLT} (same partition, or any partition if the DLT has fewer) and the
 * consumer moves on, so one poison message never blocks the partition. Errors that cannot
 * succeed on a retry (malformed payloads) go to the DLT on the first failure.
 *
 * <p>Spring Boot wires this single {@code CommonErrorHandler} bean into the auto-configured
 * listener container factory used by all {@code @KafkaListener}s.
 */
@Configuration
public class KafkaErrorHandlingConfig {

    public static final String DLT_SUFFIX = ".DLT";

    @Bean
    public DefaultErrorHandler kafkaErrorHandler(
            KafkaOperations<Object, Object> kafkaOperations,
            @Value("${circleguard.kafka.dlq.retry-interval-ms:1000}") long retryIntervalMs,
            @Value("${circleguard.kafka.dlq.max-retries:2}") long maxRetries) {
        return errorHandler(new DeadLetterPublishingRecoverer(kafkaOperations), retryIntervalMs, maxRetries);
    }

    static DefaultErrorHandler errorHandler(ConsumerRecordRecoverer recoverer, long retryIntervalMs, long maxRetries) {
        DefaultErrorHandler handler = new DefaultErrorHandler(recoverer, new FixedBackOff(retryIntervalMs, maxRetries));
        handler.addNotRetryableExceptions(IllegalArgumentException.class, JsonProcessingException.class);
        return handler;
    }
}
