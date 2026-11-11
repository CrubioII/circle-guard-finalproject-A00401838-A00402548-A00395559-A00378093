package com.circleguard.auth.security;

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

    private String token(String subject, List<String> permissions, String secret) {
        var builder = Jwts.builder().setSubject(subject).setIssuedAt(new Date())
                .setExpiration(new Date(System.currentTimeMillis() + 60_000));
        if (permissions != null) {
            builder.claim("permissions", permissions);
        }
        return builder.signWith(Keys.hmacShaKeyFor(secret.getBytes()), SignatureAlgorithm.HS256).compact();
    }

    private Authentication run(String authorizationHeader) throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest();
        if (authorizationHeader != null) {
            request.addHeader("Authorization", authorizationHeader);
        }
        FilterChain chain = mock(FilterChain.class);
        MockHttpServletResponse response = new MockHttpServletResponse();
        filter.doFilter(request, response, chain);
        verify(chain).doFilter(request, response);
        return SecurityContextHolder.getContext().getAuthentication();
    }

    @Test
    void validToken_populatesSecurityContextWithPermissions() throws Exception {
        Authentication auth = run("Bearer " + token("anon-1", List.of("identity:lookup"), SECRET));

        assertThat(auth).isNotNull();
        assertThat(auth.getName()).isEqualTo("anon-1");
        assertThat(auth.getAuthorities()).extracting(GrantedAuthority::getAuthority).containsExactly("identity:lookup");
    }

    @Test
    void tokenWithoutPermissions_authenticatesWithNoAuthorities() throws Exception {
        Authentication auth = run("Bearer " + token("anon-2", null, SECRET));

        assertThat(auth).isNotNull();
        assertThat(auth.getAuthorities()).isEmpty();
    }

    @Test
    void tokenSignedWithOtherKey_leavesContextEmpty() throws Exception {
        Authentication auth = run("Bearer " + token("anon-3", List.of(), "another-secret-key-that-is-32-bytes-long!!"));

        assertThat(auth).isNull();
    }

    @Test
    void missingOrNonBearerHeader_isIgnored() throws Exception {
        assertThat(run(null)).isNull();
        assertThat(run("Basic dXNlcjpwYXNz")).isNull();
    }
}
