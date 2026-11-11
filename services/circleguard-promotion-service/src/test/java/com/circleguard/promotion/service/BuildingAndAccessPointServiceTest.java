package com.circleguard.promotion.service;

import com.circleguard.promotion.model.AccessPoint;
import com.circleguard.promotion.model.Building;
import com.circleguard.promotion.model.Floor;
import com.circleguard.promotion.repository.jpa.AccessPointRepository;
import com.circleguard.promotion.repository.jpa.BuildingRepository;
import com.circleguard.promotion.repository.jpa.FloorRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class BuildingAndAccessPointServiceTest {

    @Mock
    private BuildingRepository buildingRepository;
    @Mock
    private FloorRepository floorRepository;
    @Mock
    private AccessPointRepository accessPointRepository;

    private BuildingService buildingService;
    private AccessPointService accessPointService;
    private FloorService floorService;

    @BeforeEach
    void setUp() {
        buildingService = new BuildingService(buildingRepository, floorRepository);
        accessPointService = new AccessPointService(accessPointRepository, floorRepository);
        floorService = new FloorService(buildingRepository, floorRepository, accessPointRepository);
        lenient().when(buildingRepository.save(any(Building.class))).thenAnswer(i -> i.getArgument(0));
        lenient().when(floorRepository.save(any(Floor.class))).thenAnswer(i -> i.getArgument(0));
        lenient().when(accessPointRepository.save(any(AccessPoint.class))).thenAnswer(i -> i.getArgument(0));
    }

    @Test
    void buildingService_createUpdateListAndDelete() {
        UUID id = UUID.randomUUID();
        Building b = buildingService.createBuilding("Eng", "ENG", "Engineering", 3.4, -76.5, "Calle 18");
        assertThat(b.getLatitude()).isEqualTo(3.4);
        assertThat(b.getAddress()).isEqualTo("Calle 18");

        when(buildingRepository.findById(id)).thenReturn(Optional.of(b));
        Building u = buildingService.updateBuilding(id, "Eng 2", "ENG2", "New", 3.5, -76.6, "Calle 19");
        assertThat(u.getName()).isEqualTo("Eng 2");
        assertThat(u.getLongitude()).isEqualTo(-76.6);

        when(buildingRepository.findAll()).thenReturn(List.of(b));
        assertThat(buildingService.getAllBuildings()).hasSize(1);

        when(floorRepository.findByBuildingId(id)).thenReturn(List.of());
        buildingService.deleteBuilding(id);
        verify(buildingRepository).deleteById(id);
    }

    @Test
    void buildingService_errors() {
        UUID id = UUID.randomUUID();
        when(buildingRepository.findById(id)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> buildingService.updateBuilding(id, "n", "c", "d", 0.0, 0.0, "a"))
                .hasMessage("Building not found");
        when(floorRepository.findByBuildingId(id)).thenReturn(List.of(new Floor()));
        assertThatThrownBy(() -> buildingService.deleteBuilding(id)).hasMessageContaining("existing floors");
    }

    @Test
    void accessPointService_fullLifecycle() {
        UUID floorId = UUID.randomUUID();
        UUID apId = UUID.randomUUID();
        Floor floor = Floor.builder().id(floorId).floorNumber(1).build();
        when(floorRepository.findById(floorId)).thenReturn(Optional.of(floor));

        AccessPoint ap = accessPointService.registerAccessPoint(floorId, "AA", 1.0, 2.0, "AP-1");
        assertThat(ap.getFloor()).isSameAs(floor);

        when(accessPointRepository.findById(apId)).thenReturn(Optional.of(ap));
        assertThat(accessPointService.getAccessPoint(apId)).contains(ap);
        when(accessPointRepository.findByFloorId(floorId)).thenReturn(List.of(ap));
        assertThat(accessPointService.getAccessPointsByFloor(floorId)).containsExactly(ap);

        AccessPoint updated = accessPointService.updateAccessPoint(apId, "BB", 5.0, 6.0, "AP-2");
        assertThat(updated.getMacAddress()).isEqualTo("BB");
        assertThat(updated.getCoordinateX()).isEqualTo(5.0);

        accessPointService.deleteAccessPoint(apId);
        verify(accessPointRepository).deleteById(apId);
    }

    @Test
    void accessPointService_errors() {
        UUID id = UUID.randomUUID();
        when(floorRepository.findById(id)).thenReturn(Optional.empty());
        when(accessPointRepository.findById(id)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> accessPointService.registerAccessPoint(id, "m", 0.0, 0.0, "n")).hasMessage("Floor not found");
        assertThatThrownBy(() -> accessPointService.updateAccessPoint(id, "m", 0.0, 0.0, "n")).hasMessage("Access Point not found");
    }

    @Test
    void floorService_addListUpdateAndDelete() {
        UUID buildingId = UUID.randomUUID();
        UUID floorId = UUID.randomUUID();
        Building building = Building.builder().id(buildingId).build();
        when(buildingRepository.findById(buildingId)).thenReturn(Optional.of(building));

        Floor floor = floorService.addFloor(buildingId, 1, "Ground");
        assertThat(floor.getBuilding()).isSameAs(building);

        when(floorRepository.findByBuildingId(buildingId)).thenReturn(List.of(floor));
        assertThat(floorService.getFloorsByBuilding(buildingId)).containsExactly(floor);

        when(floorRepository.findById(floorId)).thenReturn(Optional.of(floor));
        Floor updated = floorService.updateFloor(floorId, 5, "Fifth", null);
        assertThat(updated.getFloorNumber()).isEqualTo(5);
        assertThat(updated.getName()).isEqualTo("Fifth");

        when(accessPointRepository.findByFloorId(floorId)).thenReturn(List.of());
        floorService.deleteFloor(floorId);
        verify(floorRepository).deleteById(floorId);
    }

    @Test
    void floorService_errors() {
        UUID id = UUID.randomUUID();
        when(buildingRepository.findById(id)).thenReturn(Optional.empty());
        when(floorRepository.findById(id)).thenReturn(Optional.empty());
        when(accessPointRepository.findByFloorId(id)).thenReturn(List.of(new AccessPoint()));
        assertThatThrownBy(() -> floorService.addFloor(id, 1, "x")).hasMessage("Building not found");
        assertThatThrownBy(() -> floorService.updateFloor(id, 1, "x", null)).hasMessage("Floor not found");
        assertThatThrownBy(() -> floorService.deleteFloor(id)).hasMessageContaining("existing access points");
    }
}
