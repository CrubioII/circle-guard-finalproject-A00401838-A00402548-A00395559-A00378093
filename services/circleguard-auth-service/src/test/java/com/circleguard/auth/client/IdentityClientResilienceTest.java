package com.circleguard.auth.client;

import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.retry.RetryConfig;
import io.github.resilience4j.retry.RetryRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.HttpServerErrorException;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestTemplate;

import java.time.Duration;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.ExpectedCount.never;
import static org.springframework.test.web.client.ExpectedCount.once;
import static org.springframework.test.web.client.ExpectedCount.times;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

/**
 * US-23 (SCRUM-92): Retry y Circuit Breaker en auth -> identity, con la misma
 * configuración que application.yml pero sin esperas largas.
 */
class IdentityClientResilienceTest {

    private static final String URL = "http://identity:8083/api/v1/identities/map";

    private CircuitBreakerRegistry circuitBreakerRegistry;
    private IdentityClient client;
    private MockRestServiceServer server;

    @BeforeEach
    void setUp() {
        RetryRegistry retryRegistry = RetryRegistry.of(RetryConfig.custom()
                .maxAttempts(3)
                .waitDuration(Duration.ofMillis(1))
                .retryExceptions(ResourceAccessException.class, HttpServerErrorException.class)
                .build());
        circuitBreakerRegistry = CircuitBreakerRegistry.of(CircuitBreakerConfig.custom()
                .slidingWindowSize(4)
                .minimumNumberOfCalls(4)
                .failureRateThreshold(50)
                .waitDurationInOpenState(Duration.ofMinutes(1))
                .recordExceptions(ResourceAccessException.class, HttpServerErrorException.class)
                .build());
        client = new IdentityClient("http://identity:8083", Duration.ofSeconds(1), Duration.ofSeconds(2),
                retryRegistry, circuitBreakerRegistry);
        RestTemplate restTemplate = (RestTemplate) ReflectionTestUtils.getField(client, "restTemplate");
        server = MockRestServiceServer.bindTo(restTemplate).build();
    }

    @Test
    void retriesTransientServerErrorAndSucceeds() {
        UUID anonymousId = UUID.randomUUID();
        server.expect(once(), requestTo(URL)).andExpect(method(HttpMethod.POST)).andRespond(withServerError());
        server.expect(once(), requestTo(URL)).andRespond(
                withSuccess("{\"anonymousId\":\"" + anonymousId + "\"}", MediaType.APPLICATION_JSON));

        assertThat(client.getAnonymousId("jdoe")).isEqualTo(anonymousId);
        server.verify();
    }

    @Test
    void doesNotRetryClientErrors() {
        server.expect(once(), requestTo(URL)).andRespond(withStatus(org.springframework.http.HttpStatus.BAD_REQUEST));

        assertThatThrownBy(() -> client.getAnonymousId("jdoe")).isInstanceOf(HttpClientErrorException.class);
        server.verify();
        assertThat(breaker().getMetrics().getNumberOfFailedCalls()).isZero();
    }

    @Test
    void givesUpAfterMaxAttemptsWithUnavailableException() {
        server.expect(times(3), requestTo(URL)).andRespond(withServerError());

        assertThatThrownBy(() -> client.getAnonymousId("jdoe"))
                .isInstanceOf(IdentityServiceUnavailableException.class)
                .hasCauseInstanceOf(HttpServerErrorException.class);
        server.verify();
    }

    @Test
    void opensCircuitAndStopsCallingIdentityService() {
        // 2 logins fallidos x 3 intentos = 4 fallos en la ventana -> el breaker se abre
        server.expect(times(4), requestTo(URL)).andRespond(withServerError());
        server.expect(never(), requestTo(URL));

        assertThatThrownBy(() -> client.getAnonymousId("a")).isInstanceOf(IdentityServiceUnavailableException.class);
        assertThatThrownBy(() -> client.getAnonymousId("b")).isInstanceOf(IdentityServiceUnavailableException.class);
        assertThat(breaker().getState()).isEqualTo(CircuitBreaker.State.OPEN);

        // Con el breaker abierto falla rápido, sin llamar a identity-service
        assertThatThrownBy(() -> client.getAnonymousId("c")).isInstanceOf(IdentityServiceUnavailableException.class);
        server.verify();
    }

    private CircuitBreaker breaker() {
        return circuitBreakerRegistry.circuitBreaker(IdentityClient.RESILIENCE_INSTANCE);
    }
}
