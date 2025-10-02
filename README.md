# Salesforce REST Integration Example

This repository demonstrates a practical bidirectional integration between an external system and Salesforce using REST APIs. It contains working code and documentation for both directions of integration:

* **External → Salesforce:** A Node.js application obtains a Salesforce access token via the JWT Bearer OAuth flow and performs upserts on the `Account` object using the Salesforce REST API. The application also exposes a `/webhook/salesforce` endpoint to receive callbacks from Salesforce.
* **Salesforce → External:** Apex classes (queueable, trigger, and REST endpoint) send asynchronous HTTP POST requests to an external system using a Named Credential. They include retry logic, logging, and a simple trigger handler to enqueue outbound notifications when `Account` records change.

## Files in this repository

| File | Description |
| --- | --- |
| `server.js` | Node.js application that authenticates with Salesforce using JWT bearer tokens and performs upserts on the `Account` object. It also exposes an endpoint to receive callbacks from Salesforce. |
| `AccountSyncRest.cls` | Apex REST class that exposes a `/v1/accounts/*` endpoint. It validates input and performs an upsert on the `Account` object using a custom external ID field. |
| `OutboundPoster.cls` | Apex Queueable class that performs asynchronous callouts to an external endpoint via a Named Credential. It includes basic retry logic and writes results to an `Integration_Log__c` custom object for observability. |
| `AccountTriggerHandler.cls` | Apex handler class that enqueues outbound notifications when `Account` records are inserted or updated. |
| `AccountAfter.trigger` | Trigger that delegates to `AccountTriggerHandler` after insert and update events on `Account` objects. |
| `CHAT.md` | The original chat explanation of the integration architecture and the code (in Japanese). |

## Overview

This example shows how to set up a reliable integration between Salesforce and an external system:

- **Authentication:** The external application authenticates to Salesforce using the JWT Bearer flow, avoiding the need to store passwords. On the Salesforce side, callouts to the external system are performed via a Named Credential for secure credential management.
- **Upserts:** The external application uses the External ID field `External_Id__c` on the `Account` object for idempotent upserts. The Apex REST class offers a similar interface directly on the Salesforce platform if you need custom business validation.
- **Outbound Notifications:** Trigger and handler logic enqueue a Queueable job (`OutboundPoster`) to perform asynchronous callouts to the external system whenever an `Account` is created or its name changes. This decouples the callout from the DML transaction and allows for retry logic.
- **Logging:** Every outbound call is logged into the `Integration_Log__c` custom object (schema not included) to aid with monitoring, troubleshooting, and auditing. Retry attempts are logged and capped at three.

Refer to `CHAT.md` for a detailed explanation of the design choices and code walkthrough (Japanese). If you adapt this pattern for production, make sure to implement appropriate security measures on the external server (e.g., IP allowlist, request signing, and TLS).