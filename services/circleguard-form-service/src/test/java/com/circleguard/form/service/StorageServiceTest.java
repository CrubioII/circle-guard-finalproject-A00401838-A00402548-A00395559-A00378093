package com.circleguard.form.service;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class StorageServiceTest {

    private final StorageService service = new StorageService();

    @Test
    void store_copiesFileWithUniquePrefix() throws IOException {
        MockMultipartFile file = new MockMultipartFile("file", "cert.pdf", "application/pdf", "PDF".getBytes());

        String filename = service.store(file);

        Path stored = Paths.get("/tmp/circleguard-uploads").resolve(filename);
        try {
            assertThat(filename).endsWith("_cert.pdf");
            assertThat(Files.readString(stored)).isEqualTo("PDF");
        } finally {
            Files.deleteIfExists(stored);
        }
    }

    @Test
    void store_wrapsIoErrors() throws IOException {
        MultipartFile broken = mock(MultipartFile.class);
        when(broken.getOriginalFilename()).thenReturn("x.pdf");
        when(broken.getInputStream()).thenThrow(new IOException("disk full"));

        assertThatThrownBy(() -> service.store(broken))
                .isInstanceOf(RuntimeException.class)
                .hasMessageContaining("disk full");
    }
}
