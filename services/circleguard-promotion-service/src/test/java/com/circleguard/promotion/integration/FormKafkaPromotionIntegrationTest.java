package com.circleguard.promotion.integration;

import com.circleguard.form.model.HealthSurvey;
import com.circleguard.form.model.Question;
import com.circleguard.form.model.QuestionType;
import com.circleguard.form.model.Questionnaire;
import com.circleguard.form.repository.HealthSurveyRepository;
import com.circleguard.form.service.HealthSurveyService;
import com.circleguard.form.service.QuestionnaireService;
import com.circleguard.form.service.SymptomMapper;
import com.circleguard.promotion.model.graph.UserNode;
import com.circleguard.promotion.repository.graph.UserNodeRepository;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.YamlPropertiesFactoryBean;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.core.io.FileSystemResource;
import org.springframework.kafka.core.DefaultKafkaProducerFactory;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.kafka.support.serializer.JsonSerializer;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.KafkaContainer;
import org.testcontainers.containers.Neo4jContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Properties;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * US-16 — Prueba de integración del flujo form → Kafka → promotion con Testcontainers.
 *
 * Usa un broker Kafka REAL (misma imagen cp-kafka 7.6.0 de los compose de US-08), Neo4j y Redis reales:
 *   1. El código de producción de form-service ({@link HealthSurveyService#submitSurvey}) publica
 *      'survey.submitted' con la serialización configurada en form-service (StringSerializer + JsonSerializer).
 *   2. El contexto completo de promotion-service consume el evento con su propia configuración
 *      (JsonDeserializer) a través de {@code SurveyListener}.
 *   3. Se verifica el efecto: el usuario queda SUSPECT en Neo4j y promotion publica
 *      'promotion.status.changed' de nuevo en Kafka.
 *
 * La configuración spring.kafka.* de promotion se lee de su application.yml de producción.
 * Solo se simulan los repositorios JPA de form-service (no participan del flujo de mensajería).
 */
@SpringBootTest
@Testcontainers(disabledWithoutDocker = true)
class FormKafkaPromotionIntegrationTest {

    private static final Duration TIMEOUT = Duration.ofSeconds(30);
    private static final String PRODUCTION_CONFIG = "src/main/resources/application.yml";

    @Container
    static KafkaContainer kafka = new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.6.0"));

    @Container
    static Neo4jContainer<?> neo4j = new Neo4jContainer<>("neo4j:5.12.0").withAdminPassword("password");

    @Container
    static GenericContainer<?> redis = new GenericContainer<>("redis:7.2.1").withExposedPorts(6379);

    @DynamicPropertySource
    static void properties(DynamicPropertyRegistry registry) {
        // src/test/resources/application.yml oculta el application.yml de producción, así que la sección
        // spring.kafka.* se carga del archivo REAL de promotion: la prueba valida la configuración que se despliega.
        productionKafkaProperties().forEach((key, value) -> registry.add(key, () -> value));
        registry.add("spring.kafka.bootstrap-servers", kafka::getBootstrapServers);
        registry.add("spring.neo4j.uri", neo4j::getBoltUrl);
        registry.add("spring.neo4j.authentication.username", () -> "neo4j");
        registry.add("spring.neo4j.authentication.password", () -> "password");
        registry.add("spring.data.redis.host", redis::getHost);
        registry.add("spring.data.redis.port", redis::getFirstMappedPort);
    }

    @Autowired
    private UserNodeRepository userRepository;

    private KafkaTemplate<String, Object> formKafkaTemplate;
    private HealthSurveyService formSurveyService;
    private Questionnaire activeQuestionnaire;
    private UUID feverQuestionId;

    @BeforeEach
    void setUp() {
        userRepository.deleteAll();

        // Productor con la misma configuración que circleguard-form-service/src/main/resources/application.yml
        Map<String, Object> producerProps = Map.of(
                ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, kafka.getBootstrapServers(),
                ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class,
                ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, JsonSerializer.class);
        formKafkaTemplate = new KafkaTemplate<>(new DefaultKafkaProducerFactory<>(producerProps));

        feverQuestionId = UUID.randomUUID();
        Question fever = Question.builder()
                .id(feverQuestionId).text("Do you have fever?").type(QuestionType.YES_NO).orderIndex(1).build();
        activeQuestionnaire = Questionnaire.builder()
                .id(UUID.randomUUID()).title("Daily check").version(1).isActive(true).questions(List.of(fever)).build();

        HealthSurveyRepository surveyRepository = mock(HealthSurveyRepository.class);
        when(surveyRepository.save(any(HealthSurvey.class))).thenAnswer(inv -> inv.getArgument(0));
        QuestionnaireService questionnaireService = mock(QuestionnaireService.class);
        when(questionnaireService.getActiveQuestionnaire()).thenReturn(Optional.of(activeQuestionnaire));

        formSurveyService = new HealthSurveyService(
                surveyRepository, questionnaireService, new SymptomMapper(), formKafkaTemplate);
    }

    @AfterEach
    void tearDown() {
        formKafkaTemplate.destroy();
    }

    @Test
    @DisplayName("CA1: encuesta con síntomas en form promueve a SUSPECT vía Kafka y propaga PROBABLE a su contacto")
    void surveyWithSymptoms_promotesUserAndCascadesToContact() throws Exception {
        UUID anonymousId = UUID.randomUUID();
        String contactId = UUID.randomUUID().toString();
        userRepository.save(UserNode.builder().anonymousId(anonymousId.toString()).status("ACTIVE").build());
        userRepository.save(UserNode.builder().anonymousId(contactId).status("ACTIVE").build());
        userRepository.recordEncounter(anonymousId.toString(), contactId, System.currentTimeMillis(), "aula-101");

        try (KafkaConsumer<String, String> statusConsumer = consumerFor("promotion.status.changed")) {
            formSurveyService.submitSurvey(survey(anonymousId, "YES"));
            formKafkaTemplate.flush();

            assertThat(awaitStatus(anonymousId.toString(), "SUSPECT"))
                    .as("estado en Neo4j tras consumir survey.submitted")
                    .isEqualTo("SUSPECT");
            assertThat(awaitStatus(contactId, "PROBABLE"))
                    .as("cascada: el contacto de los últimos 14 días pasa a PROBABLE")
                    .isEqualTo("PROBABLE");

            ConsumerRecord<String, String> published = awaitRecord(statusConsumer, anonymousId.toString());
            assertThat(published).as("promotion publica promotion.status.changed").isNotNull();
            assertThat(published.value()).contains("SUSPECT");
        }
    }

    @Test
    @DisplayName("CA2: encuesta sin síntomas atraviesa Kafka pero no cambia el estado del usuario")
    void surveyWithoutSymptoms_keepsUserActive() throws Exception {
        UUID healthy = UUID.randomUUID();
        UUID sentinel = UUID.randomUUID();
        userRepository.save(UserNode.builder().anonymousId(healthy.toString()).status("ACTIVE").build());
        userRepository.save(UserNode.builder().anonymousId(sentinel.toString()).status("ACTIVE").build());

        formSurveyService.submitSurvey(survey(healthy, "NO"));
        // El centinela va después en la misma partición lógica del listener: cuando él cambia,
        // el evento sin síntomas ya fue procesado.
        formSurveyService.submitSurvey(survey(sentinel, "YES"));
        formKafkaTemplate.flush();

        assertThat(awaitStatus(sentinel.toString(), "SUSPECT")).isEqualTo("SUSPECT");
        assertThat(userRepository.findById(healthy.toString()))
                .get().extracting(UserNode::getStatus).isEqualTo("ACTIVE");
    }

    @Test
    @DisplayName("CA3: el evento que publica form respeta el contrato que lee promotion")
    void submittedEvent_matchesPromotionContract() throws Exception {
        UUID anonymousId = UUID.randomUUID();
        try (KafkaConsumer<String, String> rawConsumer = consumerFor("survey.submitted")) {
            formSurveyService.submitSurvey(survey(anonymousId, "YES"));
            formKafkaTemplate.flush();

            ConsumerRecord<String, String> record = awaitRecord(rawConsumer, anonymousId.toString());
            assertThat(record).isNotNull();
            assertThat(record.key()).isEqualTo(anonymousId.toString());
            assertThat(record.value())
                    .contains("\"anonymousId\":\"" + anonymousId + "\"")
                    .contains("\"hasSymptoms\":true")
                    .contains("\"timestamp\"");
        }
    }

    private static Map<String, Object> productionKafkaProperties() {
        YamlPropertiesFactoryBean yaml = new YamlPropertiesFactoryBean();
        yaml.setResources(new FileSystemResource(PRODUCTION_CONFIG));
        Properties all = yaml.getObject();
        assertThat(all).as("no se encontró " + PRODUCTION_CONFIG).isNotNull();
        Map<String, Object> kafkaProps = new HashMap<>();
        all.stringPropertyNames().stream()
                .filter(key -> key.startsWith("spring.kafka."))
                .forEach(key -> kafkaProps.put(key, all.getProperty(key)));
        return kafkaProps;
    }

    private HealthSurvey survey(UUID anonymousId, String feverAnswer) {
        return HealthSurvey.builder()
                .anonymousId(anonymousId)
                .responses(Map.of(feverQuestionId.toString(), feverAnswer))
                .build();
    }

    private String awaitStatus(String anonymousId, String expected) throws InterruptedException {
        long deadline = System.currentTimeMillis() + TIMEOUT.toMillis();
        String current = null;
        while (System.currentTimeMillis() < deadline) {
            current = userRepository.findById(anonymousId).map(UserNode::getStatus).orElse(null);
            if (expected.equals(current)) {
                return current;
            }
            Thread.sleep(250);
        }
        return current;
    }

    private KafkaConsumer<String, String> consumerFor(String topic) {
        KafkaConsumer<String, String> consumer = new KafkaConsumer<>(Map.of(
                ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, kafka.getBootstrapServers(),
                ConsumerConfig.GROUP_ID_CONFIG, "us16-verifier-" + UUID.randomUUID(),
                ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest",
                ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class,
                ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class));
        consumer.subscribe(List.of(topic));
        return consumer;
    }

    private ConsumerRecord<String, String> awaitRecord(KafkaConsumer<String, String> consumer, String key) {
        long deadline = System.currentTimeMillis() + TIMEOUT.toMillis();
        List<ConsumerRecord<String, String>> seen = new ArrayList<>();
        while (System.currentTimeMillis() < deadline) {
            for (ConsumerRecord<String, String> record : consumer.poll(Duration.ofMillis(500))) {
                seen.add(record);
                if (key.equals(record.key())) {
                    return record;
                }
            }
        }
        return null;
    }
}
