package com.circleguard.promotion.service;

import com.circleguard.promotion.model.AccessPoint;
import com.circleguard.promotion.model.Building;
import com.circleguard.promotion.model.Floor;
import com.circleguard.promotion.repository.graph.UserNodeRepository;
import com.circleguard.promotion.repository.jpa.AccessPointRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Answers;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.neo4j.core.Neo4jClient;
import org.springframework.data.redis.core.SetOperations;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.kafka.core.KafkaTemplate;

import java.time.Duration;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class LocationAndGraphServiceTest {

    @Mock
    private AccessPointRepository accessPointRepository;
    @Mock
    private MacSessionRegistry sessionRegistry;
    @Mock
    private GraphService graphService;
    @Mock
    private KafkaTemplate<String, Object> kafkaTemplate;
    @Mock
    private StringRedisTemplate redisTemplate;
    @Mock
    private SetOperations<String, String> setOps;
    @Mock
    private ValueOperations<String, String> valueOps;

    private LocationResolutionService locationService() {
        return new LocationResolutionService(accessPointRepository, sessionRegistry, graphService, kafkaTemplate, redisTemplate);
    }

    private AccessPoint accessPoint() {
        Building building = Building.builder().id(UUID.randomUUID()).build();
        Floor floor = Floor.builder().id(UUID.randomUUID()).floorNumber(3).building(building).build();
        return AccessPoint.builder().id(UUID.randomUUID()).macAddress("ap").name("Lab AP")
                .coordinateX(1.0).coordinateY(2.0).floor(floor).build();
    }

    @Test
    @SuppressWarnings("unchecked")
    void processSignal_publishesProximityAndRecordsEncountersWithOthers() {
        AccessPoint ap = accessPoint();
        String location = ap.getId().toString();
        when(accessPointRepository.findByMacAddress("ap")).thenReturn(Optional.of(ap));
        when(sessionRegistry.getAnonymousId("dev")).thenReturn("me");
        when(redisTemplate.opsForSet()).thenReturn(setOps);
        when(setOps.members("spatial:location:" + location)).thenReturn(Set.of("me", "other"));

        locationService().processSignal("ap", "dev", -55.0);

        verify(kafkaTemplate).send(eq("proximity.detected"), eq("me"), argThat(e -> {
            Map<String, Object> event = (Map<String, Object>) e;
            return "me".equals(event.get("anonymousId"))
                    && ap.getFloor().getId().equals(event.get("floorId"))
                    && Double.valueOf(-55.0).equals(event.get("rssi"));
        }));
        verify(graphService).recordEncounter("me", "other", location);
        verify(graphService, never()).recordEncounter("me", "me", location);
        verify(setOps).add("spatial:location:" + location, "me");
        verify(redisTemplate).expire("spatial:location:" + location, Duration.ofMinutes(10));
        verify(graphService).detectAndFormCircles(location);
    }

    @Test
    void processSignal_withNoOtherUsers_stillTriggersDetection() {
        AccessPoint ap = accessPoint();
        when(accessPointRepository.findByMacAddress("ap")).thenReturn(Optional.of(ap));
        when(sessionRegistry.getAnonymousId("dev")).thenReturn("me");
        when(redisTemplate.opsForSet()).thenReturn(setOps);
        when(setOps.members(anyString())).thenReturn(null);

        locationService().processSignal("ap", "dev", -70.0);

        verify(graphService, never()).recordEncounter(anyString(), anyString(), anyString());
        verify(graphService).detectAndFormCircles(ap.getId().toString());
    }

    @Test
    void processSignal_ignoresUnknownApAndUnmappedDevices() {
        when(accessPointRepository.findByMacAddress("unknown")).thenReturn(Optional.empty());
        when(accessPointRepository.findByMacAddress("ap")).thenReturn(Optional.of(accessPoint()));
        when(sessionRegistry.getAnonymousId("random-mac")).thenReturn(null);

        locationService().processSignal("unknown", "dev", -40.0);
        locationService().processSignal("ap", "random-mac", -40.0);

        verifyNoInteractions(kafkaTemplate, graphService);
    }

    @Test
    void macSessionRegistry_normalizesMacAndUsesTtl() {
        when(redisTemplate.opsForValue()).thenReturn(valueOps);
        when(valueOps.get("session:mac:aa:bb")).thenReturn("anon");
        MacSessionRegistry registry = new MacSessionRegistry(redisTemplate);

        registry.registerSession("AA:BB", "anon");
        assertThat(registry.getAnonymousId("AA:BB")).isEqualTo("anon");
        registry.closeSession("AA:BB");

        verify(valueOps).set("session:mac:aa:bb", "anon", Duration.ofHours(8));
        verify(redisTemplate).delete("session:mac:aa:bb");
    }

    @Test
    void graphService_recordsEncountersAndRunsClusterQuery() {
        UserNodeRepository userNodeRepository = mock(UserNodeRepository.class);
        Neo4jClient neo4jClient = mock(Neo4jClient.class, Answers.RETURNS_DEEP_STUBS);
        GraphService service = new GraphService(userNodeRepository, neo4jClient);

        service.recordEncounter("a", "b", "loc");
        service.detectAndFormCircles("loc");

        verify(userNodeRepository).recordEncounter(eq("a"), eq("b"), anyLong(), eq("loc"));
        verify(neo4jClient).query(contains("MERGE (c:Circle {locationId: $loc"));
    }
}
