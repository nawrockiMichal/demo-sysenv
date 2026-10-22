Feature: Azure Service Bus

  Scenario: Send a message to the Service Bus queue
    Given the Service Bus queue "queue.1"
    When I send the message "Hello from Cucumber"
    Then the message "Hello from Cucumber" can be received from the queue
