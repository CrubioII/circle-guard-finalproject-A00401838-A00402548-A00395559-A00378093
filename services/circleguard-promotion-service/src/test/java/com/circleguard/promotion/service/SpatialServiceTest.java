package com.circleguard.promotion.service;

import com.circleguard.promotion.model.AccessPoint;
import com.circleguard.promotion.model.Building;
import com.circleguard.promotion.model.Floor;
import com.circleguard.promotion.repository.jpa.AccessPointRepository;
import com.circleguard.promotion.repository.jpa.BuildingRepository;
import com.circleguard.promotion.repository.jpa.FloorRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
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
class SpatialServiceTest {

    @Mock
    private BuildingRepository buildingRepository;
    @Mock
    private FloorRepository floorRepository;
    @Mock
    private AccessPointRepository accessPointRepository;
    @InjectMocks
    private SpatialService service;

    private void echoSaves() {
        lenient().when(buildingRepository.save(any(Building.class))).thenAnswer(i -> i.getArgument(0));
        lenient().when(floorRepository.save(any(Floor.class))).thenAnswer(i -> i.getArgument(0));
        lenient().when(accessPointRepository.save(any(AccessPoint.class))).thenAnswer(i -> i.getArgument(0));
    }

    @Test
    void buildingLifecycle() {
        echoSaves();
        UUID id = UUID.randomUUID();
        Building created = service.createBuilding("Library", "LIB", "Main library");
        assertThat(created.getCode()).isEqualTo("LIB");

        when(buildingRepository.findById(id)).thenReturn(Optional.of(created));
        Building updated = service.updateBuilding(id, "Library 2", "LIB2", "Renovated");
        assertThat(updated.getName()).isEqualTo("Library 2");
        assertThat(updated.getDescription()).isEqualTo("Renovated");

        when(buildingRepository.findAll()).thenReturn(List.of(created));
        assertThat(service.getAllBuildings()).containsExactly(created);

        when(floorRepository.findByBuildingId(id)).thenReturn(List.of());
        service.deleteBuilding(id);
        verify(buildingRepository).deleteById(id);
    }

    @Test
    void buildingErrors() {
        UUID id = UUID.randomUUID();
        when(buildingRepository.findById(id)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.updateBuilding(id, "n", "c", "d")).hasMessage("Building not found");
        assertThatThrownBy(() -> service.addFloor(id, 1, "L1")).hasMessage("Building not found");

        when(floorRepository.findByBuildingId(id)).thenReturn(List.of(new Floor()));
        assertThatThrownBy(() -> service.deleteBuilding(id)).hasMessageContaining("existing floors");
        verify(buildingRepository, never()).deleteById(id);
    }

    @Test
    void floorLifecycle() {
        echoSaves();
        UUID buildingId = UUID.randomUUID();
        UUID floorId = UUID.randomUUID();
        Building building = Building.builder().id(buildingId).name("B").code("B").build();
        when(buildingRepository.findById(buildingId)).thenReturn(Optional.of(building));

        Floor floor = service.addFloor(buildingId, 2, "Second");
        assertThat(floor.getBuilding()).isSameAs(building);
        assertThat(floor.getFloorNumber()).isEqualTo(2);

        when(floorRepository.findByBuildingId(buildingId)).thenReturn(List.of(floor));
        assertThat(service.getFloorsByBuilding(buildingId)).containsExactly(floor);

        when(floorRepository.findById(floorId)).thenReturn(Optional.of(floor));
        Floor updated = service.updateFloor(floorId, 3, "Third");
        assertThat(updated.getFloorNumber()).isEqualTo(3);
        assertThat(updated.getName()).isEqualTo("Third");

        when(accessPointRepository.findByFloorId(floorId)).thenReturn(List.of());
        service.deleteFloor(floorId);
        verify(floorRepository).deleteById(floorId);
    }

    @Test
    void floorErrors() {
        UUID floorId = UUID.randomUUID();
        when(floorRepository.findById(floorId)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.updateFloor(floorId, 1, "x")).hasMessage("Floor not found");
        assertThatThrownBy(() -> service.registerAccessPoint(floorId, "aa", 1.0, 2.0, "AP")).hasMessage("Floor not found");

        when(accessPointRepository.findByFloorId(floorId)).thenReturn(List.of(new AccessPoint()));
        assertThatThrownBy(() -> service.deleteFloor(floorId)).hasMessageContaining("existing access points");
    }

    @Test
    void accessPointLifecycle() {
        echoSaves();
        UUID floorId = UUID.randomUUID();
        UUID apId = UUID.randomUUID();
        Floor floor = Floor.builder().id(floorId).floorNumber(1).build();
        when(floorRepository.findById(floorId)).thenReturn(Optional.of(floor));

        AccessPoint ap = service.registerAccessPoint(floorId, "AA:BB", 1.5, 2.5, "Lobby");
        assertThat(ap.getFloor()).isSameAs(floor);
        assertThat(ap.getCoordinateX()).isEqualTo(1.5);

        when(accessPointRepository.findById(apId)).thenReturn(Optional.of(ap));
        assertThat(service.getAccessPoint(apId)).contains(ap);
        when(accessPointRepository.findByFloorId(floorId)).thenReturn(List.of(ap));
        assertThat(service.getAccessPointsByFloor(floorId)).containsExactly(ap);

        AccessPoint updated = service.updateAccessPoint(apId, "CC:DD", 3.0, 4.0, "Hall");
        assertThat(updated.getMacAddress()).isEqualTo("CC:DD");
        assertThat(updated.getCoordinateY()).isEqualTo(4.0);
        assertThat(updated.getName()).isEqualTo("Hall");

        service.deleteAccessPoint(apId);
        verify(accessPointRepository).deleteById(apId);
    }

    @Test
    void updateUnknownAccessPoint_throws() {
        UUID apId = UUID.randomUUID();
        when(accessPointRepository.findById(apId)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.updateAccessPoint(apId, "m", 0.0, 0.0, "n")).hasMessage("Access Point not found");
    }
}
