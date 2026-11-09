package com.circleguard.identity.integration;

import com.circleguard.identity.model.IdentityMapping;
import com.circleguard.identity.repository.IdentityMappingRepository;
import com.circleguard.identity.util.IdentityEncryptionConverter;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.context.annotation.Import;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Prueba de integración de identity-service contra un PostgreSQL real (Testcontainers).
 *
 * <p>US-33 (SCRUM-112 / SCRUM-77) — CA1: la migración Flyway del Identity Vault coincide
 * con la entidad (ddl-auto=validate), la identidad real se guarda cifrada en BYTEA y el
 * índice ciego (identity_hash) es único y consultable.</p>
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import(IdentityEncryptionConverter.class)
@Testcontainers(disabledWithoutDocker = true)
class IdentityMappingRepositoryPostgresIntegrationTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("circleguard_identity")
            .withUsername("circleguard")
            .withPassword("circleguard-test");

    @DynamicPropertySource
    static void postgresProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        registry.add("spring.datasource.driver-class-name", () -> "org.postgresql.Driver");
        registry.add("spring.jpa.database-platform", () -> "org.hibernate.dialect.PostgreSQLDialect");
        // Contrato: la entidad debe coincidir con el esquema que crea Flyway.
        registry.add("spring.jpa.hibernate.ddl-auto", () -> "validate");
        registry.add("spring.flyway.enabled", () -> "true");
    }

    @Autowired
    private IdentityMappingRepository repository;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @Test
    @DisplayName("Guarda y recupera la identidad por su índice ciego (identity_hash)")
    void saveAndFindByIdentityHash() {
        IdentityMapping saved = repository.saveAndFlush(mapping("student@icesi.edu.co", "hash-001"));

        assertThat(saved.getAnonymousId()).isNotNull();
        assertThat(repository.findByIdentityHash("hash-001"))
                .isPresent()
                .get()
                .satisfies(m -> {
                    assertThat(m.getAnonymousId()).isEqualTo(saved.getAnonymousId());
                    assertThat(m.getRealIdentity()).isEqualTo("student@icesi.edu.co");
                });
    }

    @Test
    @DisplayName("La identidad real se persiste cifrada: nunca en texto plano en PostgreSQL")
    void realIdentityIsStoredEncrypted() {
        IdentityMapping saved = repository.saveAndFlush(mapping("secreto@icesi.edu.co", "hash-002"));

        byte[] raw = jdbcTemplate.queryForObject(
                "SELECT real_identity_encrypted FROM identity_mappings WHERE anonymous_id = ?",
                byte[].class, saved.getAnonymousId());

        assertThat(raw).isNotEmpty();
        assertThat(new String(raw, StandardCharsets.UTF_8)).doesNotContain("secreto@icesi.edu.co");
    }

    @Test
    @DisplayName("El índice ciego es único: un hash duplicado se rechaza en la base")
    void identityHashIsUnique() {
        repository.saveAndFlush(mapping("a@icesi.edu.co", "hash-dup"));

        assertThatThrownBy(() -> repository.saveAndFlush(mapping("b@icesi.edu.co", "hash-dup")))
                .isInstanceOf(DataIntegrityViolationException.class);
    }

    @Test
    @DisplayName("Un hash desconocido no devuelve identidad")
    void unknownHashReturnsEmpty() {
        assertThat(repository.findByIdentityHash("no-existe")).isEmpty();
    }

    private static IdentityMapping mapping(String realIdentity, String hash) {
        return IdentityMapping.builder()
                .realIdentity(realIdentity)
                .identityHash(hash)
                .salt("salt-" + hash)
                .build();
    }
}
