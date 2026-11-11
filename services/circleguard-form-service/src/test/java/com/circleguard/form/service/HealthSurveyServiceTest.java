package com.circleguard.form.service;

import com.circleguard.form.model.HealthSurvey;
import com.circleguard.form.model.Questionnaire;
import com.circleguard.form.model.ValidationStatus;
import com.circleguard.form.repository.HealthSurveyRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.kafka.core.KafkaTemplate;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class HealthSurveyServiceTest {

    @Mock
    private HealthSurveyRepository repository;
    @Mock
    private QuestionnaireService questionnaireService;
    @Mock
    private SymptomMapper symptomMapper;
    @Mock
    private KafkaTemplate<String, Object> kafkaTemplate;
    @InjectMocks
    private HealthSurveyService service;

    @Test
    @SuppressWarnings("unchecked")
    void submitSurvey_withSymptoms_fillsLegacyFieldsAndPublishesEvent() {
        UUID anon = UUID.randomUUID();
        Questionnaire active = Questionnaire.builder().title("Daily").version(1).build();
        HealthSurvey survey = HealthSurvey.builder().anonymousId(anon).attachmentPath("cert.pdf").build();
        when(questionnaireService.getActiveQuestionnaire()).thenReturn(Optional.of(active));
        when(symptomMapper.hasSymptoms(survey, active)).thenReturn(true);
        when(repository.save(survey)).thenReturn(survey);

        HealthSurvey saved = service.submitSurvey(survey);

        assertThat(saved.getHasFever()).isTrue();
        assertThat(saved.getHasCough()).isTrue();
        assertThat(saved.getValidationStatus()).isEqualTo(ValidationStatus.PENDING);
        ArgumentCaptor<Object> event = ArgumentCaptor.forClass(Object.class);
        verify(kafkaTemplate).send(eq("survey.submitted"), eq(anon.toString()), event.capture());
        assertThat((Map<String, Object>) event.getValue())
                .containsEntry("anonymousId", anon)
                .containsEntry("hasSymptoms", true)
                .containsKey("timestamp");
    }

    @Test
    void submitSurvey_withoutActiveQuestionnaire_keepsExplicitFlagsAndNoValidation() {
        UUID anon = UUID.randomUUID();
        HealthSurvey survey = HealthSurvey.builder().anonymousId(anon).hasFever(true).hasCough(false).build();
        when(questionnaireService.getActiveQuestionnaire()).thenReturn(Optional.empty());
        when(repository.save(survey)).thenReturn(survey);

        HealthSurvey saved = service.submitSurvey(survey);

        assertThat(saved.getHasFever()).isTrue();
        assertThat(saved.getHasCough()).isFalse();
        assertThat(saved.getValidationStatus()).isNull();
        verifyNoInteractions(symptomMapper);
        verify(kafkaTemplate).send(eq("survey.submitted"), eq(anon.toString()), any());
    }

    @Test
    void getPendingSurveys_queriesPendingWithAttachment() {
        List<HealthSurvey> pending = List.of(new HealthSurvey());
        when(repository.findByAttachmentPathIsNotNullAndValidationStatus(ValidationStatus.PENDING)).thenReturn(pending);

        assertThat(service.getPendingSurveys()).isSameAs(pending);
    }

    @Test
    void validateSurvey_approved_savesAndPublishesCertificateEvent() {
        UUID id = UUID.randomUUID();
        UUID admin = UUID.randomUUID();
        UUID anon = UUID.randomUUID();
        HealthSurvey survey = HealthSurvey.builder().id(id).anonymousId(anon).build();
        when(repository.findById(id)).thenReturn(Optional.of(survey));

        service.validateSurvey(id, ValidationStatus.APPROVED, admin);

        assertThat(survey.getValidationStatus()).isEqualTo(ValidationStatus.APPROVED);
        assertThat(survey.getValidatedBy()).isEqualTo(admin);
        verify(repository).save(survey);
        verify(kafkaTemplate).send(eq("certificate.validated"), eq(anon.toString()), any());
    }

    @Test
    void validateSurvey_rejected_doesNotPublish() {
        UUID id = UUID.randomUUID();
        HealthSurvey survey = HealthSurvey.builder().id(id).anonymousId(UUID.randomUUID()).build();
        when(repository.findById(id)).thenReturn(Optional.of(survey));

        service.validateSurvey(id, ValidationStatus.REJECTED, UUID.randomUUID());

        assertThat(survey.getValidationStatus()).isEqualTo(ValidationStatus.REJECTED);
        verifyNoInteractions(kafkaTemplate);
    }

    @Test
    void validateSurvey_unknownSurvey_throws() {
        UUID id = UUID.randomUUID();
        when(repository.findById(id)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.validateSurvey(id, ValidationStatus.APPROVED, UUID.randomUUID()))
                .hasMessageContaining("Survey not found");
    }
}
