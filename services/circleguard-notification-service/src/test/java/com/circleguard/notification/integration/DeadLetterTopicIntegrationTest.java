package com.circleguard.notification.integration;

import com.circleguard.notification.service.RoomReservationService;
import org.apache.kafka.clients.consumer.Consumer;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.kafka.core.DefaultKafkaConsumerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.kafka.test.EmbeddedKafkaBroker;
import org.springframework.kafka.test.context.EmbeddedKafka;
import org.springframework.kafka.test.utils.KafkaTestUtils;
import org.springframework.test.annotation.DirtiesContext;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.timeout;
import static org.mockito.Mockito.verify;

/**
 * US-40: a poison message on a real listener topic ends up in its Dead Letter Topic, while a valid
 * message is processed and never reaches the DLT.
 */
@SpringBootTest(properties = {
        "spring.kafka.bootstrap-servers=${spring.embedded.kafka.brokers}",
        "spring.kafka.consumer.auto-offset-reset=earliest",
        "circleguard.kafka.dlq.retry-interval-ms=100"
})
@EmbeddedKafka(partitions = 1, topics = {"circle.fenced", "circle.fenced.DLT"})
@DirtiesContext
class DeadLetterTopicIntegrationTest {

    private static final String TOPIC = "circle.fenced";
    private static final String DLT = TOPIC + ".DLT";

    @Autowired
    private EmbeddedKafkaBroker broker;

    @Autowired
    private KafkaTemplate<String, String> kafkaTemplate;

    @MockBean
    private RoomReservationService roomReservationService;

    private Consumer<String, String> dltConsumer;

    @BeforeEach
    void subscribeToDeadLetterTopic() {
        Map<String, Object> props = KafkaTestUtils.consumerProps("dlt-test-group", "false", broker);
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        dltConsumer = new DefaultKafkaConsumerFactory<>(props, new StringDeserializer(), new StringDeserializer())
                .createConsumer();
        broker.consumeFromAnEmbeddedTopic(dltConsumer, DLT);
    }

    @AfterEach
    void close() {
        dltConsumer.close();
    }

    @Test
    void poisonMessageGoesToTheDeadLetterTopicAndValidMessageDoesNot() throws Exception {
        kafkaTemplate.send(TOPIC, "valid", "{\"circleId\":\"c-1\",\"locationId\":\"room-101\"}").get();
        kafkaTemplate.send(TOPIC, "poison", "not-json").get();

        verify(roomReservationService, timeout(15_000)).cancelReservation("c-1", "room-101");

        ConsumerRecord<String, String> deadLetter = KafkaTestUtils.getSingleRecord(dltConsumer, DLT, Duration.ofSeconds(15));
        assertThat(deadLetter.key()).isEqualTo("poison");
        assertThat(deadLetter.value()).isEqualTo("not-json");
        assertThat(header(deadLetter, KafkaHeaders.DLT_ORIGINAL_TOPIC)).isEqualTo(TOPIC);
        assertThat(header(deadLetter, KafkaHeaders.DLT_EXCEPTION_MESSAGE)).contains("Malformed circle.fenced event");

        List<ConsumerRecord<String, String>> more = new ArrayList<>();
        ConsumerRecords<String, String> rest = KafkaTestUtils.getRecords(dltConsumer, Duration.ofSeconds(2));
        rest.forEach(more::add);
        assertThat(more).as("the valid message must not reach the DLT").isEmpty();
    }

    private static String header(ConsumerRecord<?, ?> consumerRecord, String name) {
        return new String(consumerRecord.headers().lastHeader(name).value(), StandardCharsets.UTF_8);
    }
}
