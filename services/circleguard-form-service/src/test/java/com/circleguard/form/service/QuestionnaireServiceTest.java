package com.circleguard.form.service;

import com.circleguard.form.model.Question;
import com.circleguard.form.model.QuestionType;
import com.circleguard.form.model.Questionnaire;
import com.circleguard.form.repository.QuestionnaireRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class QuestionnaireServiceTest {

    @Mock
    private QuestionnaireRepository repository;
    @InjectMocks
    private QuestionnaireService service;

    @Test
    void getAllAndActive_delegateToRepository() {
        Questionnaire q = Questionnaire.builder().title("A").version(1).build();
        when(repository.findAll()).thenReturn(List.of(q));
        when(repository.findFirstByIsActiveTrueOrderByVersionDesc()).thenReturn(Optional.of(q));

        assertThat(service.getAllQuestionnaires()).containsExactly(q);
        assertThat(service.getActiveQuestionnaire()).contains(q);
    }

    @Test
    void saveQuestionnaire_linksQuestionsToParent() {
        Question q1 = Question.builder().text("Fever?").type(QuestionType.YES_NO).orderIndex(1).build();
        Questionnaire questionnaire = Questionnaire.builder().title("Daily").version(1).questions(List.of(q1)).build();
        when(repository.save(questionnaire)).thenReturn(questionnaire);

        assertThat(service.saveQuestionnaire(questionnaire)).isSameAs(questionnaire);
        assertThat(q1.getQuestionnaire()).isSameAs(questionnaire);
    }

    @Test
    void saveQuestionnaire_withoutQuestions_isSaved() {
        Questionnaire questionnaire = Questionnaire.builder().title("Empty").version(1).build();
        when(repository.save(questionnaire)).thenReturn(questionnaire);

        assertThat(service.saveQuestionnaire(questionnaire)).isSameAs(questionnaire);
    }

    @Test
    void activateQuestionnaire_deactivatesOthersAndActivatesTarget() {
        UUID targetId = UUID.randomUUID();
        Questionnaire previouslyActive = Questionnaire.builder().id(UUID.randomUUID()).title("Old").version(1).isActive(true).build();
        Questionnaire inactive = Questionnaire.builder().id(UUID.randomUUID()).title("Other").version(1).isActive(false).build();
        Questionnaire target = Questionnaire.builder().id(targetId).title("New").version(2).isActive(false).build();
        when(repository.findAll()).thenReturn(List.of(previouslyActive, inactive, target));
        when(repository.findById(targetId)).thenReturn(Optional.of(target));

        service.activateQuestionnaire(targetId);

        assertThat(previouslyActive.getIsActive()).isFalse();
        assertThat(target.getIsActive()).isTrue();
        verify(repository).save(previouslyActive);
        verify(repository).save(target);
        verify(repository, never()).save(inactive);
    }
}
