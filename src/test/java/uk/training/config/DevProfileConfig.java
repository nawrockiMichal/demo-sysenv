package uk.training.config;

import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.context.annotation.PropertySource;

// Active with -Dspring.profiles.active=dev; its values override servicebus.properties.
@Configuration
@Profile("dev")
@PropertySource("classpath:servicebus-dev.properties")
public class DevProfileConfig {
}
