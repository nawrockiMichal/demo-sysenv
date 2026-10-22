Feature: Azure Service Bus

  Scenario: Send a message to the Service Bus queue
    Given a Service Bus queue is available
    When I send the message "Hello from Cucumber"
    Then the message "Hello from Cucumber" can be received from the queue
