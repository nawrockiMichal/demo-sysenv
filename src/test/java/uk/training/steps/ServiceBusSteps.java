package uk.training.steps;

import io.cucumber.java.After;
import io.cucumber.java.en.Given;
import io.cucumber.java.en.Then;
import io.cucumber.java.en.When;
import uk.training.util.ServiceBusUtil;

import static org.junit.jupiter.api.Assertions.assertEquals;

public class ServiceBusSteps {

    private ServiceBusUtil serviceBus;
    private String messageId;

    @Given("a Service Bus queue is available")
    public void aServiceBusQueueIsAvailable() {
        serviceBus = new ServiceBusUtil();
    }

    @When("I send the message {string}")
    public void iSendTheMessage(String body) {
        messageId = serviceBus.sendMessage(body);
    }

    @Then("the message {string} can be received from the queue")
    public void theMessageCanBeReceived(String expectedBody) {
        assertEquals(expectedBody, serviceBus.receiveMessageBody(messageId),
                "Message " + messageId + " was not received");
    }

    @After
    public void closeServiceBus() {
        if (serviceBus != null) serviceBus.close();
    }
}
