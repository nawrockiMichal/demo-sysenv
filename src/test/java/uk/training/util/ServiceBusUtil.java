package uk.training.util;

import com.azure.messaging.servicebus.ServiceBusClientBuilder;
import com.azure.messaging.servicebus.ServiceBusMessage;
import com.azure.messaging.servicebus.ServiceBusReceivedMessage;
import com.azure.messaging.servicebus.ServiceBusReceiverClient;
import com.azure.messaging.servicebus.ServiceBusSenderClient;
import com.azure.messaging.servicebus.models.ServiceBusReceiveMode;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.time.Duration;
import java.util.Properties;
import java.util.UUID;

public class ServiceBusUtil implements AutoCloseable {

    private static final String PROPERTIES_FILE = "/servicebus.properties";

    private final ServiceBusSenderClient sender;
    private final ServiceBusReceiverClient receiver;

    public ServiceBusUtil() {
        Properties properties = loadProperties();
        String connectionString = requiredProperty(properties, "servicebus.connection-string");
        String queueName = requiredProperty(properties, "servicebus.queue-name");

        sender = new ServiceBusClientBuilder()
                .connectionString(connectionString)
                .sender()
                .queueName(queueName)
                .buildClient();

        receiver = new ServiceBusClientBuilder()
                .connectionString(connectionString)
                .receiver()
                .queueName(queueName)
                .receiveMode(ServiceBusReceiveMode.RECEIVE_AND_DELETE)
                .buildClient();
    }

    /** Sends the message and returns its generated message ID. */
    public String sendMessage(String body) {
        String messageId = UUID.randomUUID().toString();
        sender.sendMessage(new ServiceBusMessage(body).setMessageId(messageId));
        return messageId;
    }

    /** Returns the body of the message with the given ID, or null if it was not received. */
    public String receiveMessageBody(String messageId) {
        return receiver
                .receiveMessages(10, Duration.ofSeconds(10))
                .stream()
                .filter(m -> messageId.equals(m.getMessageId()))
                .map(ServiceBusReceivedMessage::getBody)
                .map(Object::toString)
                .findFirst()
                .orElse(null);
    }

    @Override
    public void close() {
        sender.close();
        receiver.close();
    }

    private static Properties loadProperties() {
        try (InputStream in = ServiceBusUtil.class.getResourceAsStream(PROPERTIES_FILE)) {
            if (in == null) {
                throw new IllegalStateException(PROPERTIES_FILE + " not found on the classpath");
            }
            Properties properties = new Properties();
            properties.load(in);
            return properties;
        } catch (IOException e) {
            throw new UncheckedIOException("Could not read " + PROPERTIES_FILE, e);
        }
    }

    private static String requiredProperty(Properties properties, String name) {
        String value = properties.getProperty(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException("Property " + name + " is not set in " + PROPERTIES_FILE);
        }
        return value;
    }
}
