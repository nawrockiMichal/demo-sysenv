package uk.training.util;

import com.azure.messaging.servicebus.ServiceBusClientBuilder;
import com.azure.messaging.servicebus.ServiceBusMessage;
import com.azure.messaging.servicebus.ServiceBusReceivedMessage;
import com.azure.messaging.servicebus.ServiceBusReceiverClient;
import com.azure.messaging.servicebus.ServiceBusSenderClient;
import com.azure.messaging.servicebus.models.ServiceBusReceiveMode;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

// Senders and receivers are created once per queue from the shared builder, so they all use one connection.
// Spring calls close() when the test context shuts down.
@Component
public class ServiceBusUtil implements AutoCloseable {

    private final ServiceBusClientBuilder builder;
    private final Map<String, ServiceBusSenderClient> senders = new ConcurrentHashMap<>();
    private final Map<String, ServiceBusReceiverClient> receivers = new ConcurrentHashMap<>();

    public ServiceBusUtil(ServiceBusClientBuilder builder) {
        this.builder = builder;
    }

    /** Sends the message to the queue and returns its generated message ID. */
    public String sendMessage(String queueName, String body) {
        String messageId = UUID.randomUUID().toString();
        sender(queueName).sendMessage(new ServiceBusMessage(body).setMessageId(messageId));
        return messageId;
    }

    /** Returns the body of the message with the given ID from the queue, or null if it was not received. */
    public String receiveMessageBody(String queueName, String messageId) {
        return receiver(queueName)
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
        senders.values().forEach(ServiceBusSenderClient::close);
        receivers.values().forEach(ServiceBusReceiverClient::close);
    }

    private ServiceBusSenderClient sender(String queueName) {
        return senders.computeIfAbsent(queueName, name -> builder.sender()
                .queueName(name)
                .buildClient());
    }

    private ServiceBusReceiverClient receiver(String queueName) {
        return receivers.computeIfAbsent(queueName, name -> builder.receiver()
                .queueName(name)
                .receiveMode(ServiceBusReceiveMode.RECEIVE_AND_DELETE)
                .buildClient());
    }
}
