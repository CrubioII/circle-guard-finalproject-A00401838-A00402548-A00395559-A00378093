package com.circleguard.notification.service;

import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.web.reactive.function.client.ClientRequest;
import org.springframework.web.reactive.function.client.ClientResponse;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Mono;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * US-32: canal push (Gotify) con WebClient simulado.
 */
class PushServiceImplTest {

    private final AuditLogService auditLogService = mock(AuditLogService.class);
    private final List<ClientRequest> requests = new ArrayList<>();

    private PushServiceImpl serviceRespondingWith(HttpStatus status, String token) {
        WebClient.Builder builder = WebClient.builder().exchangeFunction(request -> {
            requests.add(request);
            return Mono.just(ClientResponse.create(status).build());
        });
        PushServiceImpl service = new PushServiceImpl(builder, "http://gotify.test");
        ReflectionTestUtils.setField(service, "gotifyToken", token);
        ReflectionTestUtils.setField(service, "auditLogService", auditLogService);
        return service;
    }

    @Test
    void mockTokenAuditsSuccessWithoutHttpCall() {
        PushServiceImpl service = serviceRespondingWith(HttpStatus.OK, "MOCK_TOKEN");

        CompletableFuture<Void> future = service.sendAsync("anon-1", "hello");

        assertFalse(future.isCompletedExceptionally());
        assertTrue(requests.isEmpty());
        verify(auditLogService).logDelivery(eq("anon-1"), eq("PUSH"), eq("SUCCESS"), anyString());
    }

    @Test
    void realTokenPostsMessageToGotify() {
        PushServiceImpl service = serviceRespondingWith(HttpStatus.OK, "real-token");

        CompletableFuture<Void> future = service.sendAsync("anon-1", "isolate", Map.of("url", "circleguard://guidelines"));

        assertFalse(future.isCompletedExceptionally());
        assertEquals(1, requests.size());
        ClientRequest request = requests.get(0);
        assertEquals("POST", request.method().name());
        assertEquals("http://gotify.test/message?token=real-token", request.url().toString());
        verify(auditLogService).logDelivery(eq("anon-1"), eq("PUSH"), eq("SUCCESS"), anyString());
    }

    @Test
    void realTokenWithoutMetadataStillSends() {
        PushServiceImpl service = serviceRespondingWith(HttpStatus.OK, "real-token");

        service.sendAsync("anon-1", "update", Map.of());

        assertEquals(1, requests.size());
    }

    @Test
    void serverErrorAuditsRetryAndRethrows() {
        PushServiceImpl service = serviceRespondingWith(HttpStatus.INTERNAL_SERVER_ERROR, "real-token");

        assertThrows(RuntimeException.class, () -> service.sendAsync("anon-1", "msg", Map.of()));
        verify(auditLogService).logDelivery(eq("anon-1"), eq("PUSH"), eq("RETRY"), anyString());
    }

    @Test
    void recoverAuditsFailure() {
        PushServiceImpl service = serviceRespondingWith(HttpStatus.OK, "real-token");

        CompletableFuture<Void> future = service.recover(new RuntimeException("x"), "anon-1", "msg", Map.of());

        assertTrue(future.isCompletedExceptionally());
        verify(auditLogService).logDelivery("anon-1", "PUSH", "FAILED", null);
    }
}
