package com.circleguard.auth.integration;

import com.circleguard.auth.model.LocalUser;
import com.circleguard.auth.repository.LocalUserRepository;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Prueba de integración de auth-service contra un PostgreSQL real (Testcontainers).
 *
 * <p>US-33 (SCRUM-112 / SCRUM-77) — CA1: las migraciones Flyway reales construyen el
 * esquema RBAC y el repositorio cumple el contrato que usa el login y la gestión de
 * permisos (búsqueda por usuario y por permiso), sin H2 ni bases compartidas.</p>
 */
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Testcontainers(disabledWithoutDocker = true)
class LocalUserRepositoryPostgresIntegrationTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("circleguard_auth")
            .withUsername("circleguard")
            .withPassword("circleguard-test");

    @DynamicPropertySource
    static void postgresProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        registry.add("spring.datasource.driver-class-name", () -> "org.postgresql.Driver");
        registry.add("spring.jpa.database-platform", () -> "org.hibernate.dialect.PostgreSQLDialect");
        // El esquema lo construye Flyway (como en producción), no Hibernate.
        registry.add("spring.jpa.hibernate.ddl-auto", () -> "none");
        registry.add("spring.flyway.enabled", () -> "true");
    }

    @Autowired
    private LocalUserRepository repository;

    @Autowired
    private JdbcTemplate jdbcTemplate;

    @Test
    @DisplayName("Flyway aplica todas las migraciones de auth-service sobre PostgreSQL")
    void flywayAppliesAllMigrations() {
        Integer applied = jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM flyway_schema_history WHERE success = true", Integer.class);
        Integer failed = jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM flyway_schema_history WHERE success = false", Integer.class);

        assertThat(applied).isGreaterThanOrEqualTo(6);
        assertThat(failed).isZero();
    }

    @Test
    @DisplayName("findByUsername devuelve el usuario sembrado por las migraciones")
    void findByUsernameReturnsSeededUser() {
        assertThat(repository.findByUsername("staff_guard"))
                .isPresent()
                .get()
                .extracting(LocalUser::getUsername)
                .isEqualTo("staff_guard");
    }

    @Test
    @DisplayName("findByUsername devuelve vacío para un usuario inexistente")
    void findByUsernameReturnsEmptyForUnknownUser() {
        assertThat(repository.findByUsername("no-existe")).isEmpty();
    }

    @Test
    @DisplayName("findUsersByPermissionName resuelve usuarios -> roles -> permisos (identity:lookup)")
    void findUsersByPermissionNameResolvesRbacJoins() {
        List<LocalUser> lookups = repository.findUsersByPermissionName("identity:lookup");

        assertThat(lookups)
                .extracting(LocalUser::getUsername)
                .contains("health_user", "super_admin")
                .doesNotContain("staff_guard");
    }

    @Test
    @DisplayName("El personal de portería (GATE_STAFF) tiene permiso gate:scan para validar QR")
    void gateStaffCanScanQrCodes() {
        List<LocalUser> scanners = repository.findUsersByPermissionName("gate:scan");

        assertThat(scanners)
                .extracting(LocalUser::getUsername)
                .contains("staff_guard")
                .doesNotContain("health_user");
    }

    @Test
    @DisplayName("La restricción UNIQUE de username se cumple en PostgreSQL")
    void usernameIsUniqueAtDatabaseLevel() {
        Integer duplicates = jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM (SELECT username FROM local_users GROUP BY username HAVING COUNT(*) > 1) d",
                Integer.class);

        assertThat(duplicates).isZero();
        assertThat(repository.count()).isGreaterThanOrEqualTo(3);
    }
}
