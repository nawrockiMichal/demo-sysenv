package uk.training.util;

import com.azure.messaging.servicebus.ServiceBusClientBuilder;
import com.azure.messaging.servicebus.ServiceBusMessage;
import com.azure.messaging.servicebus.ServiceBusReceivedMessage;
import com.azure.messaging.servicebus.ServiceBusReceiverClient;
import com.azure.messaging.servicebus.ServiceBusSenderClient;
import com.azure.messaging.servicebus.models.ServiceBusReceiveMode;

import java.time.Duration;
import java.util.UUID;

public class ServiceBusUtil implements AutoCloseable {

    private final ServiceBusSenderClient sender;
    private final ServiceBusReceiverClient receiver;

    public ServiceBusUtil() {
        String connectionString = requiredEnv("SERVICEBUS_CONNECTION_STRING");
        String queueName = requiredEnv("SERVICEBUS_QUEUE_NAME");

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

    private static String requiredEnv(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException("Environment variable " + name + " is not set");
        }
        return value;
    }
}
