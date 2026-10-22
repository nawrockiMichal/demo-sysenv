package uk.training.config;

import com.azure.messaging.servicebus.ServiceBusClientBuilder;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.PropertySource;
import org.springframework.context.support.PropertySourcesPlaceholderConfigurer;

// servicebus.properties holds the defaults. Profile configs are imported after it,
// so their property files take precedence when the profile is active.
@Configuration
@ComponentScan("uk.training.util")
@PropertySource("classpath:servicebus.properties")
@Import(DevProfileConfig.class)
public class TestConfig {

    // Fails startup on an unresolvable @Value placeholder instead of injecting the literal "${...}".
    @Bean
    public static PropertySourcesPlaceholderConfigurer propertySourcesPlaceholderConfigurer() {
        return new PropertySourcesPlaceholderConfigurer();
    }

    // Clients built from the same builder share one AMQP connection.
    @Bean
    public ServiceBusClientBuilder serviceBusClientBuilder(
            @Value("${servicebus.connection-string}") String connectionString) {
        return new ServiceBusClientBuilder().connectionString(connectionString);
    }
}
