package com.circleguard.gateway.service;

import com.circleguard.gateway.metrics.CheckInMetrics;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.SignatureAlgorithm;
import io.jsonwebtoken.security.Keys;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.Date;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;

/**
 * US-32: casos borde de la validación de QR en el gateway
 * (estado POTENTIAL, usuario sin estado en Redis, token inválido, firma ajena y token expirado).
 */
class QrValidationServiceEdgeCasesTest {

    private static final String SECRET = "my-super-secret-test-key-32-chars-long";

    private QrValidationService service;
    private StringRedisTemplate redisTemplate;
    private ValueOperations<String, String> valueOps;

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        redisTemplate = Mockito.mock(StringRedisTemplate.class);
        valueOps = Mockito.mock(ValueOperations.class);
        Mockito.when(redisTemplate.opsForValue()).thenReturn(valueOps);

        service = new QrValidationService(redisTemplate, new CheckInMetrics(new SimpleMeterRegistry()));
        ReflectionTestUtils.setField(service, "qrSecret", SECRET);
    }

    private String tokenFor(String subject, String secret, Date expiration) {
        var builder = Jwts.builder().setSubject(subject);
        if (expiration != null) {
            builder.setExpiration(expiration);
        }
        return builder.signWith(Keys.hmacShaKeyFor(secret.getBytes()), SignatureAlgorithm.HS256).compact();
    }

    @Test
    void shouldDenyAccessForPotentialStatus() {
        String anonymousId = UUID.randomUUID().toString();
        Mockito.when(valueOps.get("user:status:" + anonymousId)).thenReturn("POTENTIAL");

        QrValidationService.ValidationResult result = service.validateToken(tokenFor(anonymousId, SECRET, null));

        assertFalse(result.valid());
        assertEquals("RED", result.status());
        assertEquals("Access Denied: Health Risk Detected", result.message());
    }

    @Test
    void shouldAllowAccessWhenUserHasNoStatusInRedis() {
        String anonymousId = UUID.randomUUID().toString();
        Mockito.when(valueOps.get(anyString())).thenReturn(null);

        QrValidationService.ValidationResult result = service.validateToken(tokenFor(anonymousId, SECRET, null));

        assertTrue(result.valid());
        assertEquals("GREEN", result.status());
        assertEquals("Welcome to Campus", result.message());
        Mockito.verify(valueOps).get("user:status:" + anonymousId);
    }

    @Test
    void shouldRejectMalformedToken() {
        QrValidationService.ValidationResult result = service.validateToken("not-a-jwt");

        assertFalse(result.valid());
        assertEquals("RED", result.status());
        assertEquals("Invalid or Expired Token", result.message());
        Mockito.verifyNoInteractions(valueOps);
    }

    @Test
    void shouldRejectNullToken() {
        QrValidationService.ValidationResult result = service.validateToken(null);

        assertFalse(result.valid());
        assertEquals("Invalid or Expired Token", result.message());
    }

    @Test
    void shouldRejectTokenSignedWithAnotherSecret() {
        String token = tokenFor(UUID.randomUUID().toString(), "another-secret-key-that-is-32-chars-long!!", null);

        QrValidationService.ValidationResult result = service.validateToken(token);

        assertFalse(result.valid());
        assertEquals("Invalid or Expired Token", result.message());
        Mockito.verifyNoInteractions(valueOps);
    }

    @Test
    void shouldRejectExpiredToken() {
        String token = tokenFor(UUID.randomUUID().toString(), SECRET, new Date(System.currentTimeMillis() - 60_000));

        QrValidationService.ValidationResult result = service.validateToken(token);

        assertFalse(result.valid());
        assertEquals("Invalid or Expired Token", result.message());
    }

    @Test
    void shouldTreatRedisFailureAsInvalidToken() {
        String anonymousId = UUID.randomUUID().toString();
        Mockito.when(valueOps.get(anyString())).thenThrow(new RuntimeException("Redis down"));

        QrValidationService.ValidationResult result = service.validateToken(tokenFor(anonymousId, SECRET, null));

        assertFalse(result.valid());
        assertEquals("RED", result.status());
    }
}
