package com.circleguard.auth.client;

import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.retry.Retry;
import io.github.resilience4j.retry.RetryRegistry;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.HttpServerErrorException;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestTemplate;

import java.time.Duration;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

/**
 * Cliente de identity-service usado en el login.
 * US-23 (SCRUM-92): la llamada tiene timeouts, Retry con backoff exponencial y
 * Circuit Breaker de Resilience4j. Los parámetros vienen de application.yml y se
 * pueden cambiar por ambiente con variables de entorno.
 */
@Component
public class IdentityClient {

    static final String RESILIENCE_INSTANCE = "identityService";
    private static final String MAP_PATH = "/api/v1/identities/map";

    private final RestTemplate restTemplate;
    private final String identityMapUrl;
    private final Retry retry;
    private final CircuitBreaker circuitBreaker;

    @Autowired
    public IdentityClient(@Value("${identity.service.url:http://localhost:8083}") String identityServiceUrl,
                          @Value("${identity.service.connect-timeout:1s}") Duration connectTimeout,
                          @Value("${identity.service.read-timeout:2s}") Duration readTimeout,
                          RetryRegistry retryRegistry,
                          CircuitBreakerRegistry circuitBreakerRegistry) {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout((int) connectTimeout.toMillis());
        requestFactory.setReadTimeout((int) readTimeout.toMillis());
        this.restTemplate = new RestTemplate(requestFactory);
        this.identityMapUrl = identityServiceUrl.replaceAll("/+$", "") + MAP_PATH;
        this.retry = retryRegistry.retry(RESILIENCE_INSTANCE);
        this.circuitBreaker = circuitBreakerRegistry.circuitBreaker(RESILIENCE_INSTANCE);
    }

    /** Constructor con la configuración por defecto de Resilience4j, para pruebas. */
    public IdentityClient(String identityServiceUrl) {
        this(identityServiceUrl, Duration.ofSeconds(1), Duration.ofSeconds(2),
                RetryRegistry.ofDefaults(), CircuitBreakerRegistry.ofDefaults());
    }

    public UUID getAnonymousId(String realIdentity) {
        Map<String, String> request = Map.of("realIdentity", realIdentity);
        Supplier<Map> call = () -> restTemplate.postForObject(identityMapUrl, request, Map.class);
        // Retry por fuera del Circuit Breaker: cada intento cuenta para el breaker y,
        // si el breaker está abierto, no se insiste contra un servicio caído.
        Supplier<Map> resilientCall = Retry.decorateSupplier(retry,
                CircuitBreaker.decorateSupplier(circuitBreaker, call));
        try {
            Map response = resilientCall.get();
            return UUID.fromString(response.get("anonymousId").toString());
        } catch (CallNotPermittedException | ResourceAccessException | HttpServerErrorException e) {
            throw new IdentityServiceUnavailableException(e);
        }
    }
}
