package com.circleguard.identity.config;

import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.SignatureAlgorithm;
import io.jsonwebtoken.security.Keys;
import jakarta.servlet.FilterChain;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Date;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class JwtAuthenticationFilterTest {

    private static final String SECRET = "unit-test-secret-key-with-at-least-32-bytes";
    private final JwtAuthenticationFilter filter = new JwtAuthenticationFilter(SECRET);

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    private String token(List<String> permissions, String secret) {
        var builder = Jwts.builder().setSubject("anon-1").setIssuedAt(new Date())
                .setExpiration(new Date(System.currentTimeMillis() + 60_000));
        if (permissions != null) {
            builder.claim("permissions", permissions);
        }
        return builder.signWith(Keys.hmacShaKeyFor(secret.getBytes()), SignatureAlgorithm.HS256).compact();
    }

    private Authentication run(String header) throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest();
        if (header != null) {
            request.addHeader("Authorization", header);
        }
        MockHttpServletResponse response = new MockHttpServletResponse();
        FilterChain chain = mock(FilterChain.class);
        filter.doFilter(request, response, chain);
        verify(chain).doFilter(request, response);
        return SecurityContextHolder.getContext().getAuthentication();
    }

    @Test
    void validToken_setsAuthorities() throws Exception {
        Authentication auth = run("Bearer " + token(List.of("identity:lookup"), SECRET));

        assertThat(auth.getName()).isEqualTo("anon-1");
        assertThat(auth.getAuthorities()).extracting(GrantedAuthority::getAuthority).containsExactly("identity:lookup");
    }

    @Test
    void tokenWithoutPermissions_isNotAuthenticated() throws Exception {
        assertThat(run("Bearer " + token(null, SECRET))).isNull();
    }

    @Test
    void invalidSignatureOrMissingHeader_isIgnored() throws Exception {
        assertThat(run("Bearer " + token(List.of("x"), "another-secret-key-that-is-32-bytes-long!!"))).isNull();
        assertThat(run(null)).isNull();
        assertThat(run("Token abc")).isNull();
    }
}
