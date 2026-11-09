package com.circleguard.auth.client;

import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestTemplate;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.*;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

class IdentityClientTest {

    @Test
    void getAnonymousId_postsRealIdentityAndParsesResponse() {
        IdentityClient client = new IdentityClient("http://identity:8083//");
        RestTemplate restTemplate = (RestTemplate) ReflectionTestUtils.getField(client, "restTemplate");
        MockRestServiceServer server = MockRestServiceServer.bindTo(restTemplate).build();
        UUID anonymousId = UUID.randomUUID();

        server.expect(requestTo("http://identity:8083/api/v1/identities/map"))
                .andExpect(method(HttpMethod.POST))
                .andExpect(jsonPath("$.realIdentity").value("jdoe"))
                .andRespond(withSuccess("{\"anonymousId\":\"" + anonymousId + "\"}", MediaType.APPLICATION_JSON));

        assertThat(client.getAnonymousId("jdoe")).isEqualTo(anonymousId);
        server.verify();
    }
}
