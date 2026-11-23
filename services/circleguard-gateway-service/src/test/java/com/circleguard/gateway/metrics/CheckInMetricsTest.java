package com.circleguard.gateway.metrics;

import com.circleguard.gateway.service.QrValidationService;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.SignatureAlgorithm;
import io.jsonwebtoken.security.Keys;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.test.util.ReflectionTestUtils;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** US-41: cada validación de QR suma un check-in con su resultado. */
class CheckInMetricsTest {

    private static final String SECRET = "my-super-secret-test-key-32-chars-long";

    private SimpleMeterRegistry registry;
    private ValueOperations<String, String> valueOps;
    private QrValidationService service;

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        registry = new SimpleMeterRegistry();
        StringRedisTemplate redis = Mockito.mock(StringRedisTemplate.class);
        valueOps = Mockito.mock(ValueOperations.class);
        Mockito.when(redis.opsForValue()).thenReturn(valueOps);
        service = new QrValidationService(redis, new CheckInMetrics(registry));
        ReflectionTestUtils.setField(service, "qrSecret", SECRET);
    }

    private String token(String subject) {
        return Jwts.builder().setSubject(subject)
                .signWith(Keys.hmacShaKeyFor(SECRET.getBytes()), SignatureAlgorithm.HS256).compact();
    }

    private double checkins(String result) {
        return registry.get("circleguard.checkins").tag("result", result).counter().count();
    }

    @Test
    void countsGrantedDeniedAndInvalidCheckIns() {
        Mockito.when(valueOps.get("user:status:ok")).thenReturn("ACTIVE");
        Mockito.when(valueOps.get("user:status:risk")).thenReturn("CONTAGIED");

        service.validateToken(token("ok"));
        service.validateToken(token("ok"));
        service.validateToken(token("risk"));
        service.validateToken("not-a-jwt");

        assertEquals(2.0, checkins(CheckInMetrics.RESULT_GRANTED));
        assertEquals(1.0, checkins(CheckInMetrics.RESULT_DENIED));
        assertEquals(1.0, checkins(CheckInMetrics.RESULT_INVALID));
    }
}
