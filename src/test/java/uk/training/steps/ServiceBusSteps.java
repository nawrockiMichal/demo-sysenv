package uk.training.steps;

import io.cucumber.java.en.Given;
import io.cucumber.java.en.Then;
import io.cucumber.java.en.When;
import uk.training.util.ServiceBusUtil;

import static org.junit.jupiter.api.Assertions.assertEquals;

public class ServiceBusSteps {

    private final ServiceBusUtil serviceBus;
    private String queueName;
    private String messageId;

    public ServiceBusSteps(ServiceBusUtil serviceBus) {
        this.serviceBus = serviceBus;
    }

    @Given("the Service Bus queue {string}")
    public void theServiceBusQueue(String queueName) {
        this.queueName = queueName;
    }

    @When("I send the message {string}")
    public void iSendTheMessage(String body) {
        messageId = serviceBus.sendMessage(queueName, body);
    }

    @Then("the message {string} can be received from the queue")
    public void theMessageCanBeReceived(String expectedBody) {
        assertEquals(expectedBody, serviceBus.receiveMessageBody(queueName, messageId),
                "Message " + messageId + " was not received");
    }
}
