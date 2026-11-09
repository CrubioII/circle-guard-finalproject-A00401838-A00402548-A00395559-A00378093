package com.circleguard.auth.service;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class JwtTokenServiceTest {

    private static final String SECRET = "unit-test-secret-key-with-at-least-32-bytes";

    @Test
    void generateToken_includesSubjectPermissionsAndExpiration() {
        JwtTokenService service = new JwtTokenService(SECRET, 60_000);
        UUID anonymousId = UUID.randomUUID();
        var auth = new UsernamePasswordAuthenticationToken("user", null,
                List.of(new SimpleGrantedAuthority("ROLE_STUDENT"), new SimpleGrantedAuthority("identity:lookup")));

        String token = service.generateToken(anonymousId, auth);

        Claims claims = Jwts.parserBuilder()
                .setSigningKey(Keys.hmacShaKeyFor(SECRET.getBytes()))
                .build()
                .parseClaimsJws(token)
                .getBody();
        assertThat(claims.getSubject()).isEqualTo(anonymousId.toString());
        assertThat(claims.get("permissions", List.class)).containsExactlyInAnyOrder("ROLE_STUDENT", "identity:lookup");
        assertThat(claims.getExpiration()).isAfter(claims.getIssuedAt());
    }
}
