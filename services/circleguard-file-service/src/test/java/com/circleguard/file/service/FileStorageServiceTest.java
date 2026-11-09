package com.circleguard.file.service;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * US-32: lógica principal de almacenamiento del file-service.
 */
class FileStorageServiceTest {

    private final Path uploads = Paths.get("uploads");
    private final List<Path> created = new ArrayList<>();

    @AfterEach
    void cleanUp() throws IOException {
        for (Path p : created) {
            Files.deleteIfExists(p);
        }
    }

    @Test
    void constructorCreatesUploadsDirectory() {
        new FileStorageService();
        assertTrue(Files.isDirectory(uploads));
    }

    @Test
    void saveFileStoresContentWithUniquePrefix() throws IOException {
        FileStorageService service = new FileStorageService();
        MockMultipartFile file = new MockMultipartFile(
                "file", "certificate.pdf", "application/pdf", "pdf-content".getBytes());

        String filename = service.saveFile(file);
        Path stored = uploads.resolve(filename);
        created.add(stored);

        assertTrue(filename.endsWith("_certificate.pdf"));
        assertEquals(36 + 1 + "certificate.pdf".length(), filename.length(), "UUID + '_' + nombre original");
        assertTrue(Files.exists(stored));
        assertEquals("pdf-content", Files.readString(stored));
    }

    @Test
    void saveFileGeneratesDifferentNamesForSameOriginal() {
        FileStorageService service = new FileStorageService();
        MockMultipartFile file = new MockMultipartFile("file", "a.txt", "text/plain", "x".getBytes());

        String first = service.saveFile(file);
        String second = service.saveFile(file);
        created.add(uploads.resolve(first));
        created.add(uploads.resolve(second));

        assertNotEquals(first, second);
    }

    @Test
    void saveFileWrapsIoErrors() throws IOException {
        FileStorageService service = new FileStorageService();
        MultipartFile broken = mock(MultipartFile.class);
        when(broken.getOriginalFilename()).thenReturn("broken.pdf");
        when(broken.getInputStream()).thenThrow(new IOException("disk error"));

        RuntimeException ex = assertThrows(RuntimeException.class, () -> service.saveFile(broken));

        assertEquals("Could not store file", ex.getMessage());
        assertInstanceOf(IOException.class, ex.getCause());
    }

    @Test
    void loadFileIsNotImplementedYet() {
        assertNull(new FileStorageService().loadFile("anything"));
    }
}
