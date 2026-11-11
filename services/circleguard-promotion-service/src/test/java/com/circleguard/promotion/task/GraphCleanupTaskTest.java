package com.circleguard.promotion.task;

import com.circleguard.promotion.repository.graph.UserNodeRepository;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.*;

class GraphCleanupTaskTest {

    private static final long FOURTEEN_DAYS_MS = 14L * 24 * 60 * 60 * 1000;

    @Test
    void purgeStaleEncounters_usesFourteenDayThreshold() {
        UserNodeRepository repository = mock(UserNodeRepository.class);
        when(repository.purgeStaleEncounters(anyLong())).thenReturn(4L);
        long before = System.currentTimeMillis();

        new GraphCleanupTask(repository).purgeStaleEncounters();

        ArgumentCaptor<Long> threshold = ArgumentCaptor.forClass(Long.class);
        verify(repository).purgeStaleEncounters(threshold.capture());
        assertThat(threshold.getValue()).isBetween(before - FOURTEEN_DAYS_MS, System.currentTimeMillis() - FOURTEEN_DAYS_MS);
    }

    @Test
    void purgeStaleEncounters_handlesNullCountAndSwallowsErrors() {
        UserNodeRepository repository = mock(UserNodeRepository.class);
        when(repository.purgeStaleEncounters(anyLong())).thenReturn(null).thenThrow(new IllegalStateException("neo4j down"));
        GraphCleanupTask task = new GraphCleanupTask(repository);

        assertThatCode(task::purgeStaleEncounters).doesNotThrowAnyException();
        assertThatCode(task::purgeStaleEncounters).doesNotThrowAnyException();
        verify(repository, times(2)).purgeStaleEncounters(anyLong());
    }
}
