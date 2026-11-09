package com.circleguard.gateway.integration;

import com.circleguard.gateway.service.QrValidationService;
import com.circleguard.gateway.service.QrValidationService.ValidationResult;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.SignatureAlgorithm;
import io.jsonwebtoken.security.Keys;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.nio.charset.StandardCharsets;
import java.security.Key;
import java.time.Duration;
import java.util.Date;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Prueba de integración de gateway-service contra un Redis real (Testcontainers).
 *
 * <p>US-33 (SCRUM-112 / SCRUM-78) — CA2: valida la firma y la expiración del QR y
 * la consulta del estado de salud en Redis, sin dependencias compartidas.</p>
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.NONE)
@Testcontainers(disabledWithoutDocker = true)
class QrValidationRedisIntegrationTest {

    private static final String STATUS_KEY_PREFIX = "user:status:";

    @Container
    static final GenericContainer<?> REDIS =
            new GenericContainer<>(DockerImageName.parse("redis:7.2-alpine")).withExposedPorts(6379);

    @DynamicPropertySource
    static void redisProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.data.redis.host", REDIS::getHost);
        registry.add("spring.data.redis.port", () -> REDIS.getMappedPort(6379));
    }

    @Autowired
    private QrValidationService validationService;

    @Autowired
    private StringRedisTemplate redisTemplate;

    @Value("${qr.secret}")
    private String qrSecret;

    @BeforeEach
    void cleanRedis() {
        redisTemplate.getConnectionFactory().getConnection().serverCommands().flushAll();
    }

    @Test
    @DisplayName("QR firmado y vigente sin estado de riesgo en Redis -> acceso permitido")
    void validSignedTokenWithoutRiskStatusIsAccepted() {
        String anonymousId = UUID.randomUUID().toString();

        ValidationResult result = validationService.validateToken(token(anonymousId, qrSecret, Duration.ofMinutes(1)));

        assertThat(result.valid()).isTrue();
        assertThat(result.status()).isEqualTo("GREEN");
    }

    @Test
    @DisplayName("QR válido de un usuario CONTAGIED en Redis -> acceso denegado")
    void contagiedStatusStoredInRedisDeniesAccess() {
        String anonymousId = UUID.randomUUID().toString();
        redisTemplate.opsForValue().set(STATUS_KEY_PREFIX + anonymousId, "CONTAGIED");

        ValidationResult result = validationService.validateToken(token(anonymousId, qrSecret, Duration.ofMinutes(1)));

        assertThat(result.valid()).isFalse();
        assertThat(result.status()).isEqualTo("RED");
        assertThat(result.message()).contains("Health Risk");
    }

    @Test
    @DisplayName("QR válido de un usuario POTENTIAL en Redis -> acceso denegado")
    void potentialStatusStoredInRedisDeniesAccess() {
        String anonymousId = UUID.randomUUID().toString();
        redisTemplate.opsForValue().set(STATUS_KEY_PREFIX + anonymousId, "POTENTIAL");

        ValidationResult result = validationService.validateToken(token(anonymousId, qrSecret, Duration.ofMinutes(1)));

        assertThat(result.valid()).isFalse();
        assertThat(result.status()).isEqualTo("RED");
    }

    @Test
    @DisplayName("Estado de riesgo con TTL vencido en Redis -> el usuario vuelve a GREEN")
    void expiredRiskStatusInRedisAllowsAccessAgain() throws InterruptedException {
        String anonymousId = UUID.randomUUID().toString();
        redisTemplate.opsForValue().set(STATUS_KEY_PREFIX + anonymousId, "CONTAGIED", Duration.ofSeconds(1));
        Thread.sleep(1_500);

        ValidationResult result = validationService.validateToken(token(anonymousId, qrSecret, Duration.ofMinutes(1)));

        assertThat(redisTemplate.hasKey(STATUS_KEY_PREFIX + anonymousId)).isFalse();
        assertThat(result.valid()).isTrue();
        assertThat(result.status()).isEqualTo("GREEN");
    }

    @Test
    @DisplayName("QR expirado -> rechazado aunque la firma sea válida")
    void expiredTokenIsRejected() {
        String anonymousId = UUID.randomUUID().toString();

        ValidationResult result = validationService.validateToken(token(anonymousId, qrSecret, Duration.ofSeconds(-30)));

        assertThat(result.valid()).isFalse();
        assertThat(result.message()).isEqualTo("Invalid or Expired Token");
    }

    @Test
    @DisplayName("QR firmado con otra clave -> rechazado (firma inválida)")
    void tokenSignedWithAnotherKeyIsRejected() {
        String anonymousId = UUID.randomUUID().toString();
        String forged = token(anonymousId, "another-secret-key-with-at-least-32-bytes!!", Duration.ofMinutes(1));

        ValidationResult result = validationService.validateToken(forged);

        assertThat(result.valid()).isFalse();
        assertThat(result.message()).isEqualTo("Invalid or Expired Token");
    }

    @Test
    @DisplayName("QR alterado después de firmado -> rechazado")
    void tamperedTokenIsRejected() {
        String token = token(UUID.randomUUID().toString(), qrSecret, Duration.ofMinutes(1));
        String tampered = token.substring(0, token.length() - 2) + (token.endsWith("A") ? "BB" : "AA");

        ValidationResult result = validationService.validateToken(tampered);

        assertThat(result.valid()).isFalse();
    }

    private static String token(String subject, String secret, Duration validFor) {
        Key key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
        long now = System.currentTimeMillis();
        return Jwts.builder()
                .setSubject(subject)
                .setIssuedAt(new Date(now - 60_000))
                .setExpiration(new Date(now + validFor.toMillis()))
                .signWith(key, SignatureAlgorithm.HS256)
                .compact();
    }
}
