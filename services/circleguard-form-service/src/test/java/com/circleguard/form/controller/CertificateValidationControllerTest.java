package com.circleguard.form.controller;

import com.circleguard.form.model.HealthSurvey;
import com.circleguard.form.model.ValidationStatus;
import com.circleguard.form.service.HealthSurveyService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class CertificateValidationControllerTest {

    @Mock
    private HealthSurveyService surveyService;
    @InjectMocks
    private CertificateValidationController controller;

    @Test
    void getPending_returnsPendingSurveys() {
        List<HealthSurvey> pending = List.of(new HealthSurvey());
        when(surveyService.getPendingSurveys()).thenReturn(pending);

        assertThat(controller.getPending().getBody()).isEqualTo(pending);
    }

    @Test
    void validate_delegatesToService() {
        UUID id = UUID.randomUUID();
        UUID admin = UUID.randomUUID();

        assertThat(controller.validate(id, ValidationStatus.APPROVED, admin).getStatusCode().value()).isEqualTo(200);
        verify(surveyService).validateSurvey(id, ValidationStatus.APPROVED, admin);
    }
}
