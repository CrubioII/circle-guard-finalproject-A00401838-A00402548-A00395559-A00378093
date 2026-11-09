package com.circleguard.auth.service;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class QrTokenServiceTest {

    private static final String SECRET = "unit-test-qr-secret-key-with-32-bytes-min";

    @Test
    void generateQrToken_isSignedAndShortLived() {
        QrTokenService service = new QrTokenService(SECRET, 60_000);
        UUID anonymousId = UUID.randomUUID();

        String token = service.generateQrToken(anonymousId);

        Claims claims = Jwts.parserBuilder()
                .setSigningKey(Keys.hmacShaKeyFor(SECRET.getBytes()))
                .build()
                .parseClaimsJws(token)
                .getBody();
        assertThat(claims.getSubject()).isEqualTo(anonymousId.toString());
        long ttl = claims.getExpiration().getTime() - claims.getIssuedAt().getTime();
        assertThat(ttl).isBetween(59_000L, 61_000L);
    }
}
