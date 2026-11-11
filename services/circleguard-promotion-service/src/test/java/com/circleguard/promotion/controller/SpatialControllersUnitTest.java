package com.circleguard.promotion.controller;

import com.circleguard.promotion.dto.AccessPointDTO;
import com.circleguard.promotion.dto.BuildingDTO;
import com.circleguard.promotion.dto.FloorDTO;
import com.circleguard.promotion.model.AccessPoint;
import com.circleguard.promotion.model.Building;
import com.circleguard.promotion.model.Floor;
import com.circleguard.promotion.service.AccessPointService;
import com.circleguard.promotion.service.BuildingService;
import com.circleguard.promotion.service.FloorService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SpatialControllersUnitTest {

    @Mock
    private BuildingService buildingService;
    @Mock
    private FloorService floorService;
    @Mock
    private AccessPointService accessPointService;

    private final UUID buildingId = UUID.randomUUID();
    private final UUID floorId = UUID.randomUUID();
    private final UUID apId = UUID.randomUUID();

    private Building building() {
        return Building.builder().id(buildingId).name("Eng").code("ENG").description("d")
                .latitude(1.0).longitude(2.0).address("addr").build();
    }

    private Floor floor(Building b) {
        return Floor.builder().id(floorId).building(b).floorNumber(1).name("L1").floorPlanUrl("plan.png").build();
    }

    private AccessPoint ap(Floor f) {
        return AccessPoint.builder().id(apId).macAddress("AA").floor(f).coordinateX(1.0).coordinateY(2.0).name("AP").build();
    }

    @Test
    void buildingController_createListUpdateAndDelete() {
        BuildingController controller = new BuildingController(buildingService, floorService);
        Building b = building();
        b.setFloors(List.of(floor(b)));
        BuildingDTO request = BuildingDTO.builder().name("Eng").code("ENG").description("d")
                .latitude(1.0).longitude(2.0).address("addr").build();
        when(buildingService.createBuilding("Eng", "ENG", "d", 1.0, 2.0, "addr")).thenReturn(b);
        when(buildingService.getAllBuildings()).thenReturn(List.of(b, building()));
        when(buildingService.updateBuilding(buildingId, "Eng", "ENG", "d", 1.0, 2.0, "addr")).thenReturn(b);

        BuildingDTO created = controller.createBuilding(request).getBody();
        assertThat(created.getId()).isEqualTo(buildingId);
        assertThat(created.getFloors()).singleElement().satisfies(f -> {
            assertThat(f.getBuildingId()).isEqualTo(buildingId);
            assertThat(f.getFloorPlanUrl()).isEqualTo("plan.png");
        });

        List<BuildingDTO> all = controller.listBuildings().getBody();
        assertThat(all).hasSize(2);
        assertThat(all.get(1).getFloors()).isNull();

        assertThat(controller.updateBuilding(buildingId, request).getBody().getAddress()).isEqualTo("addr");

        assertThat(controller.deleteBuilding(buildingId).getStatusCode().value()).isEqualTo(200);
        verify(buildingService).deleteBuilding(buildingId);
    }

    @Test
    void buildingController_floors() {
        BuildingController controller = new BuildingController(buildingService, floorService);
        Floor orphan = Floor.builder().id(floorId).floorNumber(2).name("L2").build();
        when(floorService.getFloorsByBuilding(buildingId)).thenReturn(List.of(orphan));
        when(floorService.addFloor(buildingId, 2, "L2")).thenReturn(floor(building()));

        assertThat(controller.getFloors(buildingId).getBody()).singleElement()
                .satisfies(f -> assertThat(f.getBuildingId()).isNull());
        FloorDTO added = controller.addFloor(buildingId, FloorDTO.builder().floorNumber(2).name("L2").build()).getBody();
        assertThat(added.getBuildingId()).isEqualTo(buildingId);
    }

    @Test
    void floorController_accessPointsUpdateAndDelete() {
        FloorController controller = new FloorController(floorService, accessPointService);
        Floor f = floor(building());
        AccessPointDTO apRequest = AccessPointDTO.builder().macAddress("AA").coordinateX(1.0).coordinateY(2.0).name("AP").build();
        when(accessPointService.registerAccessPoint(floorId, "AA", 1.0, 2.0, "AP")).thenReturn(ap(f));
        when(accessPointService.getAccessPointsByFloor(floorId)).thenReturn(List.of(ap(f), ap(null)));
        when(floorService.updateFloor(floorId, 1, "L1", "plan.png")).thenReturn(f);

        assertThat(controller.addAccessPoint(floorId, apRequest).getBody().getFloorId()).isEqualTo(floorId);
        List<AccessPointDTO> aps = controller.getAccessPoints(floorId).getBody();
        assertThat(aps).hasSize(2);
        assertThat(aps.get(1).getFloorId()).isNull();

        FloorDTO updated = controller.updateFloor(floorId,
                FloorDTO.builder().floorNumber(1).name("L1").floorPlanUrl("plan.png").build()).getBody();
        assertThat(updated.getBuildingId()).isEqualTo(buildingId);

        Floor noBuilding = Floor.builder().id(floorId).floorNumber(9).build();
        when(floorService.updateFloor(floorId, 9, null, null)).thenReturn(noBuilding);
        assertThat(controller.updateFloor(floorId, FloorDTO.builder().floorNumber(9).build()).getBody().getBuildingId()).isNull();

        controller.deleteFloor(floorId);
        verify(floorService).deleteFloor(floorId);
    }

    @Test
    void accessPointController_getUpdateAndDelete() {
        AccessPointController controller = new AccessPointController(accessPointService);
        AccessPoint ap = ap(floor(building()));
        when(accessPointService.getAccessPoint(apId)).thenReturn(Optional.of(ap));
        UUID missing = UUID.randomUUID();
        when(accessPointService.getAccessPoint(missing)).thenReturn(Optional.empty());
        when(accessPointService.updateAccessPoint(apId, "BB", 3.0, 4.0, "AP2")).thenReturn(ap(null));

        assertThat(controller.getAccessPoint(apId).getBody().getMacAddress()).isEqualTo("AA");
        assertThat(controller.getAccessPoint(missing).getStatusCode().value()).isEqualTo(404);
        AccessPointDTO updated = controller.updateAccessPoint(apId,
                AccessPointDTO.builder().macAddress("BB").coordinateX(3.0).coordinateY(4.0).name("AP2").build()).getBody();
        assertThat(updated.getFloorId()).isNull();

        controller.deleteAccessPoint(apId);
        verify(accessPointService).deleteAccessPoint(apId);
    }
}
