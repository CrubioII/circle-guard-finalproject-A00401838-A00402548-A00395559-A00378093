package com.circleguard.file.controller;

import com.circleguard.file.service.FileStorageService;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * US-32: validación de entrada del endpoint de carga.
 */
@WebMvcTest(FileUploadController.class)
class FileUploadControllerEdgeCasesTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private FileStorageService storageService;

    @Test
    void shouldRejectRequestWithoutFilePart() throws Exception {
        mockMvc.perform(multipart("/api/v1/files/upload"))
                .andExpect(status().isBadRequest());
        Mockito.verifyNoInteractions(storageService);
    }

    @Test
    void shouldReturnStoredNameGeneratedByService() throws Exception {
        MockMultipartFile file = new MockMultipartFile("file", "x-ray.png", "image/png", new byte[]{1, 2, 3});
        Mockito.when(storageService.saveFile(Mockito.any())).thenReturn("1234_x-ray.png");

        mockMvc.perform(multipart("/api/v1/files/upload").file(file))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.filename").value("1234_x-ray.png"));
    }
}
