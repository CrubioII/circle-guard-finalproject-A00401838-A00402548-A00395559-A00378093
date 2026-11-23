package com.circleguard.notification.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.task.TaskDecorator;
import org.springframework.core.task.support.ContextPropagatingTaskDecorator;

/**
 * US-25 (SCRUM-94): los envíos de SMS, push, email y LMS corren en métodos @Async, es decir,
 * en otro hilo. El contexto de traza vive en el hilo que recibió el evento de Kafka, así que
 * sin este decorador esos envíos quedarían fuera de la traza. Spring Boot aplica este
 * TaskDecorator al ejecutor de @Async y copia el contexto al hilo nuevo.
 */
@Configuration
public class TracingAsyncConfig {

    @Bean
    public TaskDecorator contextPropagatingTaskDecorator() {
        return new ContextPropagatingTaskDecorator();
    }
}
